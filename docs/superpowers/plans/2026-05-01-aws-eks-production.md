# AWS EKS Production Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws/vpc/envs/production` で構築済の VPC 上に、`terraform-aws-modules/eks/aws 21.19.0` を用いて production EKS クラスタ `eks-production`（v1.33、m6g.large × 2-4 system node group、Cilium chaining 前提の VPC CNI、Access Entries モード）を構築する。

**Architecture:** `aws/{service}/modules + envs/{env}` 規約で `aws/eks/` を新設。VPC 出力は `aws/vpc/lookup` を `module "vpc"` として呼ぶ（terragrunt `dependency` ブロックは使わない）。go-getter `//` subdir 記法（`source = "../../..//eks/modules"`）で `aws/` 全体を terragrunt cache に同梱して相対 source `../../vpc/lookup` を解決。Kubernetes admin RBAC は新設の `eks-admin-production` IAM role のみに Access Entry で付与し、CI 上の `github-oidc-auth-production-github-actions-role` は AWS API のみ（Kubernetes RBAC なし）。GitOps 原則のため `enable_cluster_creator_admin_permissions = false`。`endoflife-date/amazon-eks` datasource を Renovate `customManagers` で `env.hcl` の `cluster_version` に紐付ける。

**Tech Stack:** OpenTofu/Terraform `>= 1.11.6`, Terragrunt, AWS provider `6.42.0`, `terraform-aws-modules/eks/aws 21.19.0`, `terraform-aws-modules/iam/aws ~> 6.0`（`iam-role-for-service-accounts-eks` submodule for IRSA）, `aws/vpc/lookup`（同リポジトリ内）, Renovate (`endoflife-date` datasource)

**Spec:** `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `aws/eks/Makefile` | create | terragrunt 実行 helper（`aws/vpc/Makefile` を踏襲、表示文字列のみ EKS に変更） |
| `aws/eks/root.hcl` | create | terragrunt root（remote_state、common_tags、project_name = "eks"） |
| `aws/eks/envs/production/env.hcl` | create | environment 固有値（cluster_version + renovate marker、environment_tags） |
| `aws/eks/envs/production/terragrunt.hcl` | create | env から module へ inputs を渡す。`source = "../../..//eks/modules"`（go-getter `//` 記法） |
| `aws/eks/envs/production/.terraform.lock.hcl` | create | provider lock file（`terragrunt init` で生成、commit） |
| `aws/eks/modules/terraform.tf` | create | `required_version >= 1.11.6`、AWS provider `6.42.0` exact pin、provider 設定 |
| `aws/eks/modules/variables.tf` | create | environment / aws_region / common_tags / cluster_version / node_* / log_retention_days |
| `aws/eks/modules/lookups.tf` | create | `module "vpc" { source = "../../vpc/lookup" }` |
| `aws/eks/modules/iam_admin.tf` | create | `eks-admin-production` IAM role + inline `eks:DescribeCluster` policy |
| `aws/eks/modules/main.tf` | create | `module "eks"` 本体（terraform-aws-modules/eks/aws 21.19.0） |
| `aws/eks/modules/access_entries.tf` | create | `locals.access_entries`（admin role を ClusterAdmin） |
| `aws/eks/modules/node_groups.tf` | create | `locals.eks_managed_node_groups`（system node group） |
| `aws/eks/modules/addons.tf` | create | `locals.cluster_addons` + IRSA submodules（vpc-cni, ebs-csi-driver） |
| `aws/eks/modules/outputs.tf` | create | cluster_* / oidc_* / *_iam_role_arn / admin_role_* |
| `.github/renovate.json` | modify | `customManagers` セクションを追加（`cluster_version` 自動更新） |

> **依存 spec の前提（apply 済みであること）**：`docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md` の実装が main にマージ済かつ `aws/vpc/envs/production` で apply 済（subnet に `Tier` タグ付与済）。

---

### Task 0: 公式 docs と前提条件を確認

**Files:** （read only）

実装中に判断揺れを避けるため、`terraform-aws-modules/eks/aws v21.19.0` の引数仕様と前提条件を実装前に確認する。

- [ ] **Step 1: VPC stack が apply 済かを確認**

```bash
cd aws/vpc/envs/production
TG_TF_PATH=tofu terragrunt plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

差分が出る場合は EKS plan 前に VPC を `terragrunt apply` する（特に cross-stack lookup spec の `Tier` タグが未 apply の場合、EKS plan が subnet 解決失敗する）。

- [ ] **Step 2: VPC lookup module の動作確認**

```bash
terraform -chdir=aws/vpc/lookup init -backend=false
terraform -chdir=aws/vpc/lookup validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: terraform-aws-modules/eks v21.19.0 の引数確認**

実装中に参照する引数名は以下で確定済（v21.19.0 の `variables.tf` から引用）：

| 引数 | 型 | 用途 |
|---|---|---|
| `name` | string | クラスタ名 |
| `kubernetes_version` | string | EKS バージョン（`1.33` 等） |
| `vpc_id` | string | VPC ID |
| `subnet_ids` | list(string) | nodes 用 subnet |
| `control_plane_subnet_ids` | list(string) | control plane 用 subnet（未指定なら subnet_ids を流用） |
| `endpoint_public_access` | bool | default `false`、本 spec は `true` |
| `endpoint_private_access` | bool | default `true`、本 spec も `true` |
| `endpoint_public_access_cidrs` | list(string) | default `["0.0.0.0/0"]`、本 spec はそのまま |
| `authentication_mode` | string | `"API"` |
| `enable_cluster_creator_admin_permissions` | bool | default `false`、本 spec は `false`（明示） |
| `enable_irsa` | bool | default `true`、本 spec はそのまま |
| `enabled_log_types` | list(string) | `["audit", "authenticator"]` |
| `cloudwatch_log_group_retention_in_days` | number | `7` |
| `eks_managed_node_groups` | map(object) | system node group 1 つ |
| `addons` | map(object) | addon 5 つ。各 entry に `service_account_role_arn` で IRSA を渡す |
| `access_entries` | map(object) | admin role 1 つ |
| `tags` | map(string) | `var.common_tags` |

