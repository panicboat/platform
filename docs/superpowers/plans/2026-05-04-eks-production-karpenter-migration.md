# EKS Production: Karpenter Migration (Plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws-eks-production` cluster の system pod を含めた全 pod を Karpenter NodePool 起動の Graviton 4 on-demand instance に集約し、bootstrap MNG (`t4g.small × 2`) は Karpenter controller pod のみ host する構成に移行する。

**Architecture:** 3-PR split (PR 1: AWS infra parallel add → USER GATE → PR 2: Kubernetes layer + Karpenter install → USER GATE: cordon/drain manual migration → PR 3: AWS cleanup)。`terraform-aws-modules/eks/aws//modules/karpenter` sub-module で SQS / EventBridge / IRSA / Node IAM / Instance Profile を一括 provision、Karpenter Helm chart 1.6.x で controller pod を bootstrap MNG に pin、EC2NodeClass + NodePool は kustomize で適用 (両方 `system-components` 命名)。

**Tech Stack:**
- Terraform: `terraform-aws-modules/eks/aws v21.19.0` (既存) + `terraform-aws-modules/eks/aws//modules/karpenter` (新)
- Karpenter: chart `oci://public.ecr.aws/karpenter/karpenter v1.6.5`、API `karpenter.k8s.aws/v1` (EC2NodeClass) / `karpenter.sh/v1` (NodePool)
- AWS resources: SQS interruption queue + EventBridge rules + Controller IRSA + Node IAM role + EC2 Instance Profile
- Cluster: AL2023 ARM64、Cilium 1.18.6 chaining mode + KPR、Flux 2.x GitOps

**Spec:** `docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md`

---

## File Structure

### PR 1 (AWS infrastructure parallel add)

| File | Action | Responsibility |
|---|---|---|
| `aws/eks/modules/variables.tf` | Modify | bootstrap-specific variables (`bootstrap_instance_types` / `bootstrap_min_size` / `bootstrap_max_size` / `bootstrap_desired_size` / `bootstrap_disk_size`) を追加。既存 `node_*` 変数は据え置き (PR 3 で削除) |
| `aws/eks/modules/node_groups.tf` | Modify | Add `karpenter-bootstrap` MNG block (`t4g.small × 2`、taint + label)。既存 `system` block 据え置き |
| `aws/eks/lookup/{terraform,variables,main,outputs}.tf` | Create (new shared module) | EKS cluster 情報を cross-stack で公開。`aws/vpc/lookup/` / `aws/route53/lookup/` 同型。`data "aws_eks_cluster"` を pass-through、outputs に `cluster.{name,oidc_provider_arn,oidc_provider}` を expose |
| `aws/karpenter/Makefile` + `root.hcl` | Create (new stack boilerplate) | `aws/alb/` 同型の terragrunt stack ルート。Makefile は `aws/eks/Makefile` mirror、`root.hcl` は `aws/eks/root.hcl` の `eks` → `karpenter` 置換 |
| `aws/karpenter/envs/production/{env.hcl,terragrunt.hcl}` | Create | production 環境設定。`Purpose=karpenter`、`go-getter //` notation で `karpenter/modules` を参照 |
| `aws/karpenter/modules/{terraform,variables,lookups,main,outputs}.tf` | Create | terragrunt module。`terraform-aws-modules/eks/aws//modules/karpenter v21.19.0` で SQS + EventBridge + Pod Identity Association + Controller IAM role + Node IAM + EC2 Instance Profile を一括 provision (Pod Identity 採用、IRSA ではない)。`aws/eks/lookup/` 経由で cluster_name 取得。outputs: `node_role_name` + `interruption_queue_name` |

### PR 2 (Kubernetes layer)

| File | Action | Responsibility |
|---|---|---|
| `kubernetes/components/karpenter/production/namespace.yaml` | Create | `karpenter` namespace |
| `kubernetes/components/karpenter/production/helmfile.yaml` | Create | Karpenter Helm release (chart 1.6.5、namespace=karpenter)、bootstrap MNG への nodeSelector + toleration |
| `kubernetes/components/karpenter/production/values.yaml.gotmpl` | Create | Helm chart values (`settings.clusterName` / `settings.interruptionQueue` / `nodeSelector` / `tolerations` / `controller.resources`)。**IRSA annotation 不要** (Pod Identity Association が SA-to-role mapping を直接管理)、ServiceAccount は chart デフォルト名 `karpenter` で作成 |
| `kubernetes/components/karpenter/production/kustomization/kustomization.yaml` | Create | EC2NodeClass + NodePool を bundle |
| `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml` | Create | `EC2NodeClass system-components` (AMI `al2023@latest`、subnet `Tier=private`、SG cluster + node、role 参照、blockDeviceMappings gp3 30 GiB、IMDSv2) |
| `kubernetes/components/karpenter/production/kustomization/nodepool.yaml` | Create | `NodePool system-components` (requirements + disruption + limits) |
| `kubernetes/helmfile.yaml.gotmpl` | Modify | production env values に `karpenter.{nodeRoleName,interruptionQueueName}` 追加 (Pod Identity のため `controllerRoleArn` 不要) |
| `kubernetes/manifests/production/karpenter/manifest.yaml` | Auto-generated | `make hydrate ENV=production` の出力 |
| `kubernetes/manifests/production/karpenter/kustomization.yaml` | Auto-generated | hydrate の出力 |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | Modify (auto) | hydrate で karpenter namespace が追加 |
| `kubernetes/manifests/production/kustomization.yaml` | Modify (auto) | hydrate で 8 component (cilium / gateway-api / keda / metrics-server / aws-load-balancer-controller / external-dns / **karpenter** / 00-namespaces) を resources として参照 |
| `kubernetes/README.md` | Modify | Production Operations 更新 (Cluster overview / Foundation addon operations / Troubleshooting) |

### PR 3 (AWS cleanup)

| File | Action | Responsibility |
|---|---|---|
| `aws/eks/modules/node_groups.tf` | Modify | `system` block 削除。`karpenter-bootstrap` のみ残す |
| `aws/eks/modules/variables.tf` | Modify | `node_instance_types` / `node_min_size` / `node_max_size` / `node_desired_size` / `node_disk_size` の 5 vars を削除 (bootstrap 用 vars は残す) |

---

## Task 0: 前提条件の確認

**Files:** （read only）

実装前に prerequisite が揃っていることを確認する。

- [ ] **Step 1: worktree とブランチを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-migration
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/eks-production-karpenter-migration`

- [ ] **Step 2: 必須 CLI 確認**

```bash
flux --version
kubectl version --client | head -1
helmfile --version
helm version --short
kustomize version
which terragrunt
```

Expected: 各 CLI が version を返す。

- [ ] **Step 3: Karpenter Helm chart の reachability 確認**

```bash
helm pull oci://public.ecr.aws/karpenter/karpenter --version "1.6.5" --untar --untardir /tmp/karpenter-chart-check 2>&1 | tail -3
ls /tmp/karpenter-chart-check/karpenter/Chart.yaml
rm -rf /tmp/karpenter-chart-check
```

Expected: `Pulled: public.ecr.aws/karpenter/karpenter:1.6.5` が表示、Chart.yaml が存在。

- [ ] **Step 4: AWS 認証確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
aws sts get-caller-identity --query Account --output text
```

Expected: `559744160976`

- [ ] **Step 5: 現状 node 状態確認**

```bash
kubectl get nodes -L eks.amazonaws.com/nodegroup
kubectl get pods -A -o wide --field-selector=status.phase=Running | awk 'NR>1 {print $8}' | sort | uniq -c
```

Expected: system × 2 (`m6g.large`)、各 node に 10-20 pod 配置。

---

# PR 1 implementation: AWS infrastructure parallel add

## Task 1: aws/eks/modules/variables.tf に bootstrap-specific variables を追加

**Files:**
- Modify: `aws/eks/modules/variables.tf`

`karpenter-bootstrap` MNG 用の variables を追加。既存 `node_*` 変数は据え置き (PR 3 で削除)。

- [ ] **Step 1: variables.tf の末尾 (`log_retention_days` の後) に bootstrap 用 variables を追加**

`aws/eks/modules/variables.tf` の末尾に append:

```hcl

variable "bootstrap_instance_types" {
  description = "Instance types for the karpenter-bootstrap managed node group (only hosts Karpenter controller pods)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "bootstrap_desired_size" {
  description = "Desired number of nodes in the karpenter-bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_min_size" {
  description = "Minimum number of nodes in the karpenter-bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_max_size" {
  description = "Maximum number of nodes in the karpenter-bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_disk_size" {
  description = "EBS volume size (GiB) for karpenter-bootstrap node group"
  type        = number
  default     = 20
}
```

- [ ] **Step 2: terraform validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add aws/eks/modules/variables.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): add karpenter-bootstrap MNG variables

Plan 2 で karpenter-bootstrap MNG (t4g.small × 2) を新設するため、
専用 variables を追加する:
- bootstrap_instance_types (default: ["t4g.small"])
- bootstrap_desired_size / bootstrap_min_size / bootstrap_max_size
  (default: 2/2/2、HA 用 2 AZ 分散)
- bootstrap_disk_size (default: 20、Karpenter pod のみ host するので
  既存 system MNG の 50 GiB より縮小)

既存 node_* 変数は PR 3 (system MNG 撤去) まで据え置き。
EOF
)"
```

---

## Task 2: aws/eks/modules/node_groups.tf に karpenter-bootstrap MNG block を追加

> ⚠️ **Lessons Learned L1 / L7 参照**: 実装は course correction v2 で `aws/karpenter/modules/main.tf` の standalone `eks-managed-node-group` submodule に移動 (Task 4 内で provision)。本 task の文章は brainstorming v1 当時の建付けで残されている (historical evidence)。命名 `karpenter-bootstrap` (HCL identifier は `karpenter_bootstrap`) は役割不明瞭で、`karpenter-controller-host` 等への改名は後続 plan で扱う。
>
> ⚠️ **Lessons Learned L2 / L5 参照**: 実装で standalone submodule を採用した結果、cluster info (endpoint / CA cert / service CIDR / IP family) と node SG (`eks-${cluster_name}-node`) の **明示渡しが必要** だった。Task 3 (aws/eks/lookup) と Task 4 Step 9 (aws/karpenter/modules/main.tf) は merge 後の hotfix で更新済。

**Files:**
- Modify: `aws/eks/modules/node_groups.tf`

`eks_managed_node_groups` map に `karpenter-bootstrap` を追加。既存 `system` block は **一切変更しない**。

- [ ] **Step 1: 現状の node_groups.tf 確認**

```bash
grep -n "^locals\|^  eks_managed_node_groups\|^    system\|^    karpenter" aws/eks/modules/node_groups.tf
```

Expected: `system` block のみ存在、`karpenter-bootstrap` は無い。

- [ ] **Step 2: `system` block の `}` の直後（`}` で `eks_managed_node_groups` map を閉じる前）に `karpenter-bootstrap` block を追加**

`aws/eks/modules/node_groups.tf` の `system` block の閉じ括弧の直後 (locals の閉じ括弧の前) に以下を挿入:

```hcl
    karpenter-bootstrap = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.bootstrap_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.bootstrap_min_size
      max_size     = var.bootstrap_max_size
      desired_size = var.bootstrap_desired_size

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.bootstrap_disk_size
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }

      labels = {
        "node-role/karpenter-bootstrap" = "true"
      }

      taints = {
        karpenter-controller = {
          key    = "karpenter.sh/controller"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        # SSM Session Manager access (no SSH key, port 22 closed)
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Same rationale as system MNG: CNI permissions are granted via IRSA
      # (vpc-cni IRSA bound to aws-node ServiceAccount), not via the node
      # IAM role.
      iam_role_attach_cni_policy = false
    }
```

- [ ] **Step 3: terraform validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: terragrunt plan で差分確認 (apply はしない)**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(will be created|Plan:)" | head -10
cd ../../../..
```

Expected: `module.eks.module.eks_managed_node_group["karpenter-bootstrap"].*` 関連リソースが `will be created` で表示される (launch template、ASG、IAM role、IAM role policy attachments 等で約 10-15 リソース)。

If plan fails on credentials, that's NOT a blocker — Step 3 (validate) is the gating check. Report plan output as-is.

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/node_groups.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): add karpenter-bootstrap MNG (parallel to system)

