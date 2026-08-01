# GWS SSO: AWS Identity Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AWS ログイン（Console + kubectl/EKS API）を、AWS IAM Identity Center + Google Workspace SAML/SCIM 連携によるロールベース SSO（Admin/Viewer の 2 Permission Set）に置き換える。既存の root-trust `eks-admin` role は、Identity Center 経由アクセスの動作確認後に削除する。

**Architecture:** account-wide singleton stack `aws/iam-identity-center` を新設し、`PlatformAdmin`（`AdministratorAccess`）/ `PlatformViewer`（`ReadOnlyAccess`）の 2 Permission Set を Google Workspace 側で SCIM 同期済の Google Group（`aws-admins@panicboat.net` / `aws-viewers@panicboat.net`）に Account Assignment する。`aws/eks/modules/access_entries.tf` は Identity Center が発行する Reserved SSO Role ARN を `data "aws_iam_roles"`（name_regex）で直接解決し、EKS Access Entry（`AmazonEKSClusterAdminPolicy` / `AmazonEKSViewPolicy`）に紐付ける。ロールバック不能なロックアウトを避けるため、新旧 2 経路を一時的に並走させてから旧経路（root-trust `eks-admin` role）を削除する 2 段階ロールアウトにする。

**Tech Stack:** OpenTofu `1.12.5`, Terragrunt, AWS provider `6.56.0`（`aws/eks` の既存 pin に合わせる）, AWS IAM Identity Center (`aws_ssoadmin_*` / `aws_identitystore_group`)

**Spec:** `docs/superpowers/specs/2026-08-01-gws-sso-design.md`

## Global Constraints

- OpenTofu `required_version = "1.12.5"`, AWS provider `version = "6.56.0"`（`aws/eks/modules/terraform.tf` と同一 pin）
- AWS region: `ap-northeast-1`
- Google Workspace domain: `panicboat.net`
- Google Group: `aws-admins@panicboat.net`（Admin）/ `aws-viewers@panicboat.net`（Viewer）、SCIM で Identity Store に同期済であることが前提
- EKS Access Policy ARN scheme: `arn:aws:eks::aws:cluster-access-policy/<NAME>`（IAM managed policy 形式ではない）
- git commit は `-s`（signoff）を付与、`Co-Authored-By` は付与しない

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `aws/iam-identity-center/root.hcl` | create | Terragrunt root 設定（remote state / common tags） |
| `aws/iam-identity-center/envs/production/env.hcl` | create | production 環境設定 |
| `aws/iam-identity-center/envs/production/terragrunt.hcl` | create | production terragrunt 設定 |
| `aws/iam-identity-center/modules/terraform.tf` | create | OpenTofu / AWS provider 宣言 |
| `aws/iam-identity-center/modules/variables.tf` | create | 入力変数 |
| `aws/iam-identity-center/modules/main.tf` | create | Permission Set × 2、managed policy attachment × 2、account assignment × 2 |
| `aws/iam-identity-center/modules/outputs.tf` | create | permission set ARN 等の output |
| `aws/iam-identity-center/README.md` | create | singleton stack の運用メモ |
| `aws/eks/modules/access_entries.tf` | modify（2 回: Task 2 で追加、Task 4 で `human_admin` 削除） | Identity Center Reserved Role → EKS Access Entry |
| `aws/eks/modules/iam_admin.tf` | delete（Task 4） | root-trust `eks-admin` role（不要になる） |
| `aws/eks/modules/outputs.tf` | modify（Task 4） | `admin_role_arn` / `admin_role_name` output 削除 |
| `aws/eks/README.md` | modify（Task 5） | kubectl access 手順を Identity Center ベースに更新 |

**変更しないもの**: `aws/github-oidc-auth/*`（CI 用 machine identity）、`kubernetes/*`（別 plan `2026-08-02-gws-sso-grafana-domain.md` で扱う）

---

## Task 0: Pre-flight — worktree/branch 状態 + 手動 Manual Setup の完了確認

**Files:** (確認のみ、変更なし)

**Context:** `docs/superpowers/specs/2026-08-01-gws-sso-design.md` の Manual Setup（1〜4）が完了していないと、本 plan の Terraform は `NotFound` で失敗する。Terraform を書き始める前に前提を確認する。

- [ ] **Step 1: worktree/branch 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-gws-sso
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead（`docs(specs): add GWS SSO design for AWS Identity Center and Grafana`）