> v21 の `addons` は内部で IRSA role を作らないため、IRSA は `terraform-aws-modules/iam/aws ~> 6.0` の `iam-role-for-service-accounts-eks` submodule で別途作成し、その role ARN を `service_account_role_arn` に渡す（Task 7）。

- [ ] **Step 4: ブランチ・worktree を確認**

```bash
git -C /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-aws-eks-production rev-parse --abbrev-ref HEAD
```

Expected: `feat-aws-eks-production`

以後すべてのコマンドはこの worktree（`/Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-aws-eks-production/`）で実行する。

- [ ] **Step 5: AWS 認証を確認**

```bash
aws sts get-caller-identity --query Account --output text
```

Expected: `559744160976`

EKS module の data source（`data "aws_caller_identity"` 等）と VPC lookup の data source 解決に AWS 認証が必須。

---

### Task 1: terragrunt scaffolding（最小構成で `init` 通過）

**Files:**
- Create: `aws/eks/Makefile`
- Create: `aws/eks/root.hcl`
- Create: `aws/eks/envs/production/env.hcl`
- Create: `aws/eks/envs/production/terragrunt.hcl`
- Create: `aws/eks/modules/terraform.tf`
- Create: `aws/eks/modules/variables.tf`
- Create: `aws/eks/modules/main.tf`（一時的に空コメントのみ）

terragrunt が `init` まで通る最小構成を作る。EKS module 本体（`module "eks"`）はまだ書かず、空ファイルで足場のみ。

- [ ] **Step 1: Create directory layout**

```bash
mkdir -p aws/eks/envs/production aws/eks/modules
```

- [ ] **Step 2: Create `aws/eks/root.hcl`**

```hcl
# root.hcl - Root Terragrunt configuration for EKS
# This file contains common settings shared across all environments

locals {
  # Project metadata
  project_name = "eks"

  # Parse environment from the directory path
  # This assumes environments are in envs/<environment>/ directories
  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  # Common tags applied to all resources
  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks"
    Team        = "panicboat"
  }
}

# Remote state configuration using shared S3 bucket
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    # Shared bucket for all monorepo services
    bucket = "terragrunt-state-${get_aws_account_id()}"

    # Service-specific path: eks/<environment>/terraform.tfstate
    key    = "platform/eks/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    # Shared DynamoDB table for state locking across all services
    dynamodb_table = "terragrunt-state-locks"

    # Enable server-side encryption
    encrypt = true
  }
}

# Common inputs passed to all Terraform modules
inputs = {
  environment = local.environment
  common_tags = local.common_tags
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 3: Create `aws/eks/envs/production/env.hcl`**

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  # Environment-specific settings
  environment = "production"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # EKS Kubernetes version
  # renovate: datasource=endoflife-date depName=amazon-eks versioning=loose
  cluster_version = "1.33"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "eks"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 4: Create `aws/eks/envs/production/terragrunt.hcl`**

```hcl
# terragrunt.hcl - Terragrunt configuration for production environment

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "vpc"` in modules/lookups.tf
# resolve `../../vpc/lookup` from within the cache. See
# docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md for the
# convention.
terraform {
  source = "../../..//eks/modules"
}

# Input variables for the module
inputs = {
  environment     = include.env.locals.environment
  aws_region      = include.env.locals.aws_region
  cluster_version = include.env.locals.cluster_version

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 5: Create `aws/eks/modules/terraform.tf`**

```hcl
# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.42.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
```

- [ ] **Step 6: Create `aws/eks/modules/variables.tf`**

```hcl
# variables.tf - Variables for EKS module

variable "environment" {
  description = "Environment name (e.g., production)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "cluster_version" {
  description = "EKS Kubernetes version (e.g., \"1.33\")"
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the system managed node group"
  type        = list(string)
  default     = ["m6g.large"]
}

variable "node_desired_size" {
  description = "Desired number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the system node group"
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "EBS volume size (GiB) for node group"
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days for control plane logs"
  type        = number
  default     = 7
}
```

- [ ] **Step 7: Create placeholder `aws/eks/modules/main.tf`**

```hcl
# main.tf - EKS cluster composition (placeholder; populated in Task 4)
```

- [ ] **Step 8: Create `aws/eks/Makefile`**

`aws/vpc/Makefile` をコピーし `VPC` を `EKS` に置換：

```bash
sed 's/VPC/EKS/g' aws/vpc/Makefile > aws/eks/Makefile
```

差分確認：

```bash
diff aws/vpc/Makefile aws/eks/Makefile
```

Expected: `< # Makefile for VPC` → `> # Makefile for EKS`、`< @echo "VPC - Terragrunt Commands"` → `> @echo "EKS - Terragrunt Commands"` のような置換のみ。

- [ ] **Step 9: terragrunt init で lock file 生成**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init
```

Expected: 

- backend S3 への接続成功
- AWS provider `6.42.0` 取得
- `Terraform has been successfully initialized!`
- 同階層に `.terraform.lock.hcl` が生成される

エラーが出たら：
- `S3 bucket terragrunt-state-559744160976` 存在確認（`aws s3 ls s3://terragrunt-state-559744160976/`）
- AWS 認証（`aws sts get-caller-identity`）

- [ ] **Step 10: Validate**

```bash
TG_TF_PATH=tofu terragrunt validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 11: Format check**

```bash
cd ../../..  # repo root
terraform fmt -check -recursive aws/eks
```

Expected: 出力なし（exit 0）。差分が出る場合は `terraform fmt -recursive aws/eks` で整形。

- [ ] **Step 12: Commit**

```bash
git add aws/eks/Makefile aws/eks/root.hcl \
        aws/eks/envs/production/env.hcl \
        aws/eks/envs/production/terragrunt.hcl \
        aws/eks/envs/production/.terraform.lock.hcl \
        aws/eks/modules/terraform.tf \
        aws/eks/modules/variables.tf \
        aws/eks/modules/main.tf
git commit -s -m "chore(aws/eks): scaffold terragrunt project structure