Plan 2 PR 1 として karpenter-bootstrap managed node group を追加する。
Karpenter controller pod の専用 host として t4g.small × 2 (2 AZ) で
provision する。

主な設定:
- instance_types: var.bootstrap_instance_types (= ["t4g.small"])
- capacity_type: ON_DEMAND
- ami_type: AL2023_ARM_64_STANDARD (system MNG と同じ)
- block_device_mappings: gp3 20 GiB
- labels: { node-role/karpenter-bootstrap = "true" } (Karpenter pod の
  nodeSelector で参照)
- taints: { karpenter.sh/controller = "true:NoSchedule" } (Karpenter
  pod 以外を排除、Karpenter pod は対応 toleration を持つ)
- iam_role_attach_cni_policy: false (system MNG と同じ、IRSA 経由)

既存 system block は一切変更せず、本 PR は parallel add のみ。
PR 3 で system block を撤去する。
EOF
)"
```

---

## Task 3: aws/eks/lookup/ shared module を新設 (cross-stack lookup)

**Files (all NEW):**
- Create: `aws/eks/lookup/terraform.tf`
- Create: `aws/eks/lookup/variables.tf`
- Create: `aws/eks/lookup/main.tf`
- Create: `aws/eks/lookup/outputs.tf`

`aws/vpc/lookup/` / `aws/route53/lookup/` 同型の cross-stack shared module。`aws/karpenter/` (本 plan) や将来の他 stack が EKS cluster 情報を参照するための 1 元化。

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p aws/eks/lookup
```

- [ ] **Step 2: terraform.tf 作成**

`aws/eks/lookup/terraform.tf`:

```hcl
# terraform.tf - Version constraints for the EKS lookup module.
# This module does not declare a provider; consumers supply the aws provider.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
```

- [ ] **Step 3: variables.tf 作成**

`aws/eks/lookup/variables.tf`:

```hcl
# variables.tf - Inputs for the EKS lookup module.

variable "environment" {
  description = "Environment name used to locate the EKS cluster (matches the producer's `eks-$${environment}` naming convention)."
  type        = string
}
```

- [ ] **Step 4: main.tf 作成**

`aws/eks/lookup/main.tf`:

```hcl
# main.tf - Lookup of the EKS cluster by name convention `eks-${environment}`.
#
# Consumers reference outputs.cluster.{name, oidc_provider_arn, oidc_provider}.
# Pod Identity-based stacks (e.g., aws/karpenter/) only need cluster.name;
# IRSA-based stacks would also use oidc_provider_arn / oidc_provider.

data "aws_eks_cluster" "this" {
  name = "eks-${var.environment}"
}
```

- [ ] **Step 5: outputs.tf 作成**

`aws/eks/lookup/outputs.tf`:

```hcl
# outputs.tf - Pass-through outputs of the underlying data source.

output "cluster" {
  description = "EKS cluster information (pass-through of aws_eks_cluster data source)."
  value = {
    name              = data.aws_eks_cluster.this.name
    arn               = data.aws_eks_cluster.this.arn
    endpoint          = data.aws_eks_cluster.this.endpoint
    # OIDC provider ARN is constructed from the issuer URL by AWS provider.
    # IRSA consumers use oidc_provider_arn; Pod Identity consumers don't need it.
    oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"
    oidc_provider     = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  }
}

data "aws_caller_identity" "current" {}
```

- [ ] **Step 6: terraform validate**

```bash
cd aws/eks/lookup
terraform init -backend=false 2>&1 | tail -3
terraform validate
cd ../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add aws/eks/lookup/
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): add lookup module for cross-stack cluster info

aws/karpenter/ 等の他 stack が EKS cluster 情報 (cluster_name /
oidc_provider_arn / oidc_provider) を参照するための shared lookup
module を新設する。aws/vpc/lookup/ / aws/route53/lookup/ パターンに
倣い、data resource を pass-through する。

consumer は module "eks" { source = "../../eks/lookup"; environment =
... } で参照し、outputs.cluster.{name, arn, endpoint, oidc_provider_arn,
oidc_provider} を取得する。Pod Identity-based stack は cluster.name
のみで足りるが、IRSA-based stack 用に oidc_provider 系も pass-through。
EOF
)"
```

---

## Task 4: aws/karpenter/ 新 stack を作成 (Pod Identity)

**Files (all NEW):**
- Create: `aws/karpenter/Makefile`
- Create: `aws/karpenter/root.hcl`
- Create: `aws/karpenter/envs/production/env.hcl`
- Create: `aws/karpenter/envs/production/terragrunt.hcl`
- Create: `aws/karpenter/modules/terraform.tf`
- Create: `aws/karpenter/modules/variables.tf`
- Create: `aws/karpenter/modules/lookups.tf`
- Create: `aws/karpenter/modules/main.tf`
- Create: `aws/karpenter/modules/outputs.tf`

Karpenter の AWS-side infra (SQS / EventBridge / Pod Identity / Node IAM / EC2 Instance Profile) を独立 terragrunt stack として provision する。Plan 1c-β `aws/alb/` 同型の構造。

> ⚠️ **重要**: 本 Task は Plan 1c-β `aws/alb/` の boilerplate を流用する。`Makefile` / `root.hcl` / `terragrunt.hcl` / `terraform.tf` / `variables.tf` の構造は `aws/alb/` を **structural template** として参照、`alb` → `karpenter` の置換 + Karpenter 固有の lookups + main + outputs だけが本質的差分。

### `aws/alb/` を structural template として使用

開始前に reference 構造を確認:

```bash
ls aws/alb/
ls aws/alb/envs/production/
ls aws/alb/modules/
cat aws/alb/root.hcl
cat aws/alb/Makefile | head -20
cat aws/alb/envs/production/env.hcl
cat aws/alb/envs/production/terragrunt.hcl
cat aws/alb/modules/terraform.tf
cat aws/alb/modules/variables.tf
```

### Step 1: ディレクトリ作成

```bash
mkdir -p aws/karpenter/envs/production aws/karpenter/modules
```

### Step 2: Makefile 作成 (aws/alb/Makefile mirror)

`aws/karpenter/Makefile` — `aws/alb/Makefile` をそのままコピーし、`ALB - Terragrunt Commands` → `Karpenter - Terragrunt Commands` に置換。

```bash
sed 's/ALB - Terragrunt Commands/Karpenter - Terragrunt Commands/' aws/alb/Makefile > aws/karpenter/Makefile
```

確認: `cat aws/karpenter/Makefile | head -3` で `# Makefile for ALB` が `# Makefile for Karpenter` に書き換わっているか... もし ALB のままなら追加で:

```bash
sed -i '' 's|^# Makefile for ALB|# Makefile for Karpenter|' aws/karpenter/Makefile
```

### Step 3: root.hcl 作成 (aws/alb/root.hcl mirror)

`aws/karpenter/root.hcl`:

```hcl
# root.hcl - Root Terragrunt configuration for Karpenter
# This file contains common settings shared across all environments

locals {
  # Project metadata
  project_name = "karpenter"

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
    Component   = "karpenter"
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

    # Service-specific path: karpenter/<environment>/terraform.tfstate
    key    = "platform/karpenter/${local.environment}/terraform.tfstate"
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

### Step 4: envs/production/env.hcl 作成

`aws/karpenter/envs/production/env.hcl`:

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  # Environment-specific settings
  environment = "production"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "karpenter"
    Owner       = "panicboat"
  }
}
```

### Step 5: envs/production/terragrunt.hcl 作成

`aws/karpenter/envs/production/terragrunt.hcl`:

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
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//karpenter/modules"
}

# Input variables for the module
inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "karpenter"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

### Step 6: modules/terraform.tf 作成 (`aws/alb/modules/terraform.tf` 同型)

`aws/karpenter/modules/terraform.tf`:

```hcl
# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.43.0"
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

### Step 7: modules/variables.tf 作成

`aws/karpenter/modules/variables.tf`:

```hcl
# variables.tf - Inputs for the karpenter module.

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
}
```

### Step 8: modules/lookups.tf 作成 (cross-stack EKS lookup)

`aws/karpenter/modules/lookups.tf`:

```hcl
# lookups.tf - External stack lookups.

module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

### Step 9: modules/main.tf 作成 (Karpenter sub-module + Pod Identity)

> ⚠️ **Lessons Learned L3 参照**: 本 step の `module "karpenter"` には `enable_inline_policy = true` を必ず追加する (Karpenter v1.x の controller policy が customer-managed policy size 上限 6,144 chars を超えるため)。merge 後の hotfix #272 で追加済。
>
> ⚠️ **Lessons Learned L2 / L5 参照**: 本 step では Karpenter sub-module 単独を呼んでいるが、course correction v2 で `aws/karpenter/modules/main.tf` には `module "karpenter_bootstrap"` (standalone `eks-managed-node-group` submodule) も追加され、その引数として cluster info (`cluster_endpoint` / `cluster_auth_base64` / `cluster_service_cidr` / `cluster_ip_family`) と node SG (`vpc_security_group_ids = [module.eks.cluster.node_security_group_id]`) を `aws/eks/lookup` から明示渡しする必要がある (parent module が auto-wire する 5 値を standalone submodule では明示する必要があるため)。merge 後の hotfix #275 で追加済。

`aws/karpenter/modules/main.tf`:

```hcl
# main.tf - Karpenter AWS-side infrastructure (Pod Identity authentication).
#
# terraform-aws-modules/eks/aws//modules/karpenter sub-module で:
# - Controller IAM role + EKS Pod Identity Association (karpenter:karpenter
#   ServiceAccount → IAM role)
# - Node IAM role + EC2 Instance Profile (Karpenter が起動する EC2 が
#   assume する。WorkerNode 用 managed policies + SSM)
# - SQS interruption queue
# - EventBridge rules (Spot interruption / Health / State change /
#   Instance rebalance の 4 rule、SQS が target)
#
# Plan 2 では capacity-type=on-demand のみだが、SQS/EventBridge も
# provision することで将来 spot NodePool 追加時の AWS infra 変更を
# 不要にする (Future Specs: workload-spot NodePool 参照)。
#
# Authentication mode は Pod Identity を採用 (sub-module v21.19.0 default)。
# Pod Identity Association が karpenter:karpenter ServiceAccount を IAM role
# に紐付けるため、Helm chart の serviceAccount.annotations に IRSA 情報を
# 入れる必要がない。

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.19.0"

  cluster_name = module.eks.cluster.name

  # Pod Identity を採用 (sub-module v21.19.0 default。明示的に true を指定)
  create_pod_identity_association = true

  # Karpenter ServiceAccount は karpenter namespace に置く
  # (kubernetes/components/karpenter/production/values.yaml.gotmpl と一致)
  namespace            = "karpenter"
  service_account      = "karpenter"

  # Node role: SSM Session Manager access も許可 (system MNG と同じ運用)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.common_tags
}
```

> ⚠️ `namespace` / `service_account` argument 名は terraform-aws-modules/eks v21.19.0 の karpenter sub-module の実 interface に合わせること。`gh api` 等で v21.19.0 の `modules/karpenter/variables.tf` を直接確認し、もし違っていたら正しい argument 名 (例: `pod_identity_namespace` / `pod_identity_service_account` 等) に書き換えること。

### Step 10: modules/outputs.tf 作成

`aws/karpenter/modules/outputs.tf`:

```hcl
# outputs.tf - Outputs for the karpenter module.

output "node_role_name" {
  description = "Node IAM role name for EC2 instances launched by Karpenter (referenced by EC2NodeClass.spec.role)"
  value       = module.karpenter.node_iam_role_name
}

output "interruption_queue_name" {
  description = "SQS queue name for EC2 interruption events (referenced by Helm chart values.settings.interruptionQueue)"
  value       = module.karpenter.queue_name
}
```

> Pod Identity 採用のため `controller_role_arn` は **kubernetes 側で参照不要** (Pod Identity Association が SA-to-role mapping を直接管理)。outputs にも公開しない。Helm chart の serviceAccount.annotations に `eks.amazonaws.com/role-arn` を入れる必要がないため。

### Step 11: aws/eks との pattern 整合確認

```bash
diff <(grep "remote_state" aws/eks/root.hcl -A 20) <(grep "remote_state" aws/karpenter/root.hcl -A 20) || true
diff <(grep "include " aws/eks/envs/production/terragrunt.hcl -A 3) <(grep "include " aws/karpenter/envs/production/terragrunt.hcl -A 3) || true
grep "version" aws/eks/modules/terraform.tf | head -3
grep "version" aws/karpenter/modules/terraform.tf | head -3
```

