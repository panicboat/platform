# aws/cost-management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AWS アカウント `559744160976` で Cost Optimization Hub と Compute Optimizer を有効化する Terragrunt サービス `aws/cost-management/` を新設する。

**Architecture:** 既存の `aws/{service}/modules + envs/{env}` 慣習に沿って新規サービスを追加。リソースは Cost Optimization Hub の enrollment + preferences と Compute Optimizer の enrollment の 3 つのみ。両 API は `us-east-1` 固定のため、provider region を modules 側でハードコードする。`develop` 環境（us-east-1）にのみデプロイ。

**Tech Stack:** Terragrunt 0.83.2、OpenTofu 1.6.0+、hashicorp/aws provider 6.43.0。

**Spec:** [docs/superpowers/specs/2026-05-03-aws-cost-management-design.md](../specs/2026-05-03-aws-cost-management-design.md)

**TDD note (IaC):** Terraform/Terragrunt はユニットテストフレームワークがないため、verification は `terraform fmt -check` / `terraform validate` / `terragrunt plan` の出力で行う。各タスクの「test」ステップはこれらに置き換える。

---

## File Structure

新規作成するファイル:

```
aws/cost-management/
├── root.hcl                           # Terragrunt root config + remote state
├── modules/
│   ├── terraform.tf                   # OpenTofu version + AWS provider (us-east-1 固定)
│   ├── variables.tf                   # environment, common_tags
│   ├── cost_optimization_hub.tf       # enrollment_status + preferences
│   ├── compute_optimizer.tf           # enrollment_status
│   └── outputs.tf                     # 空ファイル（一貫性のため作成）
└── envs/
    └── develop/
        ├── env.hcl                    # environment 固有 locals
        └── terragrunt.hcl             # root + env include + module source
```

各ファイルの責務:

- **root.hcl** — `vpc/root.hcl` と同形。`project_name = "cost-management"`, state key 設定, 共通 tags。
- **terraform.tf** — `terraform` block (required_version, required_providers) + `provider "aws"` (region = `"us-east-1"` ハードコード)。
- **variables.tf** — `environment`, `common_tags` のみ。`aws_region` は定義しない（modules 側固定のため）。
- **cost_optimization_hub.tf** — `aws_costoptimizationhub_enrollment_status` + `aws_costoptimizationhub_preferences`。
- **compute_optimizer.tf** — `aws_computeoptimizer_enrollment_status`。
- **outputs.tf** — 空（`# outputs.tf - No outputs; this service does not expose values to other stacks` のコメントのみ）。
- **env.hcl** — `vpc/envs/production/env.hcl` と同形。`environment = "develop"`, `aws_region = "us-east-1"`。
- **terragrunt.hcl** — `vpc/envs/production/terragrunt.hcl` と同形。`source = "../../modules"`, `inputs` で `environment` / `common_tags` を渡す（`aws_region` は渡さない）。

---

## Task 1: modules/ scaffolding (terraform.tf, variables.tf, outputs.tf)

Terragrunt から呼び出される modules ディレクトリの基礎を作る。リソース定義はまだ追加しない。

**Files:**
- Create: `aws/cost-management/modules/terraform.tf`
- Create: `aws/cost-management/modules/variables.tf`
- Create: `aws/cost-management/modules/outputs.tf`

- [ ] **Step 1: Create `aws/cost-management/modules/terraform.tf`**

```hcl
# terraform.tf - OpenTofu and provider configuration
# Cost Optimization Hub and Compute Optimizer APIs are only available in us-east-1.
# Region is pinned here so the service does not depend on env aws_region.

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
  region = "us-east-1"

  default_tags {
    tags = var.common_tags
  }
}
```

- [ ] **Step 2: Create `aws/cost-management/modules/variables.tf`**

```hcl
# variables.tf - Variables for cost-management module

variable "environment" {
  description = "Environment name (e.g., develop, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 3: Create `aws/cost-management/modules/outputs.tf`**

```hcl
# outputs.tf - No outputs; this service does not expose values to other stacks
```

- [ ] **Step 4: Verify formatting and syntax**

Run from repo root:

```bash
cd aws/cost-management/modules && terraform fmt -check -diff && cd -
```

Expected: no output, exit 0 (files are already correctly formatted).

If `terraform` command is not available, use `tofu` (OpenTofu) instead. Both should accept the same input.

- [ ] **Step 5: Commit**

```bash
git add aws/cost-management/modules/terraform.tf aws/cost-management/modules/variables.tf aws/cost-management/modules/outputs.tf
git commit -s -m "feat(aws/cost-management): scaffold module with provider pinned to us-east-1"
```

---

## Task 2: Cost Optimization Hub resources

Enrollment と preferences を 1 ファイルに記述する。`include_member_accounts = false` および `member_account_discount_visibility = "None"` で standalone account として有効化する。

**Files:**
- Create: `aws/cost-management/modules/cost_optimization_hub.tf`

- [ ] **Step 1: Create `aws/cost-management/modules/cost_optimization_hub.tf`**

```hcl
# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment and preferences

resource "aws_costoptimizationhub_enrollment_status" "this" {
  include_member_accounts = false
}