aws/eks 配下に terragrunt root.hcl、envs/production の env.hcl /
terragrunt.hcl、modules の terraform.tf / variables.tf を新設し、
terragrunt init / validate が通る最小構成を整える。

terragrunt.hcl の terraform.source は go-getter // subdir 記法を採用し、
aws/ 全体を cache に同梱できるようにする（後続 Task で
modules/lookups.tf から ../../vpc/lookup を解決するため）。
env.hcl の cluster_version には Renovate marker を仕込んでおく
（Renovate 設定追加は別 Task）。"
```

---

### Task 2: VPC lookup を組み込む

**Files:**
- Create: `aws/eks/modules/lookups.tf`

`aws/vpc/lookup` を `module "vpc"` として呼ぶ。これで以降のリソース定義から `module.vpc.vpc.id` / `module.vpc.subnets.private.ids` を参照できる。

- [ ] **Step 1: Create `aws/eks/modules/lookups.tf`**

```hcl
# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
```

- [ ] **Step 2: Validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt validate
```

Expected: 

- `init` で `aws/vpc/lookup` が cache に取り込まれる（go-getter `//` 記法のおかげで `aws/` 全体がコピー済）
- `Success! The configuration is valid.`

- [ ] **Step 3: Plan で VPC が解決されることを確認**

```bash
TG_TF_PATH=tofu terragrunt plan
```

Expected:

- `module.vpc.data.aws_vpc.this`, `module.vpc.data.aws_subnets.private` 等の data source 解決ログ
- リソース変更は 0（まだ何も resource を定義していない）
- `No changes. Your infrastructure matches the configuration.`

VPC が見つからない場合は Task 0 Step 1 に戻り、`aws/vpc/envs/production` を apply する。

- [ ] **Step 4: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

Expected: 出力なし。

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/lookups.tf
git commit -s -m "feat(aws/eks): wire up aws/vpc/lookup for cross-stack VPC discovery

modules/lookups.tf に module \"vpc\" を追加し、aws/vpc/lookup（タグ
ベースの data source ラッパ）から VPC ID / subnet IDs / DB subnet
group を取得できるようにする。terragrunt dependency ブロックは使わず
（cross-stack lookup spec の方針）、go-getter // 記法でキャッシュ同梱
した相対 source ../../vpc/lookup を解決する。"
```

---

### Task 3: 人間 kubectl 用 IAM admin role を作成

**Files:**
- Create: `aws/eks/modules/iam_admin.tf`

人間が kubectl admin として assume するための IAM role を新設する。Trust policy は account 内 principal を許可（誰が実際に assume できるかは IAM user 側のポリシーで制御）。Inline policy は kubeconfig 取得用 `eks:DescribeCluster` のみ。Kubernetes RBAC は Task 5 で Access Entry として付与する。

- [ ] **Step 1: Create `aws/eks/modules/iam_admin.tf`**

```hcl
# iam_admin.tf - IAM role for human kubectl admin access via Access Entry.
#
# Humans assume this role to obtain short-lived credentials for kubectl. The
# role itself only grants eks:DescribeCluster (needed for `aws eks
# update-kubeconfig`); Kubernetes RBAC permissions are granted separately via
# Access Entry (see access_entries.tf).
#
# Trust policy delegates to the account root. Whether an IAM user can
# actually assume this role is governed by sts:AssumeRole permissions on the
# user side (managed outside this repository).

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "eks_admin" {
  name                 = "eks-admin-${var.environment}"
  max_session_duration = 3600
  tags                 = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eks_admin_describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.eks_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/eks-${var.environment}"
      }
    ]
  })
}
```

- [ ] **Step 2: Validate & Plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected plan:

- `aws_iam_role.eks_admin` (新規、`name = "eks-admin-production"`、`max_session_duration = 3600`)
- `aws_iam_role_policy.eks_admin_describe_cluster` (新規、`Resource = "arn:aws:eks:ap-northeast-1:559744160976:cluster/eks-production"`)
- 計 2 resource added、その他差分なし

- [ ] **Step 3: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

Expected: 出力なし。

- [ ] **Step 4: Commit**

```bash
git add aws/eks/modules/iam_admin.tf
git commit -s -m "feat(aws/eks): add eks-admin-production IAM role for human kubectl

人間が kubectl admin として assume するための IAM role
eks-admin-production を新設する。Trust policy は account root に委譲し
（実際の assume 権限は IAM user 側で管理）、inline policy は kubeconfig
取得用の eks:DescribeCluster のみを付与する。Kubernetes RBAC は別途
Access Entry で付与する。"
```

---

### Task 4: 最小 EKS cluster を定義（access_entries / addons / node_groups は空 map）

**Files:**
- Modify: `aws/eks/modules/main.tf`

`module "eks"` 本体を書く。この時点では `eks_managed_node_groups` / `addons` / `access_entries` を空 map で渡し、cluster + IAM role + IRSA OIDC provider + CloudWatch Log group が作られる plan を確認する。

- [ ] **Step 1: Replace `aws/eks/modules/main.tf`**

```hcl
# main.tf - EKS cluster composition via terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Disable Secrets envelope encryption (spec decision: Out of Scope).
  # v21.19.0 enables encryption by default when `encryption_config != null`,
  # which would auto-create a KMS key + IAM policy + attachment via the
  # `kms` submodule. Set to `null` to skip the entire encryption_config
  # block and avoid unwanted KMS resources.
  encryption_config = null

  # Populated in Task 5 / 6 / 7
  access_entries          = {}
  eks_managed_node_groups = {}
  addons                  = null

  tags = var.common_tags
}
```

- [ ] **Step 2: Init & validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt validate
```

Expected:

- `init`: `terraform-aws-modules/eks/aws 21.19.0` と submodules がダウンロードされ、`.terraform.lock.hcl` が更新される
- `validate`: `Success! The configuration is valid.`

- [ ] **Step 3: Plan で cluster 周辺リソースを確認**

```bash
TG_TF_PATH=tofu terragrunt plan
```

Expected plan の主要リソース（v21 の internal 名前は `module.eks.aws_eks_cluster.this[0]` 形式）:

- `module.eks.aws_eks_cluster.this[0]`（`name = "eks-production"`、`version = "1.33"`、`endpoint_public_access = true`、`endpoint_private_access = true`、`authentication_mode = "API"`）
- `module.eks.aws_iam_role.this[0]`（cluster IAM role）
- `module.eks.aws_iam_role_policy_attachment.this["AmazonEKSClusterPolicy"]`
- `module.eks.aws_iam_openid_connect_provider.oidc_provider[0]`（IRSA OIDC）
- `module.eks.aws_cloudwatch_log_group.this[0]`（`/aws/eks/eks-production/cluster`、retention 7 日）
- `module.eks.aws_security_group.cluster[0]` および関連 SG rule
- Task 3 で追加済：`aws_iam_role.eks_admin`、`aws_iam_role_policy.eks_admin_describe_cluster`

VPC の data source 結果が `subnet_ids` に展開されており、3 件の subnet ID が known after apply ではなく具体的な値で表示されること。

`module.eks.module.kms.*` および `aws_iam_policy.cluster_encryption[0]` が **plan に出ないこと**を確認する（`encryption_config = null` で Secrets envelope encryption を spec 通り無効化しているため）。

- [ ] **Step 4: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/main.tf aws/eks/envs/production/.terraform.lock.hcl
git commit -s -m "feat(aws/eks): add minimal EKS cluster definition (control plane only)

terraform-aws-modules/eks/aws 21.19.0 を呼び出して production EKS
クラスタ eks-production の最小構成を定義する。endpoint は public +
private 両方有効、authentication_mode = API、
enable_cluster_creator_admin_permissions = false、control plane logs は
audit / authenticator のみ retention 7 日。

Secrets envelope encryption は spec 通り無効化（encryption_config =
null）。v21 のデフォルト挙動では encryption_config = {} で KMS key が
自動作成されるため、明示的に null を渡してその挙動を抑制する。

access_entries / eks_managed_node_groups / addons は後続 Task で
locals に分離して埋める。"
```

---

### Task 5: Access Entry を埋める（`eks-admin-production` を ClusterAdmin として登録）

**Files:**
- Create: `aws/eks/modules/access_entries.tf`
- Modify: `aws/eks/modules/main.tf`

Task 3 で作成した `eks-admin-production` role を `AmazonEKSClusterAdminPolicy` で Access Entry に登録する。CI 上の GitHub Actions apply role は Access Entry に登録しない（GitOps 原則）。

- [ ] **Step 1: Create `aws/eks/modules/access_entries.tf`**

```hcl
# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: only the human kubectl admin role is granted RBAC.
# The CI apply role (github-oidc-auth-production-github-actions-role)
# operates on AWS APIs only and never touches Kubernetes API; under the
# GitOps model, all Kubernetes-side changes flow through Flux CD.

locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Update `aws/eks/modules/main.tf` to reference `local.access_entries`**

`module "eks"` の `access_entries = {}` を `access_entries = local.access_entries` に変更する。

Old:
```hcl
  # Populated in Task 5 / 6 / 7
  access_entries          = {}
  eks_managed_node_groups = {}
  addons                  = null
```

New:
```hcl
  # Populated in Task 6 / 7
  access_entries          = local.access_entries
  eks_managed_node_groups = {}
  addons                  = null
```

- [ ] **Step 3: Validate & Plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected plan additions (vs Task 4):

- `module.eks.aws_eks_access_entry.this["human_admin"]` (`principal_arn = <admin role ARN>`、`type = "STANDARD"`)
- `module.eks.aws_eks_access_policy_association.this["human_admin_cluster_admin"]` (`policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"`、`access_scope.type = "cluster"`)

- [ ] **Step 4: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/access_entries.tf aws/eks/modules/main.tf
git commit -s -m "feat(aws/eks): grant ClusterAdmin RBAC to eks-admin-production via Access Entry

Access Entries モード（authentication_mode = API）で、Task 3 で作成した
eks-admin-production IAM role を AmazonEKSClusterAdminPolicy にバインド
する。GitOps 原則のため CI 上の apply role は Access Entry に登録せず、
Kubernetes RBAC は人間 kubectl デバッグ用の admin role のみ。"
```

---

### Task 6: Node group を埋める（`system` managed node group）

**Files:**
- Create: `aws/eks/modules/node_groups.tf`
- Modify: `aws/eks/modules/main.tf`

m6g.large × 2-4、AL2023_ARM_64、ON_DEMAND、3 AZ private subnet 配置の system node group を定義する。

- [ ] **Step 1: Create `aws/eks/modules/node_groups.tf`**

```hcl
# node_groups.tf - EKS managed node group definitions.
#
# Single "system" group on Graviton (ARM64) sized to host the platform
# components (Cilium / kube-proxy / CoreDNS / Prometheus-Operator / Loki /
# Tempo / OTel Collector / Beyla) plus headroom. Application workloads will
# be hosted on Karpenter-managed nodes (separate spec).

locals {
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Set EBS root volume size + type via block_device_mappings.
      # The top-level `disk_size` / `disk_type` arguments are silently
      # dropped by v21.19.0: `disk_type` is not in the v21 root schema's
      # eks_managed_node_groups object type (so it's an unknown key that
      # validates but never reaches AWS), and `disk_size` is forced to
      # `null` when `use_custom_launch_template = true` (the v21 default).
      # Using block_device_mappings is the only path that actually sets
      # gp3 / 50 GiB on the launch template.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda" # AL2023 root device
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }

      labels = {
        "node-role/system" = "true"
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        # SSM Session Manager access (no SSH key, port 22 closed)
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Do NOT attach AmazonEKS_CNI_Policy to the node IAM role.
      # v21.19.0's eks-managed-node-group submodule defaults
      # `iam_role_attach_cni_policy = true`, which would attach the policy
      # to the node role. We grant CNI permissions via IRSA instead (Task 7
      # creates the vpc-cni IRSA role bound to the aws-node ServiceAccount).
      # The trade-off: the aws-node DaemonSet must obtain its IAM
      # credentials via IRSA, which is the EKS best practice.
      iam_role_attach_cni_policy = false
    }
  }
}
```

- [ ] **Step 2: Update `aws/eks/modules/main.tf` to reference `local.eks_managed_node_groups`**

Old:
```hcl
  # Populated in Task 6 / 7
  access_entries          = local.access_entries
  eks_managed_node_groups = {}
  addons                  = null