Expected: bucket / dynamodb_table / `include "root" / "env"` / AWS provider version `6.43.0` が aws/eks と整合する。差異があれば aws/karpenter 側を aws/eks に合わせる。

### Step 12: terragrunt init + validate

```bash
cd aws/karpenter/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -5
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: init で provider download → success、validate で `Success! The configuration is valid.`

### Step 13: terragrunt plan で差分確認

```bash
cd aws/karpenter/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(will be created|Plan:)" | head -30
cd ../../../..
```

Expected:
- `module.karpenter.aws_cloudwatch_event_rule.this[*]` (4 件)
- `module.karpenter.aws_cloudwatch_event_target.this[*]` (4 件)
- `module.karpenter.aws_iam_instance_profile.this[0]`
- `module.karpenter.aws_iam_policy.controller[0]` + `aws_iam_role.controller[0]` + `aws_iam_role_policy_attachment.controller[0]`
- `module.karpenter.aws_eks_pod_identity_association.this[0]`
- `module.karpenter.aws_iam_role.node[0]` + `aws_iam_role_policy_attachment.node[*]`
- `module.karpenter.aws_sqs_queue.this[0]` + `aws_sqs_queue_policy.this[0]`

Plan: 約 20-25 リソース追加。

If plan fails on credentials, report and proceed.

### Step 14: Commit

```bash
git add aws/karpenter/
git commit -s -m "$(cat <<'EOF'
feat(aws/karpenter): add new stack with Karpenter sub-module + Pod Identity

Karpenter の AWS リソースを独立 stack として新設する。Plan 1c-β
aws/alb/ 同型の構造 (Makefile / root.hcl / envs/production/ /
modules/)。

Authentication mode は Pod Identity を採用 (terraform-aws-modules/eks
v21.19.0 karpenter sub-module の default)。Pod Identity Association
が karpenter:karpenter ServiceAccount を controller IAM role に直接
紐付けるため、Helm chart 側で eks.amazonaws.com/role-arn annotation を
付ける必要がない。

Cross-stack lookup として aws/eks/lookup module 経由で cluster_name を
取得。

provision されるリソース (約 20-25):
- Controller IAM role + EKS Pod Identity Association
- Node IAM role + EC2 Instance Profile (WorkerNode managed policies +
  AmazonSSMManagedInstanceCore)
- SQS interruption queue
- EventBridge rules (Spot Interruption / Health / Instance Rebalance /
  State Change の 4 rule、SQS が target)

outputs: node_role_name (EC2NodeClass.spec.role) +
interruption_queue_name (Helm chart settings.interruptionQueue)。
controller_role_arn は Pod Identity のため kubernetes 側で不要。
EOF
)"
```

---

## Task 5: PR 1 push + Draft PR 作成

**Files:** （git 操作のみ）

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: spec commits 3 件 + 実装 commits 4 件 = 約 7 commits:

```
<sha> feat(aws/karpenter): add new stack with Karpenter sub-module + Pod Identity
<sha> feat(aws/eks): add lookup module for cross-stack cluster info
<sha> feat(aws/eks): add karpenter-bootstrap MNG (parallel to system)
<sha> feat(aws/eks): add karpenter-bootstrap MNG variables
<sha> docs(eks): split Karpenter into aws/karpenter/ stack + Pod Identity (course correction)
<sha> docs(eks): rename Plan 2 NodePool/EC2NodeClass from default to system-components
<sha> docs(eks): add Plan 2 (Karpenter migration) design spec
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-karpenter-migration
```

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --base main \
  --title "feat(aws): Plan 2 PR 1 — Karpenter AWS infra (bootstrap MNG + sub-module)" \
  --body "$(cat <<'EOF'
## Summary

Plan 2 (Karpenter migration) の **PR 1** （AWS infrastructure 部分）。Kubernetes 側 (PR 2) は本 PR merge → CI が `aws/eks` + `aws/karpenter` apply → terragrunt outputs 取得後の **follow-up PR** で扱う。System MNG の撤去は migration 完了後の **PR 3** で実施。

### Code 変更（本 PR）

- `aws/eks/modules/variables.tf`: `bootstrap_*` 変数 5 件追加 (instance_types / desired_size / min_size / max_size / disk_size)
- `aws/eks/modules/node_groups.tf`: `karpenter-bootstrap` MNG block 追加 (`t4g.small × 2`、taint `karpenter.sh/controller=true:NoSchedule`、label `node-role/karpenter-bootstrap=true`)。既存 `system` block 据え置き
- `aws/eks/lookup/`: 新 shared module。`data "aws_eks_cluster"` を pass-through。`aws/karpenter/` から cluster_name を参照、将来の他 stack も consume 可能
- `aws/karpenter/`: 新 terragrunt stack (Makefile + root.hcl + envs/production/ + modules/)。`terraform-aws-modules/eks/aws//modules/karpenter v21.19.0` で SQS / EventBridge / Pod Identity Association + Controller IAM role / Node IAM / EC2 Instance Profile を一括 provision

### Authentication mode: Pod Identity

Plan 2 spec の Decision 5 改訂で **Pod Identity** を採用 (sub-module v21.19.0 default)。`karpenter:karpenter` ServiceAccount は Pod Identity Association 経由で controller IAM role を assume する。Helm chart の serviceAccount.annotations に `eks.amazonaws.com/role-arn` を入れる必要がないため kubernetes 側がシンプル。Plan 1c-β で IRSA 採用済の ALB Controller / ExternalDNS は据え置き、cluster 内に IRSA + Pod Identity 混在状態が一時的に存在する。

### Documents

- Plan: `docs/superpowers/plans/2026-05-04-eks-production-karpenter-migration.md`
- Spec: `docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md`

### Out of scope（PR 2 / PR 3 で扱う）

- `kubernetes/components/karpenter/production/` (PR 2)
- `kubernetes/helmfile.yaml.gotmpl` の karpenter.* 値転記 (PR 2)
- `kubernetes/manifests/production` の hydrate 結果 (PR 2)
- `kubernetes/README.md` 更新 (PR 2)
- 既存 `system` MNG block 撤去 (PR 3、migration 完了後)

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] `aws/eks/envs/production` で `terragrunt validate` 成功
- [x] `aws/eks/envs/production` で `terragrunt plan` が `karpenter-bootstrap` MNG + Karpenter sub-module 関連リソース (約 20-25 件) を `will be created` で表示

### Cluster-level (CI / operator 実行、merge 後)

- [ ] CI が `Deploy Terragrunt (eks:production)` + `Deploy Terragrunt (karpenter:production)` apply 完了 (2 stack)
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup` で 4 node Ready (`system × 2 = m6g.large` + `karpenter-bootstrap × 2 = t4g.small`)
- [ ] `aws iam list-roles --query "Roles[?contains(RoleName, 'KarpenterController')]"` で Karpenter controller IAM role 存在
- [ ] `aws eks list-pod-identity-associations --cluster-name eks-production --namespace karpenter` で karpenter ServiceAccount に Pod Identity Association が紐付いている
- [ ] `aws sqs get-queue-attributes --queue-url <interruption_queue_url>` で queue 存在
- [ ] `cd aws/karpenter/envs/production && terragrunt output -json` で 2 values (`node_role_name` / `interruption_queue_name`) 取得可能 → PR 2 で利用
EOF
)" 2>&1 | tail -3
```

Expected: PR URL（`https://github.com/panicboat/platform/pull/<num>`）が表示。

---

## (USER) PR 1 review + merge

**Files:** （CI 自動 + cluster 状態変更）

PR 1 を review、ready 化、merge する。CI が aws/eks の terragrunt apply を実行する。

- [ ] **Step 1: PR 1 を Ready for review に変更**

```bash
gh pr ready
```

- [ ] **Step 2: review approve + merge**

```bash
gh pr review --approve
gh pr merge --squash --delete-branch
```

- [ ] **Step 3: CI workflow watch**

```bash
gh run watch
```

Expected: `Deploy Terragrunt (eks:production)` が success で完了。

- [ ] **Step 4: Cluster 状態確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get nodes -L eks.amazonaws.com/nodegroup
```

Expected: 4 node 全部 Ready:
```
NAME                                              ...   GROUP
ip-10-0-XX-XX.ap-northeast-1.compute.internal    ...   system
ip-10-0-YY-YY.ap-northeast-1.compute.internal    ...   system
ip-10-0-AA-AA.ap-northeast-1.compute.internal    ...   karpenter-bootstrap
ip-10-0-BB-BB.ap-northeast-1.compute.internal    ...   karpenter-bootstrap
```

- [ ] **Step 5: AWS 側 リソース確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
aws iam list-roles --query "Roles[?contains(RoleName, 'KarpenterController')].{Name:RoleName,Arn:Arn}" --output table
aws iam list-roles --query "Roles[?contains(RoleName, 'KarpenterNode')].{Name:RoleName,Arn:Arn}" --output table
aws sqs list-queues --queue-name-prefix eks-production --output table
aws events list-rules --name-prefix eks-production --query 'Rules[].Name' --output table
```

Expected:
- KarpenterController IRSA role + KarpenterNode IAM role 存在
- SQS queue `eks-production` (or similar prefix) 存在
- EventBridge rules 4 件存在 (Spot Interrupt / Health / Rebalance / State Change)

PR 1 完了。次に Task 6 で terragrunt outputs を取得し、PR 2 の作成へ進む。

---

# PR 2 implementation: Kubernetes layer

## Task 6: terragrunt outputs 取得（controller）

**Files:** （read only）

PR 1 merge + CI apply 後に `aws/karpenter/` stack の terragrunt outputs から Karpenter 関連 2 値を取得する (Pod Identity 採用のため `controller_role_arn` は kubernetes 側で不要、よって 2 値)。

- [ ] **Step 1: PR 2 用 worktree branch を sync**

`feat/eks-production-karpenter-migration` worktree が origin/main の squash merge 後と同期されているか確認:

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-migration
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: PR 1 の commits は origin/main に squash merge 済なので空 (or spec / plan commits のみ)。

If 空でない → reset:

```bash
git reset --hard origin/main
git log --oneline origin/main..HEAD  # 空であることを確認
```

> ⚠️ **Plan 1c-β L5 lessons learned 参照**: PR 1 squash merge 後に local branch reset が subagent dispatch 中に巻き戻る現象がある。Task 6 の冒頭で明示的に reset し、`git log --oneline origin/main..HEAD` が空であることを確認してから次の subagent ディスパッチに進むこと。

- [ ] **Step 2: terragrunt outputs 取得 (aws/karpenter/ stack から)**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
cd aws/karpenter/envs/production
TG_TF_PATH=tofu terragrunt output -json > /tmp/karpenter-outputs.json
cd ../../../..
jq -r '.node_role_name.value' /tmp/karpenter-outputs.json
jq -r '.interruption_queue_name.value' /tmp/karpenter-outputs.json
```

Expected: 2 values が取得できる:
- `node_role_name`: `KarpenterNode-eks-production-XXXXXXXXXXXXXXXXXXXX`
- `interruption_queue_name`: `eks-production` (or similar)

これら 2 値を **後の Task 9 で kubernetes/helmfile.yaml.gotmpl に転記**する。

---

## Task 7: kubernetes/components/karpenter/production component を作成

**Files:**
- Create: `kubernetes/components/karpenter/production/namespace.yaml`
- Create: `kubernetes/components/karpenter/production/helmfile.yaml`
- Create: `kubernetes/components/karpenter/production/values.yaml.gotmpl`

Karpenter Helm release を component として定義。bootstrap MNG への nodeSelector + toleration を values で設定。

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p kubernetes/components/karpenter/production
```

- [ ] **Step 2: namespace.yaml 作成**

`kubernetes/components/karpenter/production/namespace.yaml`:

```yaml
# =============================================================================
# Karpenter Namespace
# =============================================================================
# This namespace contains the Karpenter controller. Chart default name is
# also `karpenter`; we follow that convention.
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: karpenter
  labels:
    app.kubernetes.io/name: karpenter
```

- [ ] **Step 3: helmfile.yaml 作成 (Task 6 で取得した実値を直接使用)**

Task 6 の `/tmp/karpenter-outputs.json` から実値を確認:

```bash
KARPENTER_INTERRUPTION_QUEUE_NAME=$(jq -r '.interruption_queue_name.value' /tmp/karpenter-outputs.json)
echo "interruptionQueueName: $KARPENTER_INTERRUPTION_QUEUE_NAME"
```

`kubernetes/components/karpenter/production/helmfile.yaml` (上記 echo の値を `${KARPENTER_INTERRUPTION_QUEUE_NAME}` の箇所に **そのまま埋め込む**。Plan 1c-β L4 lesson 反映で placeholder + 後置換パターンは使わない):

```yaml
# =============================================================================
# Karpenter Helmfile for production
# =============================================================================
# Provisions EC2 nodes for cluster workloads. Controller pod is pinned to
# karpenter-bootstrap MNG via nodeSelector + toleration. Workload nodes are
# launched into Karpenter NodePool `system-components`.
#
# Authentication: Pod Identity (provisioned by aws/karpenter/ stack の
# Pod Identity Association)。Helm chart の serviceAccount.annotations は
# 不要 (Pod Identity Association が SA-to-role mapping を直接管理)。
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と
    # 同期すること（karpenter.interruptionQueueName + cluster.name）。
    values:
      - cluster:
          name: eks-production
        karpenter:
          interruptionQueueName: ${KARPENTER_INTERRUPTION_QUEUE_NAME}  # Step 3 の echo 値で置換
---
repositories:
  # Karpenter chart は OCI registry で配布されるため repositories block 不要
  # (helmfile は chart: oci://... を直接 解決する)

releases:
  - name: karpenter
    namespace: karpenter
    chart: oci://public.ecr.aws/karpenter/karpenter
    version: "1.6.5"
    values:
      - values.yaml.gotmpl
```

実 file content の例 (Step 3 の echo で実値を確認した上で):

```yaml
    values:
      - cluster:
          name: eks-production
        karpenter:
          interruptionQueueName: eks-production
```

- [ ] **Step 4: values.yaml.gotmpl 作成**

`kubernetes/components/karpenter/production/values.yaml.gotmpl`:

```yaml
# Karpenter values for production
# Reference: docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md

# =============================================================================
# ServiceAccount (Pod Identity, no IRSA annotation needed)
# =============================================================================
# Pod Identity Association (aws/karpenter/ stack で provision 済) が
# karpenter:karpenter ServiceAccount を controller IAM role に紐付けるため、
# Helm chart 側で eks.amazonaws.com/role-arn annotation を入れる必要なし。
# ServiceAccount は chart デフォルト (create: true、name: karpenter) で OK。
# 以下を明示的に設定する必要はない (chart デフォルトで等価)。

# =============================================================================
# Replicas / Pod placement (bootstrap MNG への pin)
# =============================================================================
# replicas: 2 (chart デフォルト) を採用。HA 化済み。
replicas: 2

# Karpenter pod を karpenter-bootstrap MNG 上のみに schedule する。
# Bootstrap MNG の taint `karpenter.sh/controller=true:NoSchedule` を
# tolerate しつつ、label `node-role/karpenter-bootstrap=true` で 配置先を絞る。
nodeSelector:
  node-role/karpenter-bootstrap: "true"

tolerations:
  - key: karpenter.sh/controller
    operator: Exists
    effect: NoSchedule

# =============================================================================
# Karpenter settings
# =============================================================================
settings:
  clusterName: {{ .Values.cluster.name }}
  # SQS interruption queue 名 (Plan 2 PR 1 で aws/karpenter/ stack が provision)
  interruptionQueue: {{ .Values.karpenter.interruptionQueueName }}

# =============================================================================
# Controller resources
# =============================================================================
# chart デフォルト (1 cpu / 1Gi memory) を採用。bootstrap MNG t4g.small は
# 2 vCPU / 2 GiB なので replicas=2 で 2 cpu / 2 Gi 要求 → 余裕で fit。
```

- [ ] **Step 5: helmfile が production env を認識すること + values 解決を確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -10
cd ..
```

Expected: 6 release が listed (cilium / metrics-server / keda / aws-load-balancer-controller / external-dns / **karpenter**)、`Error` が出ないこと。

```bash
cd kubernetes
helmfile -e production --selector name=karpenter template --skip-tests 2>&1 | grep -E "(clusterName|interruptionQueue|nodeSelector|karpenter-bootstrap|--cluster-name)" | head -20
cd ..
```

Expected:
- ServiceAccount **annotation 無し** (Pod Identity Association が direct mapping、IRSA annotation 不要)
- clusterName / `--cluster-name=eks-production` (chart args)
- interruptionQueue: `eks-production`
- nodeSelector: `node-role/karpenter-bootstrap: "true"`

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/karpenter/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/karpenter): add production component (Pod Identity)

Karpenter chart 1.6.5 (oci://public.ecr.aws/karpenter/karpenter) を
pin して production 用 helmfile / values / namespace を追加する。
- serviceAccount: chart default (create: true, name: karpenter)、
  IRSA annotation なし (Pod Identity Association が SA-to-role を
  直接管理するため)
- replicas: 2 (chart デフォルト)
- nodeSelector: node-role/karpenter-bootstrap=true (bootstrap MNG 専用)
- tolerations: karpenter.sh/controller=true:NoSchedule (bootstrap MNG
  taint を tolerate)
- settings.clusterName / settings.interruptionQueue を gotmpl で差し込み

helmfile v1.4 の parent → child env values 非継承への対応は cilium
component と同パターン (child helmfile.yaml に Task 6 で aws/karpenter/
から取得した interruption_queue_name 実値を直接記述)。Plan 1c-β L4
lessons learned 反映で placeholder + 後置換パターンは使用せず、
最初から実値で記述する形にした。
EOF
)"
```

---

## Task 8: kubernetes/components/karpenter/production/kustomization/ で EC2NodeClass + NodePool を定義

**Files:**
- Create: `kubernetes/components/karpenter/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml`
- Create: `kubernetes/components/karpenter/production/kustomization/nodepool.yaml`

Karpenter Helm release が deploy された後に必要な CRD instance (EC2NodeClass / NodePool) を kustomize で定義する (Plan 1b の cilium GatewayClass overlay と同じパターン)。

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p kubernetes/components/karpenter/production/kustomization
```

- [ ] **Step 2: kustomization.yaml 作成**

`kubernetes/components/karpenter/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# Karpenter NodePool / EC2NodeClass overlay for production
# =============================================================================
# Karpenter chart 自身は CRD 定義のみ install し、NodePool / EC2NodeClass の
# instance は提供しない。本 overlay で system-components NodePool +
# EC2NodeClass を 1 セット定義する。
# Plan 1b cilium の GatewayClass overlay と同じパターン (helmfile-builder の
# components/<svc>/<env>/kustomization/ がこの目的に使われる)。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ec2nodeclass.yaml
  - nodepool.yaml