- [ ] **Step 2: AWS IAM Identity Center instance の有効化を確認**

```bash
aws sso-admin list-instances --region ap-northeast-1 --output table
```

Expected: 1 件の instance が `Status: ACTIVE` で表示される。表示されない場合は spec の Manual Setup Step 1 が未完了 — panicboat に完了を依頼してから先に進む。

- [ ] **Step 3: Google Workspace Group の SCIM 同期を確認**

Step 2 の出力から `IdentityStoreId` を控え、以下を実行:

```bash
IDENTITY_STORE_ID="<Step 2 で取得した IdentityStoreId>"
aws identitystore list-groups \
  --identity-store-id "${IDENTITY_STORE_ID}" \
  --region ap-northeast-1 \
  --query "Groups[].DisplayName" \
  --output table
```

Expected: `aws-admins` と `aws-viewers` の 2 件が表示される。表示されない場合は spec の Manual Setup Step 2〜4（SAML/SCIM 設定 + Google Group 作成）が未完了。

---

## Task 1: `aws/iam-identity-center` stack 新設（Permission Set + Account Assignment）

**Files:**
- Create: `aws/iam-identity-center/root.hcl`
- Create: `aws/iam-identity-center/envs/production/env.hcl`
- Create: `aws/iam-identity-center/envs/production/terragrunt.hcl`
- Create: `aws/iam-identity-center/modules/terraform.tf`
- Create: `aws/iam-identity-center/modules/variables.tf`
- Create: `aws/iam-identity-center/modules/main.tf`
- Create: `aws/iam-identity-center/modules/outputs.tf`
- Create: `aws/iam-identity-center/README.md`

**Context:** `aws/iam-service-linked-roles` と同じ account-wide singleton stack パターン（`envs/production` のみ）を踏襲する。

- [ ] **Step 1: `aws/iam-identity-center/modules/terraform.tf` を作成**

```hcl
# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
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

- [ ] **Step 2: `aws/iam-identity-center/modules/variables.tf` を作成**

```hcl
# variables.tf - Input variables for the IAM Identity Center module

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "admin_group_display_name" {
  description = "Google Workspace group (SCIM 同期済) に付与する PlatformAdmin permission set の対象グループ名"
  type        = string
  default     = "aws-admins"
}

variable "viewer_group_display_name" {
  description = "Google Workspace group (SCIM 同期済) に付与する PlatformViewer permission set の対象グループ名"
  type        = string
  default     = "aws-viewers"
}
```

- [ ] **Step 3: `aws/iam-identity-center/modules/main.tf` を作成**

```hcl
# main.tf - Account 単位の IAM Identity Center Permission Set / Account Assignment。
#
# Identity Center instance 自体の有効化と、Google Workspace 側の SAML app /
# SCIM provisioning 設定は AWS Console / Google Admin Console での手動作業
# (= docs/superpowers/specs/2026-08-01-gws-sso-design.md の Manual Setup 参照)。
# ここでは既存 instance を data source で参照し、Permission Set と
# Google Group (SCIM 同期済) への Account Assignment のみを管理する。
#
# aws/iam-service-linked-roles と同様、account 単位 singleton stack として
# envs/production のみを使う。

data "aws_ssoadmin_instances" "this" {}

data "aws_caller_identity" "current" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# Google Workspace 側で作成し SCIM で Identity Store に同期済のグループ。
# 未同期の状態で apply すると NotFound で失敗する (= Task 0 の pre-flight で確認済の前提)。
data "aws_identitystore_group" "admin" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.admin_group_display_name
    }
  }
}

data "aws_identitystore_group" "viewer" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.viewer_group_display_name
    }
  }
}

resource "aws_ssoadmin_permission_set" "admin" {
  name             = "PlatformAdmin"
  description      = "Full AWS account access via Google Workspace SSO (aws-admins group)"
  instance_arn     = local.instance_arn
  session_duration = "PT1H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# account_assignment は managed_policy_attachment とは互いに他方を
# 参照しないため、暗黙の依存関係が発生しない。Account Assignment の
# provisioning 時点でポリシーが未アタッチだと不完全な状態で provision
# されうるため、明示的に depends_on で順序を固定する。
resource "aws_ssoadmin_account_assignment" "admin" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn

  principal_id   = data.aws_identitystore_group.admin.group_id
  principal_type = "GROUP"

  target_id   = data.aws_caller_identity.current.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [aws_ssoadmin_managed_policy_attachment.admin]
}