```

New:
```hcl
  # Populated in Task 7
  access_entries          = local.access_entries
  eks_managed_node_groups = local.eks_managed_node_groups
  addons                  = null
```

- [ ] **Step 3: Validate & Plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected plan additions (vs Task 5):

- `module.eks.module.eks_managed_node_group["system"].aws_eks_node_group.this[0]` (`ami_type = "AL2023_ARM_64_STANDARD"`、`instance_types = ["m6g.large"]`、`capacity_type = "ON_DEMAND"`、`scaling_config = { min = 2, max = 4, desired = 2 }`)
- `module.eks.module.eks_managed_node_group["system"].aws_iam_role.this[0]` (node IAM role)
- `module.eks.module.eks_managed_node_group["system"].aws_iam_role_policy_attachment.this["AmazonEKSWorkerNodePolicy"]`
- `module.eks.module.eks_managed_node_group["system"].aws_iam_role_policy_attachment.this["AmazonEC2ContainerRegistryReadOnly"]`
- `module.eks.module.eks_managed_node_group["system"].aws_iam_role_policy_attachment.additional["ssm"]` (`policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"`)
- `module.eks.module.eks_managed_node_group["system"].aws_launch_template.this[0]` (`block_device_mappings` block で `device_name = "/dev/xvda"`, `ebs.volume_type = "gp3"`, `ebs.volume_size = 50`, `ebs.delete_on_termination = true`)
- `module.eks.module.eks_managed_node_group["system"].module.user_data.null_resource.validate_cluster_service_cidr` (v21 内部 boilerplate)

`AmazonEKS_CNI_Policy` が node IAM role に **付いていないこと** を確認する（`iam_role_attach_cni_policy = false` を明示しているため。IRSA で Task 7 にて別途付与する設計）。

- [ ] **Step 4: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/node_groups.tf aws/eks/modules/main.tf
git commit -s -m "feat(aws/eks): add system managed node group (m6g.large x 2-4, AL2023 ARM64)

platform components を載せる system 用 managed node group を 1 つ定義
する。Graviton (m6g.large) で AL2023 ARM64 AMI、ON_DEMAND 容量、3 AZ
の private subnet に分散。disk は gp3 50 GiB。SSM Session Manager
権限 (AmazonSSMManagedInstanceCore) を node IAM role に追加し、SSH key
は持たない。AmazonEKS_CNI_Policy は付与せず、IRSA で別途渡す（次 Task）。"
```

---

### Task 7: IRSA + Add-ons を埋める（vpc-cni / kube-proxy / coredns / aws-ebs-csi-driver / eks-pod-identity-agent）

**Files:**
- Create: `aws/eks/modules/addons.tf`
- Modify: `aws/eks/modules/main.tf`

`terraform-aws-modules/iam/aws ~> 6.0` の `iam-role-for-service-accounts-eks` submodule で vpc-cni と aws-ebs-csi-driver の IRSA role を作成し、`addons` map から `service_account_role_arn` で参照する。

- [ ] **Step 1: Create `aws/eks/modules/addons.tf`**

```hcl
# addons.tf - AWS-managed EKS add-ons and their IRSA roles.
#
# IRSA roles for vpc-cni and aws-ebs-csi-driver are created via the
# terraform-aws-modules/iam iam-role-for-service-accounts-eks submodule and
# wired into the addon definitions. kube-proxy / coredns / pod-identity-agent
# do not need IRSA.

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.0"

  name             = "eks-${var.environment}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = var.common_tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.0"

  name                  = "eks-${var.environment}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.common_tags
}

locals {
  cluster_addons = {
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.vpc_cni_irsa.iam_role_arn
    }
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
}
```

- [ ] **Step 2: Update `aws/eks/modules/main.tf` to reference `local.cluster_addons`**

Old:
```hcl
  # Populated in Task 7
  access_entries          = local.access_entries
  eks_managed_node_groups = local.eks_managed_node_groups
  addons                  = null
```

New:
```hcl
  access_entries          = local.access_entries
  eks_managed_node_groups = local.eks_managed_node_groups
  addons                  = local.cluster_addons
```

- [ ] **Step 3: Init & validate（新 module の取得）**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt validate
```

Expected: `terraform-aws-modules/iam/aws` と submodule `iam-role-for-service-accounts-eks` がダウンロードされ、`.terraform.lock.hcl` が更新される。

- [ ] **Step 4: Plan で IRSA + addons を確認**

```bash
TG_TF_PATH=tofu terragrunt plan
```

Expected plan additions (vs Task 6):

- `module.vpc_cni_irsa.aws_iam_role.this[0]` (`name = "eks-production-vpc-cni"`)
- `module.vpc_cni_irsa.aws_iam_role_policy_attachment.vpc_cni[0]` (`policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"`)
- `module.ebs_csi_irsa.aws_iam_role.this[0]` (`name = "eks-production-ebs-csi"`)
- `module.ebs_csi_irsa.aws_iam_role_policy_attachment.ebs_csi[0]` (`policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"`)
- `module.eks.aws_eks_addon.this["vpc-cni"]` (`service_account_role_arn = <vpc_cni_irsa role ARN>`)
- `module.eks.aws_eks_addon.this["kube-proxy"]`
- `module.eks.aws_eks_addon.this["coredns"]`
- `module.eks.aws_eks_addon.this["aws-ebs-csi-driver"]` (`service_account_role_arn = <ebs_csi_irsa role ARN>`)
- `module.eks.aws_eks_addon.this["eks-pod-identity-agent"]`

- [ ] **Step 5: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

- [ ] **Step 6: Commit**