```

- [ ] **Step 3: ec2nodeclass.yaml 作成 (Node IAM role の name を Task 6 で取得した実値で記述)**

実値を確認:

```bash
jq -r '.node_role_name.value' /tmp/karpenter-outputs.json
```

実値例: `KarpenterNode-eks-production-20260504XXXXXXXXXX`

`kubernetes/components/karpenter/production/kustomization/ec2nodeclass.yaml`:

```yaml
# =============================================================================
# EC2NodeClass: system-components
# =============================================================================
# Karpenter が node を起動する際の AWS-side configuration:
# - AMI: AL2023 ARM64 (latest)
# - Subnet: VPC private subnets (Tier=private tag で discover)
# - SecurityGroup: cluster SG + node SG (両方 Tier 経由で discover)
# - Role: Plan 2 PR 1 で aws/karpenter/ stack が provision した Node IAM role
#   (実 name は aws/karpenter/envs/production の terragrunt output
#   `node_role_name` の値)
# - EBS: gp3 30 GiB (Karpenter-managed node 用 sizing、spec L2 / Plan 1c-β
#   学び参照)
# - Metadata: IMDSv2 token required (security best practice)
# =============================================================================
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: system-components
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        Tier: private
  securityGroupSelectorTerms:
    - tags:
        "aws:eks:cluster-name": eks-production
  role: KarpenterNode-eks-production-20260504XXXXXXXXXX  # 実値は Task 6 で aws/karpenter/ から取得
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 30Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
```

> ⚠️ Step 3 の `role:` 値は Task 6 で取得した実値に書き換えること。サンプルの `KarpenterNode-eks-production-20260504XXXXXXXXXX` は placeholder。

- [ ] **Step 4: nodepool.yaml 作成**

> ⚠️ **Lessons Learned L4 参照**: 下記 YAML 内の `consolidationPolicy: WhenUnderutilized` は Karpenter v0.x の値で、v1+ では無効。実装時は `WhenEmptyOrUnderutilized` を使う (merge 後の hotfix #274 で修正済)。

`kubernetes/components/karpenter/production/kustomization/nodepool.yaml`:

```yaml
# =============================================================================
# NodePool: system-components
# =============================================================================
# Karpenter が起動する EC2 instance の選定 + lifecycle policy:
# - architecture: arm64 only (cluster と一致)
# - capacity-type: on-demand only (system-class workload なので spot 不可)
# - instance-generation: Gt 7 (Graviton 4 = m8g/c8g/r8g、最新世代のみ)
# - instance-category: m, c, r (general / compute-optimized / memory-optimized)
# - instance-size: medium..4xlarge (medium 未満は burst、8xlarge+ は bin-packing 悪化)
# - disruption: WhenUnderutilized + 30 日 expireAfter (OS patching 用 forced cycle)
# - limits.cpu: 200 (cluster 暴走時の上限、Phase 5 nginx + monorepo 想定)
# =============================================================================
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: system-components
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: system-components
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["7"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large", "xlarge", "2xlarge", "4xlarge"]
      expireAfter: 720h  # 30 days
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "200"
```

- [ ] **Step 5: kustomize build で valid 確認**

```bash
kustomize build kubernetes/components/karpenter/production/kustomization 2>&1 | head -50
```

Expected: EC2NodeClass + NodePool の 2 リソースが render される。エラーなし。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/karpenter/production/kustomization/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/karpenter): add EC2NodeClass + NodePool overlay

Plan 2 spec の Decision 3 通り、system-components NodePool +
EC2NodeClass を kustomize overlay で定義する:

- EC2NodeClass system-components:
  - amiFamily: AL2023 / amiSelectorTerms: alias=al2023@latest
  - subnetSelectorTerms: Tier=private
  - securityGroupSelectorTerms: aws:eks:cluster-name=eks-production
  - role: aws/karpenter/envs/production terragrunt output `node_role_name` の実値
  - blockDeviceMappings: gp3 30 GiB encrypted
  - metadataOptions: IMDSv2 token required

- NodePool system-components:
  - requirements: arm64 / linux / on-demand / category m,c,r /
    generation Gt 7 (Graviton 4 m8g/c8g/r8g) / size medium-4xlarge
  - disruption: WhenUnderutilized + consolidateAfter 30s + 720h expireAfter
  - limits.cpu: 200

Plan 1b cilium GatewayClass overlay と同じパターン
(helmfile-builder の components/<svc>/<env>/kustomization/ で
chart 外の CRD を定義する)。
EOF
)"
```

---

## Task 9: kubernetes/helmfile.yaml.gotmpl の production env values 更新

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`

Task 6 で取得した terragrunt outputs を `kubernetes/helmfile.yaml.gotmpl` の production env block に転記する。

- [ ] **Step 1: 現状の helmfile.yaml.gotmpl 確認**

```bash
grep -A 20 "^  production:" kubernetes/helmfile.yaml.gotmpl
```

Expected: 既存の production env block (Plan 1b で `cluster.eksApiEndpoint`、Plan 1c-β で `cluster.vpcId` / `cluster.albControllerRoleArn` / `cluster.externalDnsRoleArn` 追加済) が表示。

- [ ] **Step 2: 既存 production env block の `values:` 内に `karpenter:` map を追加**

`kubernetes/helmfile.yaml.gotmpl` の `production:` block の `cluster:` map の **直後** (同じ `values:` の中、`cluster:` map と並列に) に以下を追加:

```yaml
        karpenter:
          # Source: aws/karpenter/envs/production terragrunt output
          # Pod Identity 採用のため controllerRoleArn は不要 (Pod Identity
          # Association が SA-to-role mapping を直接管理)
          nodeRoleName: KarpenterNode-eks-production-20260504XXXXXXXXXX
          interruptionQueueName: eks-production
```

> 実値は Task 6 で `aws/karpenter/envs/production` から取得したものを使用すること。`KarpenterNode-...` の suffix は random hash なので毎回異なる。

完成後の production block 例:

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
          eksApiEndpoint: BD10E7689A05E46191305DDC7BE6CA67.gr7.ap-northeast-1.eks.amazonaws.com
          vpcId: vpc-02ea5d0ed3b7a3266
          albControllerRoleArn: arn:aws:iam::559744160976:role/eks-production-alb-controller-20260503163503969700000004
          externalDnsRoleArn: arn:aws:iam::559744160976:role/eks-production-external-dns-20260503163503968100000002
        karpenter:
          # Source: aws/karpenter/envs/production terragrunt output
          # Pod Identity 採用のため controllerRoleArn は不要
          nodeRoleName: KarpenterNode-eks-production-20260504XXXXXXXXXX
          interruptionQueueName: eks-production
```

- [ ] **Step 3: helmfile が production env を認識すること + values 解決を確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -10
cd ..
```

Expected: 6 release が listed (cilium / metrics-server / keda / aws-load-balancer-controller / external-dns / karpenter)、エラーなし。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): wire Karpenter terragrunt outputs to helmfile values

PR 1 (#XXX) で aws/karpenter/ stack apply により作成された Karpenter
関連 Node IAM / SQS の output 値を kubernetes/helmfile.yaml.gotmpl の
production env values に転記する:
- karpenter.nodeRoleName (EC2NodeClass.spec.role 用、Task 8 で kustomize
  resource 内に既に記述済だが parent helmfile にも対称的に配置)
- karpenter.interruptionQueueName (Helm chart settings.interruptionQueue 用)

Pod Identity 採用のため controllerRoleArn は kubernetes 側で不要。

Karpenter component の child helmfile (kubernetes/components/karpenter/
production/helmfile.yaml) には Task 7 で既に実値を埋めてある (helmfile
v1.4 の parent → child auto-inherit 非対応への対処、cilium と同パターン)。
EOF
)"
```

---

## Task 10: `make hydrate ENV=production` 実行 + commit

**Files (auto-generated by hydrate):**
- Create: `kubernetes/manifests/production/karpenter/manifest.yaml`
- Create: `kubernetes/manifests/production/karpenter/kustomization.yaml`
- Modify: `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (karpenter namespace 追加)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (8 component 参照に拡張)

- [ ] **Step 1: hydrate 実行**

```bash
cd kubernetes
make hydrate ENV=production
cd ..
```

Expected: `Hydrating karpenter...` 等が標準出力に表示、`✅ Manifests hydrated`。

- [ ] **Step 2: 生成された structure 確認**

```bash
find kubernetes/manifests/production -maxdepth 2 -type d | sort
```

Expected: cilium / gateway-api / keda / metrics-server / aws-load-balancer-controller / external-dns / **karpenter** / 00-namespaces の 8 つ。

- [ ] **Step 3: karpenter namespace が namespaces.yaml に追加されたこと確認**

```bash
grep -B 1 -A 5 "name: karpenter" kubernetes/manifests/production/00-namespaces/namespaces.yaml
```

Expected: `karpenter` namespace の YAML block が含まれる。

- [ ] **Step 4: top-level kustomization.yaml が 8 component を参照すること確認**

```bash
cat kubernetes/manifests/production/kustomization.yaml
```

Expected:
```yaml
resources:
  - ./00-namespaces
  - ./aws-load-balancer-controller
  - ./cilium
  - ./external-dns
  - ./gateway-api
  - ./karpenter
  - ./keda
  - ./metrics-server
```

- [ ] **Step 5: Karpenter の主要設定を sanity check**

```bash
echo "=== Karpenter ServiceAccount IRSA annotation ==="
grep -B 1 -A 3 "eks.amazonaws.com/role-arn" kubernetes/manifests/production/karpenter/manifest.yaml | head -10

echo ""
echo "=== Karpenter clusterName / interruptionQueue env ==="
grep -E "CLUSTER_NAME|INTERRUPTION_QUEUE" kubernetes/manifests/production/karpenter/manifest.yaml | head -10

echo ""
echo "=== Karpenter nodeSelector / tolerations ==="
grep -B 1 -A 3 "node-role/karpenter-bootstrap" kubernetes/manifests/production/karpenter/manifest.yaml | head -10

echo ""
echo "=== EC2NodeClass system-components ==="
grep -B 1 -A 5 "kind: EC2NodeClass" kubernetes/manifests/production/karpenter/manifest.yaml | head -10

echo ""
echo "=== NodePool system-components ==="
grep -B 1 -A 5 "kind: NodePool" kubernetes/manifests/production/karpenter/manifest.yaml | head -10
```

Expected:
- Karpenter SA に IRSA role ARN annotation
- Controller pod env に CLUSTER_NAME=eks-production / INTERRUPTION_QUEUE=eks-production
- Controller pod に nodeSelector node-role/karpenter-bootstrap=true + tolerations
- EC2NodeClass + NodePool 両方 `system-components` 命名

- [ ] **Step 6: kustomize build で全体 valid 確認**

```bash
kustomize build kubernetes/manifests/production 2>&1 | grep -c "^kind:"
```

Expected: 130+ resources（既存 112 + Karpenter chart 約 15 + EC2NodeClass + NodePool）。エラーなし。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/manifests/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/manifests/production): hydrate karpenter

make hydrate ENV=production の output を commit する。
- karpenter/manifest.yaml: chart 1.6.5 の rendered output、IRSA
  annotation + cluster name + interruption queue + nodeSelector +
  tolerations + EC2NodeClass system-components + NodePool
  system-components を含む
- 00-namespaces/namespaces.yaml: karpenter namespace 追加
- kustomization.yaml: 8 component (cilium / gateway-api / keda /
  metrics-server / aws-load-balancer-controller / external-dns /
  karpenter / 00-namespaces) を resources として参照
EOF
)"
```

---

## Task 11: kubernetes/README.md 更新

**Files:**
- Modify: `kubernetes/README.md`

Plan 2 の Karpenter component を Production Operations セクションに反映。

- [ ] **Step 1: 現状の README 構成確認**

```bash
grep -n "^### " kubernetes/README.md | head -25
```

Expected: Production Operations 配下に Cluster overview (post Plan 1c-β) / Initial Bootstrap / Daily Operations / Cilium-specific operations / Foundation addon operations / Troubleshooting / GitOps 原則 が見える (Plan 1c-β までで揃っている)。

- [ ] **Step 2: Cluster overview セクション更新**

`### Cluster overview (post Plan 1c-β)` を `### Cluster overview (post Plan 2)` に変更。Plan 1c-β で追加した foundation addons 表の直後 (次の `### Initial Bootstrap` の前) に以下を append (先頭に空行を挟んで):

````markdown
さらに Plan 2 で以下を導入：

| Addon / Resource | 配置 | 役割 |
|---|---|---|
| Karpenter controller | `karpenter` | Pod 需要に応じて EC2 instance を動的 provision (system-components NodePool 起動の m8g/c8g/r8g 系 Graviton 4 instance) |
| `karpenter-bootstrap` MNG | (`t4g.small × 2`) | Karpenter controller pod 専用の最小構成 EKS managed nodegroup。taint で他 pod を排除 |
| EC2NodeClass `system-components` | (cluster-scoped) | AMI / subnet / SG / Node IAM / EBS / IMDSv2 の AWS-side configuration |
| NodePool `system-components` | (cluster-scoped) | arm64 + on-demand + Graviton 4 + size medium-4xlarge の selection。WhenUnderutilized consolidation で cost 最適化 |
| `system` MNG | (撤去済) | Plan 2 PR 3 で削除。CoreDNS / Cilium operator / Flux / addons は全部 Karpenter NodePool に移行 |
````

- [ ] **Step 3: Foundation addon operations セクションを更新**

`### Foundation addon operations` の bash code block の末尾に append (既存の Gateway API / Metrics Server / KEDA / ALB Controller / ExternalDNS の下に):

````markdown

```bash
# Karpenter
kubectl get deployment -n karpenter karpenter             # READY 2/2、bootstrap MNG 上で稼働
kubectl logs -n karpenter deploy/karpenter --tail=20
kubectl get nodepool system-components                    # Ready=True
kubectl get ec2nodeclass system-components                # Ready=True
kubectl get nodeclaim                                     # 現在 Karpenter が起動した NodeClaim 一覧
kubectl get nodes -L karpenter.sh/nodepool                # nodepool 別の node 一覧
```
````

> 既存の bash code block の閉じ ``` の直前に上記内容を挿入する形 (同一 code block 内に append)。

- [ ] **Step 4: Troubleshooting テーブルに行追加**

`### Troubleshooting` テーブルの末尾 (既存の Plan 1c-β 学び 3 行の後) に以下の行を追加:

````markdown
| Karpenter pod が `karpenter-bootstrap` MNG 以外の node に schedule される | values.yaml.gotmpl の nodeSelector / tolerations が rendered manifest に反映されていない or bootstrap MNG の label / taint が誤り。`kubectl get pod -n karpenter -o wide` で 配置 node を確認、`kubectl get node -L node-role/karpenter-bootstrap` で label 確認 |
| `kubectl get nodepool system-components` が `Ready=False` | EC2NodeClass の参照先 (Node IAM role) や subnet selector が誤り。`kubectl describe nodepool system-components` で詳細を確認、`aws iam get-role --role-name <ec2nodeclass.spec.role>` で role 存在確認 |
| Pending pod があるのに Karpenter が node を起動しない | NodePool の requirements にマッチする instance type が region で出ない (Graviton 4 capacity 不足等) or limits.cpu に達している。`kubectl describe pod <pending-pod>` の events で Karpenter の判断ログを確認、必要なら一時的に `instance-generation: Gt 5` で gen 6/7 も許可 |
````

- [ ] **Step 5: README の整合性確認**

```bash
grep -c "^### " kubernetes/README.md
```

Expected: subsection count が Plan 1c-β 時点（23）から変わらず（既存セクションの内容追記のみで新規 subsection 追加なし）。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "$(cat <<'EOF'
docs(kubernetes): reflect Plan 2 Karpenter migration in README

Production Operations セクションに Plan 2 で導入する Karpenter と
karpenter-bootstrap MNG / EC2NodeClass / NodePool を反映する。
- Cluster overview を Plan 2 完了後の構成に更新
  (system MNG 撤去 + bootstrap MNG + Karpenter NodePool 表)
- Foundation addon operations に Karpenter / NodePool / NodeClaim の
  運用コマンド追加
- Troubleshooting に Karpenter pod 配置 / NodePool Ready=False /
  Pending pod with no provisioning の 3 件追加
EOF
)"
```

---

## Task 12: PR 2 push + Draft PR 作成

**Files:** （git 操作のみ）

- [ ] **Step 1: 全 commit 確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: Task 7-11 の 5 commit (component (helmfile + values + namespace) + kustomization (EC2NodeClass + NodePool) + helmfile.yaml.gotmpl + hydrate + README):

```
<sha> docs(kubernetes): reflect Plan 2 Karpenter migration in README
<sha> feat(kubernetes/manifests/production): hydrate karpenter
<sha> feat(kubernetes): wire Karpenter terragrunt outputs to helmfile values
<sha> feat(kubernetes/components/karpenter): add EC2NodeClass + NodePool overlay
<sha> feat(kubernetes/components/karpenter): add production component
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-karpenter-migration
```

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --base main \
  --title "feat(kubernetes): Plan 2 PR 2 — install Karpenter + system-components NodePool" \
  --body "$(cat <<'EOF'
## Summary

Plan 2 (Karpenter migration) の **PR 2** （Kubernetes layer）。PR 1 (#XXX merged) で作成された Karpenter IRSA / Node IAM / SQS / EventBridge / `karpenter-bootstrap` MNG を前提に、Karpenter Helm release (chart 1.6.5) + EC2NodeClass + NodePool (`system-components` 命名) を Flux GitOps 経由で install する。

### Code 変更（本 PR）

- `kubernetes/components/karpenter/production/`: helmfile + values + namespace。Karpenter pod を `karpenter-bootstrap` MNG に nodeSelector + toleration で pin
- `kubernetes/components/karpenter/production/kustomization/`: EC2NodeClass + NodePool (両方 `system-components`)
- `kubernetes/helmfile.yaml.gotmpl`: production env values に `karpenter.{nodeRoleName,interruptionQueueName}` 追加 (PR 1 の `aws/karpenter/` terragrunt output から実値)。Pod Identity 採用のため controllerRoleArn は不要
- `kubernetes/manifests/production/`: hydrate output (8 component 構成、karpenter 追加)
- `kubernetes/README.md`: Production Operations 更新（Cluster overview / Foundation addon operations / Troubleshooting）

### Documents

- Plan: `docs/superpowers/plans/2026-05-04-eks-production-karpenter-migration.md`
- Spec: `docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md`
- 前段 PR (AWS infra): #XXX (PR 1)

## Migration sequence

PR 2 merge 後の手順:

1. PR 2 を main へ merge
2. CI: `Hydrate Kubernetes (production)` workflow auto-run
3. Flux が main を pull → Karpenter Helm release / EC2NodeClass / NodePool / karpenter namespace を apply
4. **USER GATE 2 (cordon + drain manual migration)** を operator が実行 (Plan の `(USER) PR 2 review + merge → Migration` セクション参照)
5. PR 3 (system MNG 撤去) を作成 → merge

> ⚠️ 本 PR merge 直後の cluster は「system MNG 上に既存 pod、karpenter-bootstrap MNG 上に Karpenter controller、Karpenter NodePool 上に node 0」の状態。実際の migration は **Plan の `(USER) PR 2 review + merge → Migration` セクション** で operator が手動で cordon + drain する。

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] `helmfile -e production list` で 6 release が listed (cilium / metrics-server / keda / aws-load-balancer-controller / external-dns / karpenter)
- [x] `helmfile -e production --selector name=karpenter template` で IRSA annotation + clusterName + interruptionQueue + nodeSelector が rendered
- [x] `kustomize build kubernetes/components/karpenter/production/kustomization` で EC2NodeClass + NodePool が render される
- [x] `kustomize build kubernetes/manifests/production` が valid (130+ resources)
- [x] `kubernetes/manifests/production/00-namespaces/namespaces.yaml` に karpenter namespace 追加
- [x] `kubernetes/manifests/production/kustomization.yaml` が 8 component を参照
- [x] `kubernetes/README.md` の Production Operations が Plan 2 反映済

### Cluster-level (operator 実行、merge 後)

- [ ] `kubectl get deployment -n karpenter karpenter` で READY 2/2
- [ ] `kubectl get pod -n karpenter -o wide` で karpenter pod が **karpenter-bootstrap MNG 上に配置**
- [ ] `kubectl get nodepool system-components` で Ready=True
- [ ] `kubectl get ec2nodeclass system-components` で Ready=True
- [ ] Smoke test: `kubectl create deployment smoke-target --image=nginx:alpine` → Karpenter が m8g.medium 等を起動 → smoke pod Ready → cleanup
- [ ] system MNG cordon + drain → 全 pod が Karpenter NodePool 上に migration
EOF
)" 2>&1 | tail -3
```