resource "aws_ssoadmin_permission_set" "viewer" {
  name             = "PlatformViewer"
  description      = "Read-only AWS account access via Google Workspace SSO (aws-viewers group)"
  instance_arn     = local.instance_arn
  session_duration = "PT1H"
}

resource "aws_ssoadmin_managed_policy_attachment" "viewer" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.viewer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_ssoadmin_account_assignment" "viewer" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.viewer.arn

  principal_id   = data.aws_identitystore_group.viewer.group_id
  principal_type = "GROUP"

  target_id   = data.aws_caller_identity.current.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [aws_ssoadmin_managed_policy_attachment.viewer]
}
```

- [ ] **Step 4: `aws/iam-identity-center/modules/outputs.tf` を作成**

```hcl
# outputs.tf - Outputs for the IAM Identity Center module

output "instance_arn" {
  description = "IAM Identity Center instance ARN"
  value       = local.instance_arn
}

output "admin_permission_set_arn" {
  description = "ARN of the PlatformAdmin permission set"
  value       = aws_ssoadmin_permission_set.admin.arn
}

output "viewer_permission_set_arn" {
  description = "ARN of the PlatformViewer permission set"
  value       = aws_ssoadmin_permission_set.viewer.arn
}
```

- [ ] **Step 5: `aws/iam-identity-center/root.hcl` を作成**

```hcl
# root.hcl - Root Terragrunt configuration for iam-identity-center
# This file contains common settings shared across all environments

locals {
  # Project metadata
  project_name = "iam-identity-center"

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
    Component   = "iam-identity-center"
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

    # Service-specific path: iam-identity-center/<environment>/terraform.tfstate
    key    = "platform/iam-identity-center/${local.environment}/terraform.tfstate"
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
}
```

- [ ] **Step 6: `aws/iam-identity-center/envs/production/env.hcl` を作成**

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
    Component   = "iam-identity-center"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 7: `aws/iam-identity-center/envs/production/terragrunt.hcl` を作成**

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

# Reference to Terraform modules
terraform {
  source = "../../modules"
}

# Input variables for the module
inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "iam-identity-center"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 8: `aws/iam-identity-center/README.md` を作成**

```markdown
# iam-identity-center

AWS IAM Identity Center の Permission Set (`PlatformAdmin` / `PlatformViewer`) と、Google Workspace (SCIM 同期済) Group への Account Assignment を管理する stack。

## Instance 自体は Terraform 管理外

Identity Center instance の有効化、Google Workspace 側の SAML app 設定、SCIM provisioning は AWS Console / Google Admin Console での手動作業。手順は `docs/superpowers/specs/2026-08-01-gws-sso-design.md` の Manual Setup を参照。

## envs/production のみを使う

account 単位の singleton stack（Identity Center instance は 1 account 1 instance）。`envs/production` 以外の環境ディレクトリを追加しないこと。

## 前提: Google Group が SCIM 同期済であること