```bash
git add aws/eks/modules/addons.tf aws/eks/modules/main.tf aws/eks/envs/production/.terraform.lock.hcl
git commit -s -m "feat(aws/eks): wire AWS-managed addons with IRSA for vpc-cni and ebs-csi

vpc-cni / kube-proxy / coredns / aws-ebs-csi-driver / eks-pod-identity-agent
の 5 つの AWS-managed addon を有効化する。vpc-cni と
aws-ebs-csi-driver には terraform-aws-modules/iam の
iam-role-for-service-accounts-eks submodule で作成した IRSA role を
service_account_role_arn 経由で渡す。conflict resolution は
create/update ともに OVERWRITE。"
```

---

### Task 8: Outputs を定義

**Files:**
- Create: `aws/eks/modules/outputs.tf`

cluster 情報、IRSA OIDC、IAM role ARN、admin role ARN を出力する。Karpenter 等の後続 stack が `terragrunt run-all` 時に参照しやすい形にしておく。

- [ ] **Step 1: Create `aws/eks/modules/outputs.tf`**

```hcl
# outputs.tf - Outputs for the EKS cluster module.

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Cluster security group created by EKS"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node security group"
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (for Karpenter / external addons)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "IRSA OIDC provider URL"
  value       = module.eks.oidc_provider
}

output "cluster_iam_role_arn" {
  description = "Cluster IAM role ARN"
  value       = module.eks.cluster_iam_role_arn
}

output "admin_role_arn" {
  description = "ARN of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.arn
}

output "admin_role_name" {
  description = "Name of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.name
}
```

> Node group の IAM role ARN は `module.eks.eks_managed_node_groups["system"].iam_role_arn` で参照できるが、現時点で consumer が居ないため output には載せない（YAGNI）。Karpenter spec で必要になった段階で追加する。

- [ ] **Step 2: Validate & Plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected: `validate` 成功。`plan` の Outputs セクションに上記すべての output が `(known after apply)` または計算値で表示される。リソース差分は Task 7 と同じ。

- [ ] **Step 3: Format check**

```bash
cd ../../..
terraform fmt -check -recursive aws/eks
```

- [ ] **Step 4: Commit**

```bash
git add aws/eks/modules/outputs.tf
git commit -s -m "feat(aws/eks): expose cluster, OIDC, and admin role outputs

cluster_name / cluster_endpoint / cluster_version / cluster_ca / SG ID /
OIDC provider ARN+URL / cluster IAM role ARN / admin role ARN+name を
output に追加する。Karpenter など後続 stack や、kubectl 用の
update-kubeconfig 自動化スクリプトから参照できるようにする。"
```

---

### Task 9: Renovate customManager で `cluster_version` を自動更新対象にする

**Files:**
- Modify: `.github/renovate.json`

`endoflife-date/amazon-eks` datasource に紐付ける `customManagers` セクションを追加する。production パスは既存ルールで automerge が無効化されるため、PR は手動 merge 必須。

- [ ] **Step 1: 現在の `.github/renovate.json` を確認**

```bash
cat .github/renovate.json | head -65
```

Expected: `packageRules` 配列が末尾の `}` の直前で閉じている。

- [ ] **Step 2: `.github/renovate.json` に `customManagers` を追加**

`packageRules` 配列の閉じ `]` の直後（末尾の `}` の直前）にカンマ付きで以下を挿入する。`packageRules` 配列の中身は変更しない。

Old (末尾付近):
```json
    {
      "description": "Track OpenTofu releases instead of Terraform for required_version",
      "matchDepTypes": ["required_version"],
      "matchDepNames": ["hashicorp/terraform"],
      "overridePackageName": "opentofu/opentofu"
    }
  ]
}
```

New:
```json
    {
      "description": "Track OpenTofu releases instead of Terraform for required_version",
      "matchDepTypes": ["required_version"],
      "matchDepNames": ["hashicorp/terraform"],
      "overridePackageName": "opentofu/opentofu"
    }
  ],

  "customManagers": [
    {
      "customType": "regex",
      "description": "EKS Kubernetes version pinned in env.hcl",
      "fileMatch": ["^aws/eks/envs/.+/env\\.hcl$"],
      "matchStrings": [
        "#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)(?:\\s+versioning=(?<versioning>\\S+))?\\s*\\n\\s*cluster_version\\s*=\\s*\"(?<currentValue>[^\"]+)\""
      ]
    }
  ]
}
```

- [ ] **Step 3: JSON syntax check**

```bash
python3 -m json.tool .github/renovate.json > /dev/null && echo OK
```

Expected: `OK`

- [ ] **Step 4: Renovate config validator（npx で実行）**

```bash
npx --yes --package=renovate -- renovate-config-validator .github/renovate.json
```

Expected: `Validating .github/renovate.json` → `Config validated successfully` (または同等のメッセージ)。エラーが出る場合は schema URL 参照（`https://docs.renovatebot.com/renovate-schema.json`）と照合。

- [ ] **Step 5: regex の self-test（matchStrings が env.hcl にマッチするか）**

```bash
python3 - <<'EOF'
import re

regex = r"#\s*renovate:\s*datasource=(?P<datasource>\S+)\s+depName=(?P<depName>\S+)(?:\s+versioning=(?P<versioning>\S+))?\s*\n\s*cluster_version\s*=\s*\"(?P<currentValue>[^\"]+)\""

with open("aws/eks/envs/production/env.hcl") as f:
    content = f.read()

m = re.search(regex, content)
assert m, "regex did not match env.hcl"
assert m.group("datasource") == "endoflife-date", f"unexpected datasource: {m.group('datasource')}"
assert m.group("depName") == "amazon-eks", f"unexpected depName: {m.group('depName')}"
assert m.group("versioning") == "loose", f"unexpected versioning: {m.group('versioning')}"
assert m.group("currentValue") == "1.33", f"unexpected currentValue: {m.group('currentValue')}"
print("OK", m.groupdict())
EOF
```

Expected: `OK {'datasource': 'endoflife-date', 'depName': 'amazon-eks', 'versioning': 'loose', 'currentValue': '1.33'}`

- [ ] **Step 6: Commit**

```bash
git add .github/renovate.json
git commit -s -m "feat(github/renovate): add customManager for EKS cluster_version

aws/eks/envs/*/env.hcl 内の cluster_version を endoflife-date /
amazon-eks datasource と紐付け、Renovate が自動で PR を起票できる
ようにする。production パスは既存 packageRules の matchPaths で
automerge 無効・⚠️ production ラベル付与が継続適用される。"
```