Expected: PR URL が表示。

---

## (USER) PR 2 review + merge → Migration

> ⚠️ **Lessons Learned L6 参照**: 本 USER GATE は実行中に bootstrap MNG の rolling update + PR #275 (node SG hotfix) の組み合わせで Karpenter pod が CrashLoopBackOff 状態のまま PDB blocker を起こす escalation を経験した。Step 2 で Karpenter pod が 5 分以上 NotReady の場合は `kubectl delete pod karpenter-... -n karpenter --force --grace-period=0` で eviction を bypass する recovery 手順を実行する。

**Files:** （cluster 状態変更）

PR 2 を merge して Karpenter を install、その後 manual で cordon + drain による migration を実行する。

- [ ] **Step 1: PR 2 を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: `Hydrate Kubernetes (production)` workflow が success で完了。

- [ ] **Step 2: Flux reconcile + Karpenter pod 起動確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
flux get kustomizations -n flux-system flux-system
kubectl get pods -n karpenter
kubectl get pod -n karpenter -o wide
```

Expected:
- flux Kustomization が Ready=True、`Applied revision: main@<sha>`
- karpenter deployment 2/2 Ready
- karpenter pod が `karpenter-bootstrap` MNG (label `node-role/karpenter-bootstrap=true` の node) 上で Running

- [ ] **Step 3: Karpenter logs + CRD 確認**

```bash
kubectl logs -n karpenter deploy/karpenter --tail=30 | grep -iE "(error|fail|level=error)" | head -10
kubectl get nodepool system-components
kubectl get ec2nodeclass system-components
```

Expected:
- Error log なし (ASsumeRoleWithWebIdentity 系のみ初期化中に出る場合あり、最終的に成功すれば問題なし)
- NodePool / EC2NodeClass 両方 Ready=True

- [ ] **Step 4: Smoke test (Karpenter が Graviton 4 instance を auto-provision することを確認)**

```bash
kubectl create deployment smoke-target --image=nginx:alpine --replicas=1
```

Karpenter が m8g.medium 等を起動するまで待つ (通常 60-120 秒):

```bash
until kubectl get nodeclaim 2>/dev/null | grep -q "Ready"; do sleep 5; done
echo "NodeClaim Ready"
kubectl get nodeclaims
kubectl get nodes -L node.kubernetes.io/instance-type -L karpenter.sh/nodepool
kubectl get pod -l app=smoke-target -o wide
```

Expected:
- NodeClaim `system-components-XXXXX` が Ready
- 新 node が `m8g.{medium,large,...}` / `c8g.*` / `r8g.*` のいずれかで起動、`karpenter.sh/nodepool=system-components` label
- smoke-target pod が新 node 上で Running

Cleanup:

```bash
kubectl delete deployment smoke-target
# Karpenter consolidation で empty node が auto-cleanup される (TTL 30 秒)
sleep 60
kubectl get nodes -L karpenter.sh/nodepool
```

Expected: smoke 用 node が auto-delete されて 4 node に戻る (system × 2 + bootstrap × 2)。

- [ ] **Step 5: 既存 system MNG の cordon (両 node)**

```bash
for node in $(kubectl get nodes -l 'eks.amazonaws.com/nodegroup=system' -o name); do
  kubectl cordon $node
done
kubectl get nodes -L eks.amazonaws.com/nodegroup
```

Expected: system × 2 の status が `Ready,SchedulingDisabled`。

- [ ] **Step 6: Drain (1 node ずつ、PDB 尊重)**

```bash
# 1 node 目を drain
SYSTEM_NODE_1=$(kubectl get nodes -l 'eks.amazonaws.com/nodegroup=system' -o name | head -1)
echo "Draining: $SYSTEM_NODE_1"
kubectl drain $SYSTEM_NODE_1 --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

Expected: 全 pod が evict され、`drained` 完了。Karpenter が pending pod を見て m8g.medium 等を 1-2 個 provision している。

```bash
# Karpenter が起動した node を確認
kubectl get nodeclaims
kubectl get nodes -L eks.amazonaws.com/nodegroup -L karpenter.sh/nodepool
```

```bash
# 2 node 目を drain
SYSTEM_NODE_2=$(kubectl get nodes -l 'eks.amazonaws.com/nodegroup=system' -o name | head -1)
echo "Draining: $SYSTEM_NODE_2"
kubectl drain $SYSTEM_NODE_2 --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

> ⚠️ Drain で PDB が blocker になった場合 (`Cannot evict pod` エラー):
> - 該当 deployment の replicas を一時的に増やす
> - or PDB を update して `maxUnavailable` を増やす (`kubectl edit pdb <name>`)

- [ ] **Step 7: 移行完了確認**

```bash
kubectl get pods -A -o wide --field-selector=status.phase=Running | awk 'NR>1 {print $8}' | sort | uniq -c
kubectl get nodes -L eks.amazonaws.com/nodegroup -L karpenter.sh/nodepool
flux get all -A | grep -v "True" | head -5
cilium status --wait | tail -10
```

Expected:
- pod は `karpenter-bootstrap × 2` (DaemonSet 等) + `system-components × N` の Karpenter 起動 node に集約。`system × 2` には DaemonSet 以外 0 pod
- `flux get all -A | grep -v True` が空 (header のみ)
- `cilium status` が steady state (chaining mode 動作確認)

- [ ] **Step 8: Smoke Ingress test (Plan 1c-β verification と同じ、回帰確認)**

Plan 1c-β verification battery の smoke test と同じ Ingress を投入し、ALB + Route53 + HTTPS が正常動作すること確認。Karpenter NodePool 上で動く ALB Controller / ExternalDNS が PR 1 / PR 2 で破壊されていないことの最終確認。

```bash
kubectl run smoke-target --image=nginx:alpine --port=80 -n default
kubectl expose pod smoke-target --port=80 --target-port=80 -n default --name=smoke-svc
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smoke-ing
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: panicboat-platform
    external-dns.alpha.kubernetes.io/hostname: smoke.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: smoke.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: smoke-svc
                port:
                  number: 80
EOF
until [ -n "$(kubectl get ingress smoke-ing -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ]; do sleep 5; done
sleep 60  # DNS 伝搬待ち
curl -sI https://smoke.panicboat.net/ --max-time 30 | head -5
```

Expected: `HTTP/2 200`、Plan 1c-β と同じ動作。

Cleanup:

```bash
kubectl delete ingress smoke-ing -n default
kubectl delete svc smoke-svc -n default
kubectl delete pod smoke-target -n default
```

Migration 完了。次に PR 3 (system MNG 撤去) の実装へ進む。

---

# PR 3 implementation: AWS cleanup

## Task 13: aws/eks/modules/node_groups.tf から system block を削除

> ⚠️ **Lessons Learned L7 参照**: course correction v2 で karpenter-bootstrap MNG が `aws/karpenter/` に移動した結果、`aws/eks/modules/node_groups.tf` には `system` block しか残らず、本 task の実装は同ファイル全体の削除 + `main.tf` の `eks_managed_node_groups` argument 削除 + `variables.tf` の `node_*` var 削除になった (PR 3 #276)。

**Files:**
- Modify: `aws/eks/modules/node_groups.tf`

USER GATE 2 で system MNG node が cordon + drain 済 (pod 数 0、DaemonSet のみ) なので、安全に terraform-side から block 削除可能。

- [ ] **Step 1: PR 3 用に branch を sync**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-karpenter-migration
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: 空 (PR 2 squash merge 後)。

If 空でない:

```bash
git reset --hard origin/main
git log --oneline origin/main..HEAD  # 空であることを確認
```

> ⚠️ Plan 1c-β L5 lessons learned 参照: PR squash merge 後の reset を明示。

- [ ] **Step 2: 現状の node_groups.tf 確認**

```bash
grep -n "^locals\|    system\|    karpenter-bootstrap" aws/eks/modules/node_groups.tf
```

Expected: `system` block + `karpenter-bootstrap` block 両方存在。

- [ ] **Step 3: `system` block を削除**

`aws/eks/modules/node_groups.tf` から `system = { ... }` block 全体を削除する (block の `system = {` から閉じ `}` まで、約 50 行)。`karpenter-bootstrap` block と `locals { ... }` の閉じ括弧は残す。

完成後の構造:

```hcl
# node_groups.tf - EKS managed node group definitions.
#
# Single "karpenter-bootstrap" group on Graviton (ARM64) sized to host the
# Karpenter controller pod only. All other workloads (system pods + future
# applications) run on Karpenter NodePool-managed nodes.
#
# See docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md
# for the rationale.

locals {
  eks_managed_node_groups = {
    karpenter-bootstrap = {
      # ... (Task 2 で追加した内容そのまま)
    }
  }
}
```

- [ ] **Step 4: ヘッダ comment を更新 (system MNG への言及を Karpenter ベースに書き直す)**

`aws/eks/modules/node_groups.tf` の冒頭 comment block (Plan 1a 時点で書いた `# Single "system" group ...` の段落) を以下に書き換え:

```hcl
# node_groups.tf - EKS managed node group definitions.
#
# Single "karpenter-bootstrap" group on Graviton (ARM64) hosts the
# Karpenter controller pod (replicas=2). All other workloads (CoreDNS,
# Cilium operator, Flux, Foundation addons, future applications) run on
# Karpenter NodePool-managed Graviton 4 (m8g/c8g/r8g) on-demand instances.
#
# See docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md
# for the rationale. The previous "system" managed nodegroup was removed
# in Plan 2 PR 3 after the migration.
```

- [ ] **Step 5: terraform validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: terragrunt plan で差分確認 (apply はしない)**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(will be destroyed|Plan:)" | head -10
cd ../../../..
```

Expected: `module.eks.module.eks_managed_node_group["system"].*` 関連リソースが `will be destroyed` (約 10-15 リソース)。`Plan: 0 to add, 0 to change, ~10-15 to destroy`。

If plan fails on credentials, report and proceed.

- [ ] **Step 7: Commit**

```bash
git add aws/eks/modules/node_groups.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): remove system MNG (Plan 2 migration complete)