resource "aws_costoptimizationhub_preferences" "this" {
  savings_estimation_mode            = "BeforeDiscounts"
  member_account_discount_visibility = "None"

  depends_on = [aws_costoptimizationhub_enrollment_status.this]
}
```

- [ ] **Step 2: Verify formatting**

```bash
cd aws/cost-management/modules && terraform fmt -check -diff && cd -
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add aws/cost-management/modules/cost_optimization_hub.tf
git commit -s -m "feat(aws/cost-management): enroll Cost Optimization Hub with standalone account preferences"
```

---

## Task 3: Compute Optimizer enrollment

Compute Optimizer の opt-in だけ追加する。`recommendation_preferences` は本タスクでは扱わない（YAGNI）。

**Files:**
- Create: `aws/cost-management/modules/compute_optimizer.tf`

- [ ] **Step 1: Create `aws/cost-management/modules/compute_optimizer.tf`**

```hcl
# compute_optimizer.tf - AWS Compute Optimizer enrollment

resource "aws_computeoptimizer_enrollment_status" "this" {
  status                  = "Active"
  include_member_accounts = false
}
```

- [ ] **Step 2: Verify formatting**

```bash
cd aws/cost-management/modules && terraform fmt -check -diff && cd -
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add aws/cost-management/modules/compute_optimizer.tf
git commit -s -m "feat(aws/cost-management): enroll Compute Optimizer for this account"
```

---

## Task 4: Terragrunt root.hcl

サービスの root config を作成する。`vpc/root.hcl` をテンプレートとし、`project_name` / `Component` / state key を `cost-management` に置き換える。

**Files:**
- Create: `aws/cost-management/root.hcl`

- [ ] **Step 1: Create `aws/cost-management/root.hcl`**

```hcl
# root.hcl - Root Terragrunt configuration for cost-management
# This file contains common settings shared across all environments

locals {
  # Project metadata
  project_name = "cost-management"

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
    Component   = "cost-management"
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

    # Service-specific path: cost-management/<environment>/terraform.tfstate
    key    = "platform/cost-management/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    # Shared DynamoDB table for state locking across all services
    dynamodb_table = "terragrunt-state-locks"

    # Enable server-side encryption
    encrypt = true
  }
}

# Common inputs passed to all Terraform modules
# aws_region is intentionally omitted; the cost-management module pins region to us-east-1.
inputs = {
  environment = local.environment
  common_tags = local.common_tags
}
```

- [ ] **Step 2: Commit**

```bash
git add aws/cost-management/root.hcl
git commit -s -m "feat(aws/cost-management): add Terragrunt root config with shared remote state"
```

---

## Task 5: develop env config

`develop` 環境用の `env.hcl` と `terragrunt.hcl` を作成する。`vpc/envs/production/` をテンプレートとする。

**Files:**
- Create: `aws/cost-management/envs/develop/env.hcl`
- Create: `aws/cost-management/envs/develop/terragrunt.hcl`

- [ ] **Step 1: Create `aws/cost-management/envs/develop/env.hcl`**

```hcl
# env.hcl - Environment-specific configuration for develop

locals {
  # Environment-specific settings
  environment = "develop"

  # AWS configuration (Cost Optimization Hub / Compute Optimizer home region)
  aws_region = "us-east-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "cost-management"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 2: Create `aws/cost-management/envs/develop/terragrunt.hcl`**

```hcl
# terragrunt.hcl - Terragrunt configuration for develop environment

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
# aws_region is intentionally not passed; the module pins region to us-east-1.
inputs = {
  environment = include.env.locals.environment

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "cost-management"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add aws/cost-management/envs/develop/env.hcl aws/cost-management/envs/develop/terragrunt.hcl
git commit -s -m "feat(aws/cost-management): add develop environment in us-east-1"
```

---

## Task 6: Terragrunt plan verification

ここまでで全ファイルが揃ったので、`terragrunt init` + `terragrunt plan` で正しく 3 リソースの create が予定されることを確認する。

**Files:** （変更なし、検証のみ）

- [ ] **Step 1: Run `terragrunt init`**

```bash
cd aws/cost-management/envs/develop && terragrunt init && cd -
```

Expected: `Terraform has been successfully initialized!` (および remote backend / providers のダウンロード成功)。

前提: AWS 認証情報がローカルに設定されていること（`aws sts get-caller-identity` が account `559744160976` を返す状態）。

- [ ] **Step 2: Run `terragrunt validate`**

```bash
cd aws/cost-management/envs/develop && terragrunt validate && cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Run `terragrunt plan`**

```bash
cd aws/cost-management/envs/develop && terragrunt plan && cd -
```

Expected: `Plan: 3 to add, 0 to change, 0 to destroy.`

create されるリソース:
- `aws_costoptimizationhub_enrollment_status.this`
- `aws_costoptimizationhub_preferences.this`
- `aws_computeoptimizer_enrollment_status.this`

`Plan: 3 to add` 以外の数が出た場合は実装にずれがあるので、リソース定義を見直して修正する。

- [ ] **Step 4: No commit**

このタスクは検証のみ。コードに変更があれば前タスクのいずれかに戻ってコミットし直すこと。

---

## Out of This Plan (Follow-up Work)

以下は spec の "Follow-ups" に記載済み。**本 PR には含めない**:

1. `aws/github-oidc-auth/` の plan / apply ロールに `cost-optimization-hub:*` および `compute-optimizer:*` の最小権限を追加し CI で apply 可能にする。
2. ローカルからの `terragrunt apply` 実施 + AWS Console での enrollment 確認（実装範囲外、ユーザーが PR マージ後に実施）。