---

### Task 10: 全体 plan の最終レビュー

**Files:** （read only）

apply 前に、これまで追加したすべてのリソースを `terragrunt plan` で総点検する。`terraform fmt` の最終確認も行う。

- [ ] **Step 1: Format check（全 aws/eks）**

```bash
terraform fmt -check -recursive aws/eks
```

Expected: 出力なし。差分が出る場合は `terraform fmt -recursive aws/eks` で整形して再 commit。

- [ ] **Step 2: Plan して output を保存**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan -out=eks.tfplan 2>&1 | tee plan.log
```

Expected: `plan.log` の末尾に `Plan: <N> to add, 0 to change, 0 to destroy.` の行があり、`<N>` はおおよそ 25-35 程度（cluster + node group + IRSA × 2 + addons × 5 + access entry × 2 + IAM role × 2 等）。

注意：apply 時の参照のため `eks.tfplan` は手元に残す（gitignore 対象）。

- [ ] **Step 3: Plan 内容の手動チェックリスト**

`plan.log` を眺めて以下が含まれることを確認する：

- [ ] `module.eks.aws_eks_cluster.this[0]` で `name = "eks-production"`、`version = "1.33"`、`endpoint_public_access = true`、`endpoint_private_access = true`、`authentication_mode = "API"`
- [ ] `module.eks.aws_eks_cluster.this[0]` の `vpc_config.subnet_ids` に 3 件の subnet ID
- [ ] `module.eks.aws_eks_cluster.this[0]` の `enabled_cluster_log_types = ["audit", "authenticator"]`
- [ ] `module.eks.aws_cloudwatch_log_group.this[0]` の `retention_in_days = 7`
- [ ] `module.eks.module.eks_managed_node_group["system"]` 配下に node group + IAM role + launch template
- [ ] node IAM role に `AmazonEKS_CNI_Policy` が **付かない**こと（IRSA 経由のため）
- [ ] node IAM role に `AmazonSSMManagedInstanceCore` が付くこと
- [ ] `module.eks.aws_eks_addon.this` に 5 entries（`vpc-cni`, `kube-proxy`, `coredns`, `aws-ebs-csi-driver`, `eks-pod-identity-agent`）
- [ ] vpc-cni と aws-ebs-csi-driver の `service_account_role_arn` がそれぞれ IRSA module の role ARN を参照
- [ ] `module.eks.aws_eks_access_entry.this["human_admin"]` の `principal_arn` が `aws_iam_role.eks_admin.arn` を参照
- [ ] `aws_iam_role.eks_admin` の `name = "eks-admin-production"`、`max_session_duration = 3600`
- [ ] VPC（`aws/vpc/envs/production`）への変更差分は **無い**こと

問題があればここで該当 Task に戻って修正する。

- [ ] **Step 4: plan.log と eks.tfplan を gitignore に確認**

```bash
git check-ignore aws/eks/envs/production/eks.tfplan aws/eks/envs/production/plan.log
```

Expected: 両方が ignore 対象（既存 `.gitignore` で `*.tfplan` / `*.log` 系がカバーされていること）。ignore されない場合は plan ファイルを commit に含めないよう手動で除外する：

```bash
rm aws/eks/envs/production/eks.tfplan aws/eks/envs/production/plan.log
```

> apply は次 Task で別途 `terragrunt apply` で再生成して実行する（CI で apply する場合は plan を artifact 化するが、本 spec では手動 apply 想定）。

- [ ] **Step 5: 全体差分が clean か確認**

```bash
cd ../../..
git status
```

Expected: `nothing to commit, working tree clean`。残留差分があれば調査して整理。

> **Checkpoint**: ここまでで実装は完了。次の Task で実 AWS apply を行う。CI からの自動 apply ではなく、人間の手元で実行する想定。

---

### Task 11: Apply（実 AWS リソース作成）

**Files:** （実 AWS リソースを作成）

control plane 作成に 10〜15 分、node group 起動に追加で 3〜5 分、addon 適用に数分。合計 15〜25 分程度。

- [ ] **Step 1: Plan を再生成**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan -out=eks.tfplan
```

Expected: Task 10 Step 2 と同じ内容。差分があれば中断。

- [ ] **Step 2: Apply**

```bash
TG_TF_PATH=tofu terragrunt apply eks.tfplan
```

Expected: `Apply complete! Resources: <N> added, 0 changed, 0 destroyed.`

途中でエラーが出た場合：

| エラー | 対処 |
|---|---|
| `addon vpc-cni: ServiceLinkedRole error` | AWS account に EKS service-linked role が無い。`aws iam create-service-linked-role --aws-service-name eks.amazonaws.com` を実行して再 apply |
| `addon ... timed out` | 一時的な kube-system の立ち上がり遅延。`terragrunt apply` を再実行（idempotent） |
| `access_entry already exists` | （前回 apply の中断残骸）`aws eks list-access-entries --cluster-name eks-production` で確認、不要なものを `aws eks delete-access-entry` で消してから再 apply |

- [ ] **Step 3: Apply 後に output を確認**

```bash
TG_TF_PATH=tofu terragrunt output
```

Expected: `cluster_name = "eks-production"`、`cluster_endpoint = "https://...eks.amazonaws.com"`、`admin_role_arn = "arn:aws:iam::559744160976:role/eks-admin-production"` など全 output が表示される。

- [ ] **Step 4: tfplan ファイルを削除**

```bash
rm -f eks.tfplan plan.log
```

> commit step は無い（apply はインフラ操作のみで code 変更なし）。

---

### Task 12: 動作検証（kubectl 経路）

**Files:** （read only / kubectl 操作）

人間 kubectl 経路（`eks-admin-production` を assume → `aws eks update-kubeconfig` → `kubectl`）が機能するかを確認する。

- [ ] **Step 1: `eks-admin-production` を assume**