Plan 2 PR 3 として、Karpenter migration 完了後の system managed
node group を削除する。USER GATE 2 で cordon + drain 済 (pod 数 0、
DaemonSet のみ存在せず) なので terraform destroy で安全に terminate
される。

ファイル冒頭 comment block も Karpenter ベースの構成説明に書き換え。
karpenter-bootstrap MNG が唯一の eks_managed_node_groups エントリと
なる。
EOF
)"
```

---

## Task 14: aws/eks/modules/variables.tf から不要 variables を削除

**Files:**
- Modify: `aws/eks/modules/variables.tf`

system MNG 用の `node_*` variables (5 件) は使用箇所が消えたので削除する。bootstrap 用 vars は据え置き。

- [ ] **Step 1: 削除対象を確認**

```bash
grep -n "^variable \"node_" aws/eks/modules/variables.tf
```

Expected: 5 件が表示:
```
variable "node_instance_types"
variable "node_desired_size"
variable "node_min_size"
variable "node_max_size"
variable "node_disk_size"
```

- [ ] **Step 2: variables.tf から 5 つの `node_*` variable block を削除**

`aws/eks/modules/variables.tf` から以下の 5 つの `variable "node_*"` block 全体を削除:

- `variable "node_instance_types"` block
- `variable "node_desired_size"` block
- `variable "node_min_size"` block
- `variable "node_max_size"` block
- `variable "node_disk_size"` block

`bootstrap_*` variables (Task 1 で追加) と `cluster_version` / `log_retention_days` / `environment` / `aws_region` / `common_tags` は **削除しない**。

- [ ] **Step 3: terraform validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: terragrunt.hcl の inputs に `node_*` 設定が残っていないか確認**

```bash
grep "node_" aws/eks/envs/production/terragrunt.hcl
```

Expected: 結果が空 (production terragrunt.hcl は `node_*` を override していない、defaults を使っていただけなので削除で問題なし)。

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/variables.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): cleanup unused node_* variables

Plan 2 PR 3 で system MNG 削除に伴い、system MNG 専用だった以下の
5 variables を variables.tf から削除する:
- node_instance_types
- node_desired_size
- node_min_size
- node_max_size
- node_disk_size

bootstrap_* (Plan 2 PR 1 で追加) は karpenter-bootstrap MNG 用に残す。
production terragrunt.hcl は node_* を override していなかったため
inputs 側の更新は不要。
EOF
)"
```

---

## Task 15: PR 3 push + Draft PR 作成

**Files:** （git 操作のみ）

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: Task 13 + 14 の 2 commit:

```
<sha> feat(aws/eks): cleanup unused node_* variables
<sha> feat(aws/eks): remove system MNG (Plan 2 migration complete)
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-karpenter-migration
```

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --base main \
  --title "feat(aws): Plan 2 PR 3 — remove system MNG (post-migration cleanup)" \
  --body "$(cat <<'EOF'
## Summary

Plan 2 (Karpenter migration) の **PR 3** （AWS cleanup 部分）。PR 2 (#XXX merged) + USER GATE 2 (cordon + drain) で全 pod が Karpenter NodePool 上に移行済の状態で、空になった system managed node group を terraform から撤去する。

### Code 変更（本 PR）

- `aws/eks/modules/node_groups.tf`: `system` block 削除 + ヘッダ comment 更新
- `aws/eks/modules/variables.tf`: `node_instance_types` / `node_desired_size` / `node_min_size` / `node_max_size` / `node_disk_size` の 5 vars 削除 (bootstrap_* は据え置き)

### Documents

- Plan: `docs/superpowers/plans/2026-05-04-eks-production-karpenter-migration.md`
- Spec: `docs/superpowers/specs/2026-05-04-eks-production-karpenter-migration-design.md`
- 前段 PR (Karpenter install): #XXX (PR 2)
- AWS infra parallel add: #XXX (PR 1)

## Migration sequence

PR 3 merge 直前の cluster 状態 (USER GATE 2 完了後):
- bootstrap MNG (`t4g.small × 2`): Karpenter controller pod 配置
- Karpenter NodePool managed nodes (`m8g/c8g/r8g.*` × N): 全 system pod 配置
- system MNG (`m6g.large × 2`): DaemonSet 以外 pod 数 = 0、cordoned

PR 3 merge 後の手順:
1. PR 3 を main へ merge
2. CI: `Deploy Terragrunt (eks:production)` workflow auto-run
3. terragrunt apply で system MNG 削除 → AWS が EC2 instance 2 台を terminate
4. Plan 2 完了

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] `aws/eks/envs/production` で `terragrunt validate` 成功
- [x] `aws/eks/envs/production` で `terragrunt plan` が `module.eks.module.eks_managed_node_group["system"].*` 関連リソース (約 10-15 件) を `will be destroyed` で表示。`Plan: 0 to add, 0 to change, ~10-15 to destroy`
- [x] `aws/eks/envs/production/terragrunt.hcl` の inputs に `node_*` 設定が残っていない

### Cluster-level (CI / operator 実行、merge 後)

- [ ] CI が `Deploy Terragrunt (eks:production)` apply 完了
- [ ] `kubectl get nodes -L eks.amazonaws.com/nodegroup` で `system` group node が存在しない
- [ ] `aws eks list-nodegroups --cluster-name eks-production` で `system` が無い (`karpenter-bootstrap` のみ)
- [ ] cluster 状態が steady (全 pod Ready, Karpenter NodePool 上で安定稼働)
- [ ] AWS billing console で日次 EC2 cost が `m6g.large × 2` 分減少していることを翌日確認
EOF
)" 2>&1 | tail -3
```

Expected: PR URL が表示。

---

## (USER) PR 3 review + merge → Verification

**Files:** （cluster 状態変更）

PR 3 を merge して system MNG を撤去、最終 verification を実行する。

- [ ] **Step 1: PR 3 を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: `Deploy Terragrunt (eks:production)` workflow が success で完了。`module.eks.module.eks_managed_node_group["system"].*` の destroy が完了。

- [ ] **Step 2: Cluster 状態確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get nodes -L eks.amazonaws.com/nodegroup -L karpenter.sh/nodepool
```

Expected: `system` group node が存在しない。`karpenter-bootstrap × 2` + Karpenter NodePool 起動の `system-components` group nodes のみ。

- [ ] **Step 3: AWS 側 nodegroup 確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
aws eks list-nodegroups --cluster-name eks-production --region ap-northeast-1 --output table
```

Expected: `karpenter-bootstrap` のみ。`system` は無い。

- [ ] **Step 4: Pod 配置確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get pods -A -o wide --field-selector=status.phase=Running | awk 'NR>1 {print $8}' | sort | uniq -c
flux get all -A | grep -v "True" | head -5
```

Expected:
- 全 pod が `karpenter-bootstrap × 2` + Karpenter NodePool 起動の node (`system-components-XXXXX`) に分散
- Flux Reconciliation 全部 Ready

- [ ] **Step 5: Karpenter consolidation 動作確認 (idle 時の node 数最小化)**

```bash
# 5-10 分 idle 後に node 数を確認
kubectl get nodes -L karpenter.sh/nodepool
kubectl get nodeclaim
```

Expected: Karpenter consolidation で workload に応じた最小 node 数に収束 (typical: bootstrap × 2 + system-components × 1-3)。

- [ ] **Step 6: 翌日 cost 確認 (async)**

24 時間後に AWS Billing console で日次 EC2 cost を確認。

Expected: `m6g.large × 2` 分 (~$1.6/日 = ~$50/月相当) の減少を確認。Karpenter NodePool 起動 instance の cost (consolidation 効いた状態) も計上。Total cost: 移行前比で大幅減 (idle 時想定: bootstrap × 2 + small Karpenter instance × 1-2 で ~$30-60/月)。

すべて pass したら **Plan 2 完了**。Phase 1 + Phase 2 完了、次は Phase 3 (Observability stack) または Phase 5 nginx 投入 + 関連 spot NodePool 追加 spec へ。

---

## Self-review checklist

> Plan 完成後の self-review。Implementer が任意 task を実行する前に、Plan 自体の整合性を確認する。

### Spec coverage

Spec の各セクションが Plan 内のどの task で実装されているか:

- [x] **Goals G1 (Karpenter on-demand 集約)** → Tasks 2, 3, 6-10 (bootstrap MNG + Karpenter sub-module + Helm + EC2NodeClass + NodePool + helmfile parent + hydrate)
- [x] **Goals G2 (operational simplicity)** → Task 7 で nodeSelector + toleration、Task 8 で NodePool 単一 (`system-components`)
- [x] **Goals G3 (cost reduction)** → Task 1 で bootstrap_disk_size=20、Task 2 で t4g.small × 2、Task 13 で system MNG 削除
- [x] **Architecture decision 1 (Roadmap Decision 5 上書き)** → Plan 全体 (3-PR で system MNG → Karpenter NodePool 移行)
- [x] **Architecture decision 2 (on-demand only)** → Task 8 nodepool.yaml の `karpenter.sh/capacity-type=on-demand`
- [x] **Architecture decision 3 (ARM64 + Graviton 4 + medium-4xlarge)** → Task 8 nodepool.yaml requirements
- [x] **Architecture decision 4 (3-PR split)** → PR 1 (Tasks 1-5) / USER GATE 1 / PR 2 (Tasks 6-12) / USER GATE 2 / PR 3 (Tasks 13-15) / USER GATE 3
- [x] **Architecture decision 5 (terraform-aws-modules karpenter sub-module)** → Task 3
- [x] **Components matrix AWS layer** → Tasks 1-4
- [x] **Components matrix Kubernetes layer** → Tasks 7, 8, 9, 10, 11
- [x] **Cross-stack value flow** → Task 6 (terragrunt outputs 取得) → Task 9 (helmfile.yaml.gotmpl 転記)
- [x] **Migration sequence の cordon + drain step** → USER GATE 2 (Step 5-7)
- [x] **Verification checklist (PR 1 後 / PR 2 後 / USER GATE 2 後 / PR 3 後)** → 各 PR / USER GATE 内に統合
- [x] **エラーシナリオ (PDB blocker / capacity 不足 / Karpenter pod 落ち)** → USER GATE 2 Step 6 内で言及 + Task 11 README troubleshooting に追加

### Placeholder scan

- [x] **`${KARPENTER_*}` shell 変数 placeholder** は Task 6 で取得した `/tmp/karpenter-outputs.json` から実値を埋め込む明示的指示あり (Task 7 Step 3、Task 8 Step 3 (EC2NodeClass.spec.role)、Task 9 Step 2 (helmfile.yaml.gotmpl)。L4 lesson 反映で REPLACE_FROM_TERRAGRUNT_OUTPUT placeholder pattern は使わず、最初から実値を直接記述する形)
- [x] **`<sha>` / `<XXX>` / `<num>`** は commit hash / PR number の placeholder で実装時に確定
- [x] **node IP placeholder (`ip-10-0-XX-XX`)** は USER GATE 2 で `kubectl get nodes` から取得して使う想定 (Step 6 で `SYSTEM_NODE_1=$(... | head -1)` で動的取得)
- [x] **TBD / implement later / fill in details** 等の禁止文言なし

### Type / signature consistency