`data.aws_identitystore_group` は Google Workspace 側で作成し SCIM 同期済のグループ（`aws-admins` / `aws-viewers`）を name lookup する。未同期の状態で apply すると `NotFound` で失敗する。
```

- [ ] **Step 9: format + validate（AWS 認証不要）**

```bash
terraform fmt -check aws/iam-identity-center/modules/*.tf
terraform -chdir=aws/iam-identity-center/modules init -backend=false
terraform -chdir=aws/iam-identity-center/modules validate
```

Expected: `fmt -check` は差分なし（exit 0）。`validate` は `Success! The configuration is valid.`

- [ ] **Step 10: terragrunt plan（要 AWS 認証 + Task 0 の前提確認済）**

```bash
cd aws/iam-identity-center/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt plan
```

Expected: `Plan: 6 to add, 0 to change, 0 to destroy`（`aws_ssoadmin_permission_set` × 2、`aws_ssoadmin_managed_policy_attachment` × 2、`aws_ssoadmin_account_assignment` × 2）。`NotFound` エラーが出る場合は Task 0 の Manual Setup 確認に戻る。

- [ ] **Step 11: terragrunt apply**

```bash
cd aws/iam-identity-center/envs/production
TG_TF_PATH=tofu terragrunt apply -auto-approve
```

Expected: Step 10 と同じ 6 resources が `Apply complete!` で作成される。

- [ ] **Step 12: Commit**

```bash
git add aws/iam-identity-center/
git commit -s -m "feat(aws): add IAM Identity Center Permission Sets for Google Workspace SSO

PlatformAdmin / PlatformViewer permission set を SCIM 同期済の Google
Group (aws-admins / aws-viewers) に account assignment する。Identity
Center instance と Google 側 SAML/SCIM 設定は手動 (spec の Manual Setup 参照)。"
```

---

## Task 2: `aws/eks` に Identity Center 経由の Access Entry を追加（既存 `eks-admin` 経路と並走）

**Files:**
- Modify: `aws/eks/modules/access_entries.tf`

**Context:** ロックアウトを避けるため、旧 root-trust `eks-admin` role 経路を残したまま Identity Center 経路を追加する。両方が並走した状態で Task 3 の動作確認を行い、確認が取れてから Task 4 で旧経路を削除する。

- [ ] **Step 1: `aws/eks/modules/access_entries.tf` を編集**

Old:
```hcl
# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: only the human kubectl admin role is granted RBAC.
# The CI apply role (github-oidc-auth-production-github-actions-role)
# operates on AWS APIs only and never touches Kubernetes API; under the
# GitOps model, all Kubernetes-side changes flow through Flux CD.
#
# Note on policy_arn format: EKS Access Policies use a dedicated ARN
# scheme `arn:aws:eks::aws:cluster-access-policy/<NAME>`, NOT the IAM
# managed policy form `arn:aws:iam::aws:policy/<NAME>`. Passing the IAM
# form to AssociateAccessPolicy yields InvalidParameterException (400).

locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

New:
```hcl
# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: only human kubectl principals get RBAC. The CI apply
# role (github-oidc-auth-production-github-actions-role) operates on AWS APIs
# only and never touches Kubernetes API; under the GitOps model, all
# Kubernetes-side changes flow through Flux CD.
#
# human_admin (root-trust eks-admin role) is being phased out in favor of AWS
# IAM Identity Center (aws/iam-identity-center, Google Workspace SSO). Both
# paths are active in parallel until Identity Center kubectl access is
# verified end-to-end, after which human_admin is removed
# (docs/superpowers/plans/2026-08-02-gws-sso-aws-identity-center.md Task 4).
#
# Reserved SSO role ARNs are only assigned by AWS after the Permission Set's
# Account Assignment exists (aws/iam-identity-center), so the data sources
# below return an empty list if that stack hasn't been applied yet.
#
# Note on policy_arn format: EKS Access Policies use a dedicated ARN
# scheme `arn:aws:eks::aws:cluster-access-policy/<NAME>`, NOT the IAM
# managed policy form `arn:aws:iam::aws:policy/<NAME>`. Passing the IAM
# form to AssociateAccessPolicy yields InvalidParameterException (400).

data "aws_iam_roles" "identity_center_admin" {
  name_regex  = "AWSReservedSSO_PlatformAdmin_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "identity_center_viewer" {
  name_regex  = "AWSReservedSSO_PlatformViewer_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    identity_center_admin = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_admin.arns)[0]

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    identity_center_viewer = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_viewer.arns)[0]

      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: format check**

```bash
terraform fmt -check aws/eks/modules/access_entries.tf
```

Expected: 出力なし（exit 0）

- [ ] **Step 3: terragrunt plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan
```

Expected: `Plan: 2 to add, 0 to change, 0 to destroy`（`identity_center_admin` / `identity_center_viewer` の access entry 2 件のみ追加、既存 `human_admin` は無変更）。`data.aws_iam_roles` が空リストを返す場合は Task 1 の apply が未完了か、Permission Set 名の typo が原因 — `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --query "Roles[].RoleName"` で実際の Reserved Role 名を確認する。

- [ ] **Step 4: terragrunt apply**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt apply -auto-approve
```

Expected: Step 3 と同じ 2 resources が `Apply complete!` で作成される。

- [ ] **Step 5: Commit**

```bash
git add aws/eks/modules/access_entries.tf
git commit -s -m "feat(aws/eks): add Identity Center access entries alongside eks-admin

PlatformAdmin/PlatformViewer の Reserved SSO Role に対する EKS Access
Entry を追加する。ロックアウト防止のため、root-trust eks-admin role
の human_admin entry は動作確認が取れるまで並走させる。"
```

---

## Task 3: Identity Center 経由 kubectl access の end-to-end 確認

**Files:** (確認のみ、変更なし)

**Context:** Task 4 で旧経路を削除する前に、新経路（Identity Center → Permission Set → Access Entry）が実際に動作することを確認する。この確認が取れない限り Task 4 に進まない。

- [ ] **Step 1: AWS CLI に Identity Center profile を設定**

```bash
aws configure sso
```

対話プロンプトで以下を入力:
- `SSO session name`: `panicboat`
- `SSO start URL`: Identity Center Access Portal の URL（AWS Console の IAM Identity Center → Settings で確認）
- `SSO region`: `ap-northeast-1`
- ブラウザでログイン（`panicboat@panicboat.net`）後、Account を選択
- `PlatformAdmin` role を選択
- `CLI default client Region`: `ap-northeast-1`
- `profile name`: `platform-admin`

- [ ] **Step 2: SSO login**

```bash
aws sso login --profile platform-admin
```

Expected: ブラウザが開き Google ログイン画面へリダイレクト → `panicboat@panicboat.net` でログイン → `Successfully logged into Start URL` が表示される

- [ ] **Step 3: kubeconfig 更新 + kubectl 疎通確認**

```bash
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production --profile platform-admin
AWS_PROFILE=platform-admin kubectl get nodes
```

Expected: node 一覧が返る（`Unauthorized` にならない）

- [ ] **Step 4: Admin 権限の確認**

```bash
AWS_PROFILE=platform-admin kubectl auth can-i create namespaces
```

Expected: `yes`

---

## Task 4: root-trust `eks-admin` role の削除（Identity Center への完全移行）

**Files:**
- Modify: `aws/eks/modules/access_entries.tf`
- Delete: `aws/eks/modules/iam_admin.tf`
- Modify: `aws/eks/modules/outputs.tf`

**Context:** Task 3 で Identity Center 経由の kubectl access が確認できたので、旧 root-trust `eks-admin` role とその access entry を削除する。**Task 3 の確認が取れていない場合はこのタスクを実行しない**（現状唯一の kubectl access 経路を壊すリスクがある）。

- [ ] **Step 1: `aws/eks/modules/access_entries.tf` から `human_admin` を削除**

Old（Task 2 で追加した状態）:
```hcl
locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    identity_center_admin = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_admin.arns)[0]

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    identity_center_viewer = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_viewer.arns)[0]

      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

New（ファイル全体）:
```hcl
# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# Human kubectl access flows entirely through AWS IAM Identity Center (SAML
# federation with Google Workspace, see aws/iam-identity-center). The CI
# apply role (github-oidc-auth-production-github-actions-role) operates on
# AWS APIs only and never touches Kubernetes API; under the GitOps model, all
# Kubernetes-side changes flow through Flux CD.
#
# Reserved SSO role ARNs are only assigned by AWS after the Permission Set's
# Account Assignment exists (aws/iam-identity-center), so the data sources
# below return an empty list if that stack hasn't been applied yet.
#
# Note on policy_arn format: EKS Access Policies use a dedicated ARN
# scheme `arn:aws:eks::aws:cluster-access-policy/<NAME>`, NOT the IAM
# managed policy form `arn:aws:iam::aws:policy/<NAME>`. Passing the IAM
# form to AssociateAccessPolicy yields InvalidParameterException (400).

data "aws_iam_roles" "identity_center_admin" {
  name_regex  = "AWSReservedSSO_PlatformAdmin_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "identity_center_viewer" {
  name_regex  = "AWSReservedSSO_PlatformViewer_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  access_entries = {
    identity_center_admin = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_admin.arns)[0]

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    identity_center_viewer = {
      principal_arn = tolist(data.aws_iam_roles.identity_center_viewer.arns)[0]

      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: `aws/eks/modules/iam_admin.tf` を削除**

```bash
git rm aws/eks/modules/iam_admin.tf
```

- [ ] **Step 3: `aws/eks/modules/outputs.tf` から `admin_role_arn` / `admin_role_name` を削除**

Old:
```hcl
output "admin_role_arn" {
  description = "ARN of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.arn
}

output "admin_role_name" {
  description = "Name of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.name
}

output "alb_controller_role_arn" {
```

New:
```hcl
output "alb_controller_role_arn" {
```

- [ ] **Step 4: format check**

```bash
terraform fmt -check aws/eks/modules/*.tf
```

Expected: 出力なし（exit 0）

- [ ] **Step 5: terragrunt plan**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan
```

Expected: `Plan: 0 to add, 0 to change, 3 to destroy`（`aws_eks_access_entry.this["human_admin"]` / `aws_iam_role_policy.eks_admin_describe_cluster` / `aws_iam_role.eks_admin`）。`identity_center_admin` / `identity_center_viewer` の access entry には変更がないこと。

- [ ] **Step 6: terragrunt apply**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt apply -auto-approve
```

Expected: Step 5 と同じ 3 resources が `Apply complete!` で destroy される。

- [ ] **Step 7: 旧 role の削除確認**

```bash
aws iam get-role --role-name eks-admin-production 2>&1 | head -3
```

Expected: `An error occurred (NoSuchEntity) when calling the GetRole operation`

- [ ] **Step 8: Identity Center 経路が引き続き動作することを確認**

```bash
AWS_PROFILE=platform-admin kubectl get nodes
```

Expected: node 一覧が返る（旧経路削除の影響を受けない）

- [ ] **Step 9: Commit**

```bash
git add aws/eks/modules/access_entries.tf aws/eks/modules/outputs.tf
git commit -s -m "feat(aws/eks): remove root-trust eks-admin role

Identity Center 経由 kubectl access の動作確認が取れたため、root-trust
eks-admin role と対応する access entry / output を削除する。人間の
kubectl/Console access は AWS IAM Identity Center 経由の 1 本になる。"
```

---

## Task 5: `aws/eks/README.md` を Identity Center ベースの手順に更新

**Files:**
- Modify: `aws/eks/README.md`

- [ ] **Step 1: 「kubectl access」節を置き換え**

Old:
```markdown
## kubectl access

人間が kubectl を叩く経路は **`eks-admin-production` IAM role を assume する 1 本のみ**。CI 上の apply role は AWS API のみで Kubernetes API は触らない（GitOps 原則）。

### Quick start (recommended: login script)

`panicboat/ansible` で deploy される `eks-login.sh` を source する：

```bash
source ~/Workspace/eks-login.sh                          # → eks-production / ap-northeast-1
source ~/Workspace/eks-login.sh production                # 同上 (明示)
source ~/Workspace/eks-login.sh staging us-west-2        # 未知 env は region 必須
```

スクリプトは：

1. env / region を解決（既知 env は default region、未知 env は明示必須）
2. `aws sts get-caller-identity` で現在の account ID を動的取得
3. `eks-admin-${env}` role を assume（session 1 時間）
4. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` を export
5. `aws eks update-kubeconfig` で kubeconfig 更新

完了後 `kubectl get nodes` 等が通るようになる。

> Source 必須（実行しても export が parent shell に反映されない）。スクリプトは `source` チェックで弾く。

### Manual login (without script)

```bash
ENV=production
REGION=ap-northeast-1

ADMIN_ROLE_ARN=$(cd aws/eks/envs/${ENV} && TG_TF_PATH=tofu terragrunt output -raw admin_role_arn)
CREDS=$(aws sts assume-role \
  --role-arn "$ADMIN_ROLE_ARN" \
  --role-session-name "kubectl-${USER:-debug}" \
  --query 'Credentials' \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)

aws eks update-kubeconfig --region "${REGION}" --name "eks-${ENV}"
```

session を破棄するには `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`。
```

New:
```markdown
## kubectl access

人間が kubectl を叩く経路は **AWS IAM Identity Center（Google Workspace SSO）経由の 1 本のみ**。CI 上の apply role は AWS API のみで Kubernetes API は触らない（GitOps 原則）。

Permission Set は 2 種類:

| Permission Set | Google Group | EKS Access Policy |
|---|---|---|
| `PlatformAdmin` | `aws-admins@panicboat.net` | `AmazonEKSClusterAdminPolicy`（cluster-admin 相当） |
| `PlatformViewer` | `aws-viewers@panicboat.net` | `AmazonEKSViewPolicy`（読み取り専用） |

### Quick start (recommended: pre-configured profile)

初回のみ `aws configure sso` で profile を作成する（Identity Center Access Portal の Start URL は AWS Console の IAM Identity Center → Settings で確認）。

```bash
aws sso login --profile platform-admin
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production --profile platform-admin
```

完了後 `AWS_PROFILE=platform-admin kubectl get nodes` 等が通るようになる。session は Permission Set の `session_duration`（1 時間）で失効し、再度 `aws sso login` が必要。

### Manual login (profile 未設定の場合)

```bash
aws sso login --sso-start-url <identity-center-start-url> --sso-region ap-northeast-1
```

ログイン後に所属する Google Group（`aws-admins` / `aws-viewers`）に応じた Permission Set が選択できる。
```

- [ ] **Step 2: Architecture 節の Access Entries 行を更新**

Old:
```markdown
- **Access Entries**: `eks-admin-production` role 1 本のみに `AmazonEKSClusterAdminPolicy` を付与。`enable_cluster_creator_admin_permissions = false` でステルス admin を防止。
```

New:
```markdown
- **Access Entries**: AWS IAM Identity Center の Permission Set 2 本（`PlatformAdmin` → `AmazonEKSClusterAdminPolicy` / `PlatformViewer` → `AmazonEKSViewPolicy`）に対応する Reserved SSO Role にのみ付与。`enable_cluster_creator_admin_permissions = false` でステルス admin を防止。
```

- [ ] **Step 3: Troubleshooting 表の assume-role 行を更新**

Old:
```markdown
| `kubectl: error: You must be logged in to the server (Unauthorized)` | session credentials が expired（max 1 時間）または未 export。`eks-login.sh` を再 source。 |
| `kubectl: error: ... credentials` after switching shells | 新 shell では assume-role の env vars が引き継がれない。再 source。 |
| `aws sts assume-role: AccessDenied` | 実行している IAM principal に `sts:AssumeRole` resource permission がない。IAM 側で付与（リポジトリ管理外）。 |
```

New:
```markdown
| `kubectl: error: You must be logged in to the server (Unauthorized)` | SSO session credentials が expired（max 1 時間）。`aws sso login --profile platform-admin` を再実行。 |
| `kubectl: error: ... credentials` after switching shells | 新 shell では `AWS_PROFILE` が引き継がれない。`export AWS_PROFILE=platform-admin` を再実行するか都度 `--profile` を指定。 |
| `aws sso login` 後も Permission Set が選択できない | Google Group（`aws-admins` / `aws-viewers`）への所属が SCIM 同期されていない可能性。Google Admin Console でグループ所属を確認。 |
```

- [ ] **Step 4: Commit**

```bash
git add aws/eks/README.md
git commit -s -m "docs(aws/eks): document Identity Center kubectl access flow

root-trust eks-admin role の削除に合わせ、kubectl access 手順を
aws sso login ベースに更新する。"
```

---

## Task 6: 最終確認 + 外部ツールの引き継ぎ事項の明記

**Files:** (確認のみ、変更なし)

**Context:** `panicboat/ansible` 側の `eks-login.sh`（もしくはユーザーの zsh 環境の `eks-login` 関数）は `eks-admin-${env}` role の `sts:AssumeRole` に依存しており、この repo の管理外。Task 4 で role を削除した時点でこれらは動作しなくなるため、repo 外での更新が必要であることを明記する（このタスク自体はコード変更を行わない）。

- [ ] **Step 1: kubectl access の最終疎通確認**

```bash
AWS_PROFILE=platform-admin kubectl get nodes
AWS_PROFILE=platform-admin kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Expected: node 一覧が返り、異常 Pod がないこと（あれば本 plan とは無関係な既存問題の可能性、別途調査）

- [ ] **Step 2: 引き継ぎ事項を panicboat に共有**

以下は本 repo の変更では対応できない、repo 外の手動対応が必要な事項:

- `panicboat/ansible` 側の `eks-login.sh`（または個人の zsh 環境の `eks-login` 関数）が `eks-admin-${env}` role の assume に依存している場合、`aws sso login --profile platform-admin` ベースに書き換える必要がある（`eks-admin-production` role は Task 4 で削除済のため、既存スクリプトは `AccessDenied` または `NoSuchEntity` で失敗する）
- Viewer（`PlatformViewer`）権限の動作確認は、Google Workspace 側に `aws-viewers` グループのメンバーが実在する場合にのみ実施可能。本 plan 実行時点で該当メンバーがいなければ、実際に Viewer メンバーが追加された際に別途確認する

---