```bash
ADMIN_ROLE_ARN=$(cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw admin_role_arn)
echo "Admin role: $ADMIN_ROLE_ARN"

CREDS=$(aws sts assume-role \
  --role-arn "$ADMIN_ROLE_ARN" \
  --role-session-name kubectl-debug \
  --query 'Credentials' \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)

aws sts get-caller-identity
```

Expected: `Arn` が `arn:aws:sts::559744160976:assumed-role/eks-admin-production/kubectl-debug`。

assume に失敗する場合：実行している IAM user に `sts:AssumeRole` リソース権限がないため、IAM 側でその権限を付与してから再実行する（リポジトリ管理外の作業）。

- [ ] **Step 2: kubeconfig を生成**

```bash
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production
```

Expected: `Updated context arn:aws:eks:ap-northeast-1:559744160976:cluster/eks-production in ~/.kube/config`

- [ ] **Step 3: control plane 接続確認**

```bash
kubectl version
```

Expected: `Server Version: v1.33.x-eks-...` の行が表示される（`Client Version` のみで Server 取得失敗ならネットワーク or RBAC 問題）。

- [ ] **Step 4: ノード一覧確認**

```bash
kubectl get nodes -o wide
```

Expected: 

- 2 ノード `Ready` 状態
- AZ 分散（`topology.kubernetes.io/zone` ラベルが `ap-northeast-1a/c/d` のうち 2 個に分かれる、3 個目は今後の scale up で利用）
- INSTANCE-TYPE が `m6g.large`
- ARCHITECTURE が `arm64`

- [ ] **Step 5: kube-system の Pod が Running**

```bash
kubectl get pods -n kube-system
```

Expected: `aws-node-*` × 2、`kube-proxy-*` × 2、`coredns-*` × 2、`ebs-csi-controller-*` × 2、`ebs-csi-node-*` × 2、`eks-pod-identity-agent-*` × 2 が `Running`。

- [ ] **Step 6: IRSA がアノテートされていることを確認**

```bash
kubectl get sa -n kube-system aws-node -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
echo
kubectl get sa -n kube-system ebs-csi-controller-sa -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
echo
```

Expected: それぞれ `arn:aws:iam::559744160976:role/eks-production-vpc-cni`、`arn:aws:iam::559744160976:role/eks-production-ebs-csi`。

- [ ] **Step 7: 一時 credentials を破棄**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

> commit step は無い。

---

### Task 13: PR を Draft で作成

**Files:** （PR 作成のみ）

実装ブランチ（`feat-aws-eks-production`）を origin に push し、Draft PR を作成する。CI で `aws/eks/envs/production` を terragrunt stack として `terragrunt plan` が実行されることを確認する。

- [ ] **Step 1: `git status` と `git log` で push 内容を確認**

```bash
git status
git log --oneline origin/main..HEAD
```

Expected: 

- `git status`: working tree clean
- `git log`: Task 1〜9 で作成した 9 commit が並ぶ（spec の commit はプロジェクト方針上、本ブランチに同梱しないなら別ブランチに分離。同梱でも可）

> Spec ファイル（前ブランチ `feat-aws-eks-production` で既にコミット済の `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`）も同じ PR に含めて良い。本実装プラン（`docs/superpowers/plans/2026-05-01-aws-eks-production.md`）も同 PR に含める。

- [ ] **Step 2: 初回 push（upstream を origin に明示）**

```bash
git push -u origin HEAD
```

Expected: `branch 'feat-aws-eks-production' set up to track 'origin/feat-aws-eks-production'.`

- [ ] **Step 3: Draft PR を作成**

```bash
gh pr create --draft --title "feat(aws/eks): add production EKS cluster" --body "$(cat <<'EOF'
## Summary

- production VPC 上に EKS クラスタ `eks-production`（v1.33、m6g.large × 2-4 system node group、AWS-managed addons + IRSA、Access Entries モード）を新設
- Kubernetes admin RBAC は新設の `eks-admin-production` IAM role のみに Access Entry で付与（CI 上の apply role は AWS API のみ、Kubernetes RBAC は付与せず）
- Renovate `customManagers` で `cluster_version` を `endoflife-date/amazon-eks` datasource と紐付け

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- Plan: `docs/superpowers/plans/2026-05-01-aws-eks-production.md`

## Test plan

- [ ] CI で `aws/eks/envs/production` の `terragrunt plan` が PR 上で成功し plan 内容が PR コメントに掲載される
- [ ] `terragrunt apply` 後、`kubectl get nodes -o wide` で m6g.large × 2 ノードが Ready
- [ ] `kubectl get pods -n kube-system` で aws-node / kube-proxy / coredns / ebs-csi / pod-identity-agent が Running
- [ ] `kubectl get sa -n kube-system aws-node` の `eks.amazonaws.com/role-arn` アノテーションが IRSA role を指す
- [ ] `aws sts assume-role` で `eks-admin-production` を assume → `aws eks update-kubeconfig` → `kubectl version` が Server バージョンを返す
- [ ] Renovate dependency dashboard issue に `aws/eks/envs/production/env.hcl: amazon-eks` が現れる
EOF
)"
```

Expected: PR URL が標準出力に表示される（`https://github.com/panicboat/platform/pull/<N>`）。

- [ ] **Step 4: CI（terragrunt plan）の成否を確認**

```bash
gh pr checks --watch
```

Expected: `auto-label--deploy-trigger` から `reusable--terragrunt-executor` 経由で `aws/eks/envs/production` の `terragrunt plan` が走り、success で完了する。

PR コメントに plan 結果が貼られていることを GitHub UI で確認する：

```bash
gh pr view --comments | head -40
```

Expected: terragrunt plan の出力（追加リソース一覧）が PR comment として現れる。

> ここで CI plan が手元の Task 10 の plan と一致していれば実装完了。あとはレビュー → ready for review → merge の通常フロー。`apply` は merge 後の `auto-label--deploy-trigger` が main push をトリガに `reusable--terragrunt-executor` で `terragrunt apply` を実行する設計だが、本 spec は GitOps 原則のため **production への apply は手動（Task 11 で実施済）** を推奨する。`workflow-config.yaml` で auto-apply を有効にしている場合は事前にレビュー時間を確保する。