- [x] **terragrunt output 名** (`aws/karpenter/modules/outputs.tf` の `node_role_name` / `interruption_queue_name`) は Task 4 (定義) と Task 6 (取得) と Task 7 / 8 / 9 (参照) で一致
- [x] **helmfile values key** (`cluster.name` / `karpenter.nodeRoleName` / `karpenter.interruptionQueueName`) は Task 7 (child) と Task 9 (parent) で一致 (Pod Identity 採用で `controllerRoleArn` は kubernetes 側に存在しない)
- [x] **Karpenter ServiceAccount 名** (`karpenter`) は Task 3 (`irsa_namespace_service_accounts = ["karpenter:karpenter"]`) と Task 7 (`serviceAccount.name: karpenter`) で一致
- [x] **bootstrap MNG taint key** (`karpenter.sh/controller`) は Task 2 (taints.karpenter-controller.key) と Task 7 (tolerations.key) で一致
- [x] **bootstrap MNG label** (`node-role/karpenter-bootstrap=true`) は Task 2 (labels) と Task 7 (nodeSelector) で一致
- [x] **NodePool / EC2NodeClass 名** (`system-components`) は Task 8 と Task 11 (README) で一致
- [x] **Karpenter chart version** (`1.6.5`) は Task 0 Step 3 (reachability) と Task 7 (helmfile.yaml.version) で一致
- [x] **Helm chart values 構造** (`settings.clusterName` / `settings.interruptionQueue` / `serviceAccount.annotations`) は Task 7 と chart 1.6.5 の values.yaml schema で一致 (Task 0 でも reachability 確認済)

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) — 全 task の commit step で指定
- [x] `Co-Authored-By` 不付与 — 全 task の commit message に無し
- [x] PR は `--draft` — Tasks 5, 12, 15 の `gh pr create --draft`
- [x] 新規ブランチ初回 push: `git push -u origin HEAD` — Tasks 5, 12, 15
- [x] Conventional Commits — 全 commit が `feat(scope):` / `docs(scope):` 形式

### README 更新を含めた

- [x] Task 11 で kubernetes/README.md の Production Operations セクション 3 箇所修正 (Cluster overview / Foundation addon operations / Troubleshooting)

### Plan 1b / 1c-α / 1c-β の知見反映

- [x] helmfile v1.4 の parent → child env values 非継承への対応 → Task 7 で child helmfile に実値再定義 + 同期コメント (cilium パターン)
- [x] hydrate-component の `-e $(ENV)` 不足は Plan 1b で fix 済 (修正後の Makefile 前提) → Task 10 で `make hydrate ENV=production` 使用
- [x] 新 component の env-aware namespace 配置 → Task 7 namespace.yaml で対応
- [x] **Plan 1c-β L1 (IRSA module の random suffix)** → Task 6 で terragrunt output 経由で動的取得、Task 9 で実値転記
- [x] **Plan 1c-β L2 (.terraform.lock.hcl gitignore)** → Plan 内で git add 対象として言及せず
- [x] **Plan 1c-β L3 (kube-proxy state drift)** → 本 plan では該当する state drift なし (PR 1 で system MNG 撤去でなく追加なので)
- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT placeholder pattern 不要)** → 反映済。Task 7 では shell 変数 (`${KARPENTER_INTERRUPTION_QUEUE_NAME}`) を Task 6 の `/tmp/karpenter-outputs.json` から `jq` で取得 → そのまま yaml に埋め込む形で、最初から実値を直接記述する。同パターンを Task 8 (EC2NodeClass.spec.role) / Task 9 (helmfile.yaml.gotmpl) でも採用
- [x] **Plan 1c-β L5 (squash merge 後の branch reset rollback)** → Task 6 Step 1 + Task 13 Step 1 で明示的に `git fetch origin main && git reset --hard origin/main` + `git log --oneline origin/main..HEAD` 確認を組み込み

---

## Lessons Learned (post-execution)

PR 1 (#271) + #272 + PR 2 (#273) + #274 + #275 + PR 3 (#276) を merge して production cluster で全 verification battery (cordon + drain → Karpenter NodePool 移行 → system MNG 撤去) が pass した時点で判明した知見。次 plan 設計時に反映する。

### L1: `karpenter_bootstrap` MNG の命名は役割不明瞭で改善余地あり

`karpenter_bootstrap` は terraform-aws-modules/eks の Karpenter 公式 sample で使われている命名だが、本 cluster の構成では「Karpenter controller pod (replicas=2) のみをホストする MNG」という具体的役割を持つ。`bootstrap` は「初回起動」の含意があり、長期常駐する controller host としての機能を表現していない。

**影響:** Plan 2 の終盤で「system MNG と karpenter_bootstrap MNG の役割の違い」を文脈なしで説明する必要が生じた (Karpenter NodePool node が増えた後、bootstrap MNG が残り続ける必然性が命名から読み取れない)。

**対処:** 改名候補は `karpenter-controller-host` / `karpenter-controller` / `karpenter-static` 等で、role-explicit な名前。本 PR のスコープ外（rename は MNG 再作成相当の disruption を伴うため別 plan で扱う）。次回 fresh stack で同パターンを採用する場合は最初から role-explicit な名前にする。

### L2: standalone `eks-managed-node-group` submodule は cluster info を auto-wire しない

`terraform-aws-modules/eks` の parent module 内で `eks_managed_node_groups = { ... }` として定義する MNG は cluster endpoint / CA cert / service CIDR / IP family が submodule に自動配線されるが、`terraform-aws-modules/eks/aws//modules/eks-managed-node-group` を **standalone** で呼ぶ場合は同 5 値を呼び出し側から明示渡しする必要がある (AL2023 user data generator が要求)。

**影響:** Plan 2 PR 1 の初回 apply で

```
Error: Invalid value for variable
  cluster_service_cidr: Required for AL2023 launch templates.
```

が発生し、`aws/eks/lookup/outputs.tf` を `cluster_endpoint` / `certificate_authority_data` / `service_cidr` / `ip_family` を含む形に拡張して `aws/karpenter/modules/main.tf` から passthrough する hotfix が必要だった。

**対処:** standalone submodule の使用を選択する場合 (本 plan の course correction v2 で bootstrap MNG を `aws/karpenter/` に独立移動した結果)、Plan 段階で `cluster_endpoint` / `cluster_auth_base64` / `cluster_service_cidr` / `cluster_ip_family` の渡し口を `aws/eks/lookup/outputs.tf` に組み込んで設計する。本 plan の Task 3 (`aws/eks/lookup/`) と Task 4 Step 9 (`aws/karpenter/modules/main.tf`) は merge 後の hotfix で更新済。次 plan では標準テンプレートとして組み込む。

### L3: Karpenter v1.x controller IAM policy は customer-managed policy size 上限 (6,144 chars) を超過する

`terraform-aws-modules/eks/aws//modules/karpenter` v21 系のデフォルトは Karpenter v1.x の controller policy を customer-managed policy として作成するが、Karpenter v1 では accumulated permissions により size がデフォルトで 6,144 chars 超になり、apply 時に

```
LimitExceeded: Cannot exceed quota for PolicySize: 6144
```

で失敗する。AWS quota は managed policy 6,144 vs inline role policy 10,240 で、後者なら通る。

**影響:** Plan 2 PR 1 merge 直後の apply が失敗、hotfix #272 として `enable_inline_policy = true` を `module "karpenter"` に追加。

**対処:** `terraform-aws-modules/eks/aws//modules/karpenter` の `enable_inline_policy` variable description が直接このユースケース (Karpenter v1 size limit) を推奨しており、Plan 段階で気付ける。Karpenter sub-module を新規導入する plan では `enable_inline_policy = true` をデフォルトで指定する慣習に。

### L4: NodePool `consolidationPolicy` の有効値は Karpenter v1+ で変更されている

Karpenter v0.x (alpha API) では `WhenUnderutilized` が有効値だったが、v1+ (`karpenter.sh/v1` API) では `WhenEmpty` / `WhenEmptyOrUnderutilized` の 2 値のみ有効で、`WhenUnderutilized` は廃止。

**影響:** Plan 2 spec / plan markdown で `WhenUnderutilized` を引用していたため、PR 2 merge 後に Flux Kustomization が

```
NodePool.karpenter.sh "system-components" is invalid: spec.disruption.consolidationPolicy: Unsupported value: "WhenUnderutilized": supported values: "WhenEmpty", "WhenEmptyOrUnderutilized"
```

で dry-run validation 失敗、hotfix #274 で `WhenEmptyOrUnderutilized` に修正。

**対処:** 外部 API の enum 値を spec に転記する場合、spec 作成時点の install 対象 chart version (本 plan では Karpenter 1.6.5) の CRD schema を直接参照する慣習に。本 plan 後半 (Task 8 NodePool block) は merge 後修正済。

### L5: standalone MNG submodule への node SG 明示 attach が必要 (cross-node pod traffic)

`terraform-aws-modules/eks` の parent module は cluster とは別に「node SG」(`eks-${cluster_name}-node`) を作成し、parent 内 MNG に自動 attach する。これは node 間 pod-network traffic (CNI overlay 等) を許可する SG。standalone `eks-managed-node-group` submodule は **cluster_primary_security_group_id のみ** 自動 attach し、node SG は attach しない。

**影響:** Plan 2 PR 2 merge 後、bootstrap MNG node 上の Karpenter controller pod が CoreDNS pod (system MNG node 上) への DNS query で timeout し続ける現象が発生 (`getaddrinfo EAI_AGAIN sts.ap-northeast-1.amazonaws.com`)。控えめな表現で「DNS 不調」だが実体は cross-node pod traffic 全 drop。Karpenter pod が CrashLoopBackOff のまま rolling update 中に PDB blocker (L6) と複合して escalation。

**対処:** hotfix #275 で `aws/eks/lookup/main.tf` に tag-based discovery (`tag:Name = eks-${var.environment}-node`) を追加して `aws_security_group` data source を取得、`outputs.cluster.node_security_group_id` に export し、`aws/karpenter/modules/main.tf` の bootstrap MNG で `vpc_security_group_ids = [module.eks.cluster.node_security_group_id]` として明示 attach。次 plan で standalone submodule を使う場合はテンプレートに組み込む。

### L6: rolling update + PDB の組み合わせで Karpenter controller 自身が drain blocker になり得る

Plan 2 PR 1 + #272 apply 完了直後、bootstrap MNG が rolling update で 2 nodes を順次 replace するが、新 node の SG 設定 (L5 hotfix #275) が適用される前に Karpenter pod が再 schedule され DNS timeout で CrashLoopBackOff (NotReady 状態) になった。Karpenter 自身が PDB `disruptionsAllowed: 0` (NotReady のため available replica が常に 0) を持つため、rolling update の drain 工程は eviction を **無限ループ** で reject される。

**影響:** rolling update が 15 分以上 stall、新規 node が 4 台に積み上がり EC2 cost 増。

**対処:** `kubectl delete pod karpenter-... -n karpenter --force --grace-period=0` で eviction を bypass して force terminate。Pod は新 node (#275 の SG 適用済) に再 schedule され、DNS が通って Ready に。次 plan で同パターンに陥らないために:

- Karpenter sub-module を導入する PR では PR description の Test plan に "Karpenter pods become Ready within 5 min" を明示
- bootstrap MNG の rolling update 中は `kubectl get pods -n karpenter -w` で Ready 状態を監視
- 5 分超で NotReady の場合は force delete pod を recovery 手順として README troubleshooting に記載

### L7: 設計途中の major design pivot で spec / plan markdown が divergent

Plan 2 は brainstorming 段階で:

- v1 設計: bootstrap MNG を `aws/eks/modules/node_groups.tf` に追加 (system MNG と並置)
- v2 設計 (course correction): bootstrap MNG を `aws/karpenter/` に独立 stack 移動 + Pod Identity 採用 + standalone `eks-managed-node-group` submodule 利用

の 2 段階の design pivot を経た。spec / plan markdown は v1 当時の文章 (Task 2 で `aws/eks/modules/node_groups.tf` に追加、Task 13 で system block 削除) を残したまま実装は v2 で進行し、Task 4 (`aws/karpenter/`) のみ v2 に書き換え。結果として Plan Task 2 ヘッダ・Task 13 ヘッダ・Spec の File Structure / Components matrix に v1 表記が残存。

**影響:** 本 PR 作成時に「実装通りに plan を update する」のか「historical evidence として残す」のか判断必要。Plan 1c-β #270 の前例 (= 既存記述は evidence として残し、L マーカーで補足) に倣い後者を選択。post-mortem としてこの divergent の原因と対処を本 lesson で記録する。

**対処:** 次 plan で major design pivot が発生した場合:

- Pivot 直後に spec を直接書き換える (versioned subsection で v1/v2 を併記しない、現行 design のみ)
- Plan の File Structure / 該当 task ヘッダも同タイミングで update
- Implementer subagent への dispatch 時に「spec 上の最新 design に従う、plan markdown と乖離する場合は spec を正とする」と明示

そうしないと post-mortem で `course correction v2 で divergent` が常に lesson として残ることになる。
