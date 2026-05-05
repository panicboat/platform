# EKS Production: Observability AWS Infrastructure (Phase 3 Sub-project 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 3 観測スタック (Prometheus + Thanos sidecar / Loki / Tempo) 用の AWS-side infra を 3 つの independent terragrunt stack (`aws/eks-metrics/`, `aws/eks-logs/`, `aws/eks-traces/`) として provisioning する。各 stack は S3 bucket + Pod Identity Association + IAM role + S3 policy を含み、Sub-project 2-4 (Helm chart 導入) の前提となる。

**Architecture:** 3 stack 構成で stack 単位の atomic 性 (将来 managed service 移行で AMP / CloudWatch Logs / X-Ray に切り替える時、該当 stack のみ touch して他に影響を与えない) を確保。Plan 2 `aws/karpenter/` pattern (terragrunt boilerplate + Pod Identity) を踏襲。本 PR は AWS-side のみ provision で K8s cluster 側は無変化 (Sub-project 2-4 で初めて `monitoring` namespace + 各 SA を chart install で作成)。

**Tech Stack:** terragrunt + OpenTofu / terraform-aws-modules/s3-bucket/aws / `aws_eks_pod_identity_association` resource (terraform AWS provider 6.x) / aws/eks/lookup module (Plan 2 で確立した cross-stack lookup pattern)

**Spec:** `docs/superpowers/specs/2026-05-05-eks-production-observability-aws-infra-design.md`

---

## File Structure

新規作成 33 ファイル (3 stack × 11 ファイル):

```
aws/eks-metrics/                       # Sub-project 1 stack (Prometheus + Thanos)
├── Makefile
├── root.hcl
├── envs/production/
│   ├── env.hcl
│   └── terragrunt.hcl
└── modules/
    ├── terraform.tf                   # OpenTofu version + AWS provider
    ├── variables.tf                   # environment / aws_region / common_tags
    ├── lookups.tf                     # aws/eks/lookup から cluster name 取得
    ├── main.tf                        # S3 bucket + IAM role + S3 policy + Pod Identity Association
    └── outputs.tf                     # bucket_name / bucket_path_prefix / pod_identity_role_name

aws/eks-logs/                          # Sub-project 1 stack (Loki) — 同型
└── (同上 11 ファイル、retention 30d、bucket loki-<account-id>、SA loki)

aws/eks-traces/                        # Sub-project 1 stack (Tempo) — 同型
└── (同上 11 ファイル、retention 7d、bucket tempo-<account-id>、SA tempo)
```

**Files の責務分離:**

| File | 責務 |
|---|---|
| `Makefile` | ローカル開発の terragrunt wrapper (init / plan / apply / validate / destroy 等) |
| `root.hcl` | terragrunt remote state 設定 (S3 bucket + DynamoDB lock)、stack 全体の common config |
| `envs/production/env.hcl` | environment 固有 locals (environment / aws_region / environment_tags) |
| `envs/production/terragrunt.hcl` | environment-specific input + module source 指定 |
| `modules/terraform.tf` | OpenTofu version + AWS provider version |
| `modules/variables.tf` | environment / aws_region / common_tags の宣言 |
| `modules/lookups.tf` | cross-stack lookup (aws/eks/lookup module を呼ぶ) |
| `modules/main.tf` | S3 bucket + IAM role + S3 policy + Pod Identity Association |
| `modules/outputs.tf` | Sub-project 2-4 が consume する outputs |

各 stack は **3 stack の boilerplate を独立に持つ** (= aws/karpenter/ pattern と同型)。stack 間の terraform 依存は無い (= 各 stack は aws/eks/lookup のみ depend)。

---

## Task 0: 前提条件の確認 + branch sync

**Files:** (read-only confirmation)

事前確認のみ。Plan 2 / tuning で確立した Plan-as-self-contained の patten。

- [ ] **Step 1: branch / worktree 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
git fetch origin main
git status
git log --oneline origin/main..HEAD
```

Expected:
- `On branch feat/eks-production-observability-aws-infra`
- spec の 1 commit (`34d1f6a`) が ahead of origin/main
- working tree clean

- [ ] **Step 2: AWS account-id 確認 (bucket 命名で使う)**

```bash
aws sts get-caller-identity --query 'Account' --output text
```

Expected: `559744160976` (panicboat production account)

この account-id は spec / plan を通して bucket 命名 (`thanos-559744160976` 等) に使われる。違う値が返ってきたら **STOP**、context が違う環境で実行している可能性。

- [ ] **Step 3: EKS Pod Identity Agent enable 確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get daemonset -n kube-system eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 --query 'associations[*].{ns:namespaceName,sa:serviceAccount}'
```

Expected:
- DaemonSet `eks-pod-identity-agent` が `kube-system` namespace に存在 + 各 node で Running
- Pod Identity Associations のリストに既存 (Karpenter 用 `karpenter:karpenter`) が表示される (Plan 2 で provision 済)

- [ ] **Step 4: aws/eks/lookup module の output 確認 (Sub-project 1 で使う)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
cat aws/eks/lookup/outputs.tf
```

Expected: `output "cluster"` が定義されており、`name` (= `eks-production`) を含む。

- [ ] **Step 5: `monitoring` namespace の現状確認**

```bash
kubectl get namespace monitoring 2>&1 || echo "expected: NotFound"
```

Expected: `Error from server (NotFound): namespaces "monitoring" not found` (本 PR では namespace を作成しない、Sub-project 2 で chart install 時に作成)。

- [ ] **Step 6: 既存 S3 buckets 確認 (衝突チェック)**

```bash
aws s3 ls --region ap-northeast-1 | grep -E "thanos-|loki-|tempo-"
```

Expected: マッチなし (= 本 PR で新規 3 bucket 作成可能)。

- [ ] **Step 7: 既存 IAM role 確認 (命名衝突チェック)**

```bash
aws iam list-roles --query 'Roles[?starts_with(RoleName, `eks-production-prometheus`) || starts_with(RoleName, `eks-production-loki`) || starts_with(RoleName, `eks-production-tempo`)].RoleName'
```

Expected: 空配列 `[]` (= 本 PR で新規 3 IAM role 作成可能)。

---

## Task 1: aws/eks-metrics/ stack 新規作成 (Thanos S3 + Pod Identity for prometheus SA)

**Files:**
- Create: `aws/eks-metrics/Makefile`
- Create: `aws/eks-metrics/root.hcl`
- Create: `aws/eks-metrics/envs/production/env.hcl`
- Create: `aws/eks-metrics/envs/production/terragrunt.hcl`
- Create: `aws/eks-metrics/modules/terraform.tf`
- Create: `aws/eks-metrics/modules/variables.tf`
- Create: `aws/eks-metrics/modules/lookups.tf`
- Create: `aws/eks-metrics/modules/main.tf`
- Create: `aws/eks-metrics/modules/outputs.tf`

aws/karpenter/ pattern を踏襲、retention 90 日、bucket 名 `thanos-<account-id>`、SA 名 `prometheus`。

- [ ] **Step 1: ディレクトリ作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
mkdir -p aws/eks-metrics/envs/production aws/eks-metrics/modules
```

- [ ] **Step 2: Makefile 作成**

`aws/eks-metrics/Makefile` を以下で作成:

```makefile
# Makefile for EKS Metrics (Thanos S3 + Pod Identity)

# Default values
ENV ?= production

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help init plan apply destroy validate fmt check clean

help: ## Show this help message
	@echo "EKS Metrics - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments:"
	@echo "  - production"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=production"
	@echo "  make apply ENV=production"

init: ## Initialize Terragrunt
	@printf "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@printf "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@printf "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@printf "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)\n"
	@printf "$(RED)WARNING: This will destroy all resources!$(NC)\n"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		printf "$(YELLOW)Cancelled.$(NC)\n"; \
	fi

validate: ## Validate Terragrunt configuration
	@printf "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@printf "$(YELLOW)Formatting Terraform files...$(NC)\n"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@printf "$(GREEN)All checks completed for $(ENV)$(NC)\n"

clean: ## Clean Terragrunt cache
	@printf "$(YELLOW)Cleaning Terragrunt cache...$(NC)\n"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@printf "$(YELLOW)Showing current state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@printf "$(YELLOW)Showing outputs for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@printf "$(YELLOW)Refreshing state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt refresh
```

- [ ] **Step 3: root.hcl 作成**

`aws/eks-metrics/root.hcl` を以下で作成:

```hcl
# root.hcl - Root Terragrunt configuration for EKS Metrics
# This file contains common settings shared across all environments

locals {
  project_name = "eks-metrics"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks-metrics"
    Team        = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "platform/eks-metrics/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  environment = local.environment
  common_tags = local.common_tags
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 4: envs/production/env.hcl 作成**

`aws/eks-metrics/envs/production/env.hcl` を以下で作成:

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks-metrics"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 5: envs/production/terragrunt.hcl 作成**

`aws/eks-metrics/envs/production/terragrunt.hcl` を以下で作成:

```hcl
# terragrunt.hcl - Terragrunt configuration for production environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//eks-metrics/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-metrics"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 6: modules/terraform.tf 作成**

`aws/eks-metrics/modules/terraform.tf` を以下で作成:

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

- [ ] **Step 7: modules/variables.tf 作成**

`aws/eks-metrics/modules/variables.tf` を以下で作成:

```hcl
# variables.tf - Inputs for the eks-metrics module

variable "environment" {
  description = "Environment name (e.g., production). Used as bucket path prefix for env isolation."
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
```

- [ ] **Step 8: modules/lookups.tf 作成**

`aws/eks-metrics/modules/lookups.tf` を以下で作成:

```hcl
# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

- [ ] **Step 9: modules/main.tf 作成 (S3 bucket + IAM + Pod Identity)**

`aws/eks-metrics/modules/main.tf` を以下で作成:

```hcl
# main.tf - EKS Metrics AWS-side infrastructure (S3 backend for Thanos sidecar).
#
# Provides:
# 1. S3 bucket `thanos-<account-id>` for long-term Prometheus metrics storage
#    (Thanos sidecar が write、Thanos compactor が read で compaction)。
#    - Lifecycle: 90 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:prometheus`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Thanos compaction で必要)
# 3. Pod Identity Association binding `monitoring:prometheus` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う:
# - production: s3://thanos-<account-id>/production/...
# - 将来 staging を同 account で構築する場合: 別 IAM role + 別 Pod Identity Association を staging path 用に追加
#
# Sub-project 2 (kube-prometheus-stack chart 導入) は本 stack の outputs
# (bucket_name / bucket_path_prefix / pod_identity_role_name) を terragrunt output
# 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "thanos-${data.aws_caller_identity.current.account_id}"
  service_name   = "prometheus" # K8s ServiceAccount name (override of chart default)
  retention_days = 90           # Thanos long-term metrics retention
}

# S3 bucket for Thanos long-term metrics storage
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

  # Public access block: 4 settings all true (production standard, Decision 6)
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # SSE-S3 (AES256) by default (Decision 5)
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  # Versioning Disabled (Decision 7, immutable write pattern)
  versioning = {
    status = "Disabled"
  }

  # Lifecycle: env path filter + retention (Decision 4)
  lifecycle_rule = [
    {
      id     = "${var.environment}-retention"
      status = "Enabled"
      filter = {
        prefix = "${var.environment}/"
      }
      expiration = {
        days = local.retention_days
      }
    }
  ]

  tags = var.common_tags
}

# IAM role for Pod Identity Association (Decision 10)
# Trust policy: pods.eks.amazonaws.com service principal で AssumeRole + TagSession
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-${local.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# IAM policy for S3 access (Decision 11, production env path scoped)
# Bucket-level: ListBucket + GetBucketLocation with s3:prefix condition for env scope
# Object-level: Get / Put / Delete on env path only
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = "${var.environment}/*"
          }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        Sid    = "ObjectLevelOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
        ]
        Resource = "arn:aws:s3:::${local.bucket_name}/${var.environment}/*"
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role (Decision 10)
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
```

- [ ] **Step 10: modules/outputs.tf 作成**

`aws/eks-metrics/modules/outputs.tf` を以下で作成:

```hcl
# outputs.tf - Outputs for the eks-metrics module.

output "bucket_name" {
  description = "S3 bucket name for Thanos long-term metrics storage. Referenced by Sub-project 2 helmfile values (kube-prometheus-stack thanos.objstoreConfig)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Thanos object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:prometheus SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:prometheus SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
```

- [ ] **Step 11: terragrunt init + validate + plan で diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra/aws/eks-metrics/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected:
- `init`: provider download / module fetch (terraform-aws-modules/s3-bucket v5.6.0 + aws/eks/lookup) で `success`
- `validate`: `Success! The configuration is valid.`
- `plan` summary: `Plan: ~10 to add, 0 to change, 0 to destroy.` (S3 bucket 関連 ~7 + IAM role + IAM policy + Pod Identity Association = 約 10 resources)

⚠️ もし plan が `module.eks` 等の既存 stack に対する change/destroy を含む場合は **STOP**。本 task の scope 外の変更が混入している。

- [ ] **Step 12: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
git add aws/eks-metrics/
git commit -s -m "feat(aws/eks-metrics): add S3 bucket + Pod Identity for Thanos metrics backend

Phase 3 Sub-project 1 の最初の stack。Prometheus + Thanos sidecar 用の
S3 backend を provisioning する。

- S3 bucket: thanos-<account-id> (account-id で globally unique、env なし)
- env 分離: bucket 内 prefix \${var.environment}/ で
- Lifecycle: production path filter で 90 日 expiration
- Encryption: SSE-S3 (AES256)
- Public access block: 4 settings true
- Versioning: Disabled
- Pod Identity Association: monitoring:prometheus SA → IAM role
- IAM permission: \${env}/* path に Get/Put/Delete、ListBucket は s3:prefix
  condition で env-scoped

aws/eks/lookup から cluster name を取得 (Plan 2 で確立した cross-stack
lookup pattern)。

Sub-project 2 (kube-prometheus-stack 導入) は terragrunt output 経由で
bucket_name / bucket_path_prefix / pod_identity_role_name を取得して
helmfile values に渡す。"
```

---

## Task 2: aws/eks-logs/ stack 新規作成 (Loki S3 + Pod Identity for loki SA)

**Files:**
- Create: `aws/eks-logs/Makefile`
- Create: `aws/eks-logs/root.hcl`
- Create: `aws/eks-logs/envs/production/env.hcl`
- Create: `aws/eks-logs/envs/production/terragrunt.hcl`
- Create: `aws/eks-logs/modules/terraform.tf`
- Create: `aws/eks-logs/modules/variables.tf`
- Create: `aws/eks-logs/modules/lookups.tf`
- Create: `aws/eks-logs/modules/main.tf`
- Create: `aws/eks-logs/modules/outputs.tf`

aws/eks-metrics/ と同型、retention 30 日、bucket 名 `loki-<account-id>`、SA 名 `loki`。

- [ ] **Step 1: ディレクトリ作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
mkdir -p aws/eks-logs/envs/production aws/eks-logs/modules
```

- [ ] **Step 2: Makefile 作成**

`aws/eks-logs/Makefile` を以下で作成 (1 行目 `# Makefile for EKS Logs (Loki S3 + Pod Identity)` + 16 行目 `@echo "EKS Logs - Terragrunt Commands"` の差分以外は eks-metrics と同型):

```makefile
# Makefile for EKS Logs (Loki S3 + Pod Identity)

# Default values
ENV ?= production

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help init plan apply destroy validate fmt check clean

help: ## Show this help message
	@echo "EKS Logs - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments:"
	@echo "  - production"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=production"
	@echo "  make apply ENV=production"

init: ## Initialize Terragrunt
	@printf "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@printf "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@printf "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@printf "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)\n"
	@printf "$(RED)WARNING: This will destroy all resources!$(NC)\n"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		printf "$(YELLOW)Cancelled.$(NC)\n"; \
	fi

validate: ## Validate Terragrunt configuration
	@printf "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@printf "$(YELLOW)Formatting Terraform files...$(NC)\n"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@printf "$(GREEN)All checks completed for $(ENV)$(NC)\n"

clean: ## Clean Terragrunt cache
	@printf "$(YELLOW)Cleaning Terragrunt cache...$(NC)\n"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@printf "$(YELLOW)Showing current state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@printf "$(YELLOW)Showing outputs for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@printf "$(YELLOW)Refreshing state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt refresh
```

- [ ] **Step 3: root.hcl 作成**

`aws/eks-logs/root.hcl` を以下で作成 (project_name / state key / Component が `eks-logs` に変更):

```hcl
# root.hcl - Root Terragrunt configuration for EKS Logs
# This file contains common settings shared across all environments

locals {
  project_name = "eks-logs"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks-logs"
    Team        = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "platform/eks-logs/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  environment = local.environment
  common_tags = local.common_tags
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 4: envs/production/env.hcl 作成**

`aws/eks-logs/envs/production/env.hcl` を以下で作成 (Purpose が `eks-logs`):

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks-logs"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 5: envs/production/terragrunt.hcl 作成**

`aws/eks-logs/envs/production/terragrunt.hcl` を以下で作成 (terraform source / Project が `eks-logs`):

```hcl
# terragrunt.hcl - Terragrunt configuration for production environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//eks-logs/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-logs"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 6: modules/terraform.tf 作成**

`aws/eks-logs/modules/terraform.tf` を以下で作成 (eks-metrics と同型):

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

- [ ] **Step 7: modules/variables.tf 作成**

`aws/eks-logs/modules/variables.tf` を以下で作成 (description "eks-logs module" に変更、それ以外 eks-metrics と同型):

```hcl
# variables.tf - Inputs for the eks-logs module

variable "environment" {
  description = "Environment name (e.g., production). Used as bucket path prefix for env isolation."
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
```

- [ ] **Step 8: modules/lookups.tf 作成**

`aws/eks-logs/modules/lookups.tf` を以下で作成 (eks-metrics と同型):

```hcl
# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

- [ ] **Step 9: modules/main.tf 作成 (S3 + IAM + Pod Identity)**

`aws/eks-logs/modules/main.tf` を以下で作成 (eks-metrics 構造と同型、bucket 名 `loki-<account-id>` / SA `loki` / retention 30 日 に変更):

```hcl
# main.tf - EKS Logs AWS-side infrastructure (S3 backend for Loki).
#
# Provides:
# 1. S3 bucket `loki-<account-id>` for Loki log chunks long-term storage
#    (Loki distributor / ingester が write、Loki querier が read)。
#    - Lifecycle: 30 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:loki`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Loki block deletion で必要)
# 3. Pod Identity Association binding `monitoring:loki` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う。
# Sub-project 3 (Loki chart 導入) は本 stack の outputs を terragrunt output
# 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "loki-${data.aws_caller_identity.current.account_id}"
  service_name   = "loki" # K8s ServiceAccount name
  retention_days = 30     # Loki log chunks retention
}

# S3 bucket for Loki log chunks
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning = {
    status = "Disabled"
  }

  lifecycle_rule = [
    {
      id     = "${var.environment}-retention"
      status = "Enabled"
      filter = {
        prefix = "${var.environment}/"
      }
      expiration = {
        days = local.retention_days
      }
    }
  ]

  tags = var.common_tags
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-${local.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# IAM policy for S3 access (production env path scoped)
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = "${var.environment}/*"
          }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        Sid    = "ObjectLevelOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
        ]
        Resource = "arn:aws:s3:::${local.bucket_name}/${var.environment}/*"
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
```

- [ ] **Step 10: modules/outputs.tf 作成**

`aws/eks-logs/modules/outputs.tf` を以下で作成 (description "Loki" に変更、構造は eks-metrics と同型):

```hcl
# outputs.tf - Outputs for the eks-logs module.

output "bucket_name" {
  description = "S3 bucket name for Loki log chunks. Referenced by Sub-project 3 helmfile values (loki chart storage_config.aws.s3)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Loki object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:loki SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:loki SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
```

- [ ] **Step 11: terragrunt init + validate + plan で diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra/aws/eks-logs/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected:
- `init`: success
- `validate`: `Success! The configuration is valid.`
- `plan` summary: `Plan: ~10 to add, 0 to change, 0 to destroy.` (eks-metrics と同型)

⚠️ もし `module.eks` 等の既存 stack に対する change/destroy を含む場合は **STOP**。

- [ ] **Step 12: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
git add aws/eks-logs/
git commit -s -m "feat(aws/eks-logs): add S3 bucket + Pod Identity for Loki log backend

Phase 3 Sub-project 1 の 2 番目の stack。Loki chart 用の S3 backend を
provisioning する。

- S3 bucket: loki-<account-id>
- env 分離: bucket 内 prefix \${var.environment}/
- Lifecycle: production path filter で 30 日 expiration
- Encryption: SSE-S3 (AES256)
- Public access block: 4 settings true
- Versioning: Disabled
- Pod Identity Association: monitoring:loki SA → IAM role

aws/eks-metrics/ と同型 (boilerplate 共通)、retention と SA 名のみ差分。
Sub-project 3 (Loki chart 導入) で本 stack の outputs を helmfile に
渡す。"
```

---

## Task 3: aws/eks-traces/ stack 新規作成 (Tempo S3 + Pod Identity for tempo SA)

**Files:**
- Create: `aws/eks-traces/Makefile`
- Create: `aws/eks-traces/root.hcl`
- Create: `aws/eks-traces/envs/production/env.hcl`
- Create: `aws/eks-traces/envs/production/terragrunt.hcl`
- Create: `aws/eks-traces/modules/terraform.tf`
- Create: `aws/eks-traces/modules/variables.tf`
- Create: `aws/eks-traces/modules/lookups.tf`
- Create: `aws/eks-traces/modules/main.tf`
- Create: `aws/eks-traces/modules/outputs.tf`

aws/eks-metrics/ と同型、retention 7 日、bucket 名 `tempo-<account-id>`、SA 名 `tempo`。

- [ ] **Step 1: ディレクトリ作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
mkdir -p aws/eks-traces/envs/production aws/eks-traces/modules
```

- [ ] **Step 2: Makefile 作成**

`aws/eks-traces/Makefile` を以下で作成 (1 行目 + help text の "EKS Traces" 表記以外は eks-metrics と同型):

```makefile
# Makefile for EKS Traces (Tempo S3 + Pod Identity)

# Default values
ENV ?= production

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help init plan apply destroy validate fmt check clean

help: ## Show this help message
	@echo "EKS Traces - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments:"
	@echo "  - production"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=production"
	@echo "  make apply ENV=production"

init: ## Initialize Terragrunt
	@printf "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@printf "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@printf "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@printf "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)\n"
	@printf "$(RED)WARNING: This will destroy all resources!$(NC)\n"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		printf "$(YELLOW)Cancelled.$(NC)\n"; \
	fi

validate: ## Validate Terragrunt configuration
	@printf "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@printf "$(YELLOW)Formatting Terraform files...$(NC)\n"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@printf "$(GREEN)All checks completed for $(ENV)$(NC)\n"

clean: ## Clean Terragrunt cache
	@printf "$(YELLOW)Cleaning Terragrunt cache...$(NC)\n"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@printf "$(YELLOW)Showing current state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@printf "$(YELLOW)Showing outputs for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@printf "$(YELLOW)Refreshing state for $(ENV)...$(NC)\n"
	cd envs/$(ENV) && terragrunt refresh
```

- [ ] **Step 3: root.hcl 作成**

`aws/eks-traces/root.hcl` を以下で作成 (project_name / state key / Component が `eks-traces` に変更):

```hcl
# root.hcl - Root Terragrunt configuration for EKS Traces
# This file contains common settings shared across all environments

locals {
  project_name = "eks-traces"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks-traces"
    Team        = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "platform/eks-traces/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  environment = local.environment
  common_tags = local.common_tags
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 4: envs/production/env.hcl 作成**

`aws/eks-traces/envs/production/env.hcl` を以下で作成 (Purpose `eks-traces`):

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks-traces"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 5: envs/production/terragrunt.hcl 作成**

`aws/eks-traces/envs/production/terragrunt.hcl` を以下で作成 (terraform source / Project が `eks-traces`):

```hcl
# terragrunt.hcl - Terragrunt configuration for production environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//eks-traces/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-traces"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 6: modules/terraform.tf 作成**

`aws/eks-traces/modules/terraform.tf` を以下で作成 (eks-metrics と同型):

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

- [ ] **Step 7: modules/variables.tf 作成**

`aws/eks-traces/modules/variables.tf` を以下で作成 (description "eks-traces module" に変更、それ以外 eks-metrics と同型):

```hcl
# variables.tf - Inputs for the eks-traces module

variable "environment" {
  description = "Environment name (e.g., production). Used as bucket path prefix for env isolation."
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
```

- [ ] **Step 8: modules/lookups.tf 作成**

`aws/eks-traces/modules/lookups.tf` を以下で作成 (eks-metrics と同型):

```hcl
# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

- [ ] **Step 9: modules/main.tf 作成 (S3 + IAM + Pod Identity)**

`aws/eks-traces/modules/main.tf` を以下で作成 (eks-metrics 構造と同型、bucket 名 `tempo-<account-id>` / SA `tempo` / retention 7 日 に変更):

```hcl
# main.tf - EKS Traces AWS-side infrastructure (S3 backend for Tempo).
#
# Provides:
# 1. S3 bucket `tempo-<account-id>` for Tempo trace data storage
#    (Tempo distributor / ingester が write、Tempo querier が read)。
#    - Lifecycle: 7 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:tempo`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Tempo block deletion で必要)
# 3. Pod Identity Association binding `monitoring:tempo` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う。
# Sub-project 4 (Tempo + OpenTelemetry chart 導入) は本 stack の outputs を
# terragrunt output 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "tempo-${data.aws_caller_identity.current.account_id}"
  service_name   = "tempo" # K8s ServiceAccount name
  retention_days = 7       # Tempo trace data retention (high-volume, short retention)
}

# S3 bucket for Tempo trace data
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning = {
    status = "Disabled"
  }

  lifecycle_rule = [
    {
      id     = "${var.environment}-retention"
      status = "Enabled"
      filter = {
        prefix = "${var.environment}/"
      }
      expiration = {
        days = local.retention_days
      }
    }
  ]

  tags = var.common_tags
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-${local.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# IAM policy for S3 access (production env path scoped)
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = "${var.environment}/*"
          }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        Sid    = "ObjectLevelOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
        ]
        Resource = "arn:aws:s3:::${local.bucket_name}/${var.environment}/*"
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
```

- [ ] **Step 10: modules/outputs.tf 作成**

`aws/eks-traces/modules/outputs.tf` を以下で作成 (description "Tempo" に変更、構造は eks-metrics と同型):

```hcl
# outputs.tf - Outputs for the eks-traces module.

output "bucket_name" {
  description = "S3 bucket name for Tempo trace data. Referenced by Sub-project 4 helmfile values (tempo chart storage.trace.s3)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Tempo object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:tempo SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:tempo SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
```

- [ ] **Step 11: terragrunt init + validate + plan で diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra/aws/eks-traces/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan
```

Expected:
- `init`: success
- `validate`: `Success! The configuration is valid.`
- `plan` summary: `Plan: ~10 to add, 0 to change, 0 to destroy.`

⚠️ もし `module.eks` 等の既存 stack に対する change/destroy を含む場合は **STOP**。

- [ ] **Step 12: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
git add aws/eks-traces/
git commit -s -m "feat(aws/eks-traces): add S3 bucket + Pod Identity for Tempo trace backend

Phase 3 Sub-project 1 の 3 番目の stack。Tempo chart 用の S3 backend を
provisioning する。

- S3 bucket: tempo-<account-id>
- env 分離: bucket 内 prefix \${var.environment}/
- Lifecycle: production path filter で 7 日 expiration
  (high-volume traces なので短期 retention)
- Encryption: SSE-S3 (AES256)
- Public access block: 4 settings true
- Versioning: Disabled
- Pod Identity Association: monitoring:tempo SA → IAM role

aws/eks-metrics/ と同型 (boilerplate 共通)、retention と SA 名のみ差分。
Sub-project 4 (OpenTelemetry + Tempo chart 導入) で本 stack の outputs を
helmfile に渡す。"
```

---

## Task 4: PR push + Draft PR 作成

**Files:** (no file changes、git remote operation)

3 stack の commits を origin に push して Draft PR を作成。

- [ ] **Step 1: branch 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-aws-infra
git status
git log --oneline origin/main..HEAD
```

Expected:
- working tree clean
- 4 commits ahead: spec + 3 stack creation commits

- [ ] **Step 2: branch を push**

```bash
git push -u origin HEAD
```

Expected: `feat/eks-production-observability-aws-infra` branch が origin に作成される。

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --title "feat(eks): Phase 3 Sub-project 1 — Observability AWS infra (S3 × 3 + Pod Identity × 3)" --body "$(cat <<'EOF'
## Summary

Roadmap Phase 3 (Observability) を 4 sub-projects に分解した最初の sub-project。観測スタック (Prometheus + Thanos / Loki / Tempo) 用の AWS-side infra を 3 つの independent terragrunt stack で provisioning する。

### Stack 構成

| Stack | bucket | retention | Pod Identity SA |
|---|---|---|---|
| `aws/eks-metrics/` | `thanos-559744160976` | 90 日 | `monitoring:prometheus` |
| `aws/eks-logs/` | `loki-559744160976` | 30 日 | `monitoring:loki` |
| `aws/eks-traces/` | `tempo-559744160976` | 7 日 | `monitoring:tempo` |

### 設計のキーポイント

- **data-type 中立な stack 命名** (`aws/eks-{metrics,logs,traces}/`) で将来 managed service 移行 (AMP / CloudWatch Logs / X-Ray) でも stack 名そのまま再利用可能
- **bucket 命名 `<component>-<account-id>`** で env 識別子なし、env 分離は bucket 内 prefix `${env}/` で実現 (同 account で staging 共存可能、別 account 移行時は bucket migration で対応)
- **Pod Identity Association** (Plan 2 `aws/karpenter/` で確立) を採用、IRSA は使わない
- **IAM permission 最小化**: production env path のみ access、ListBucket は `s3:prefix` condition で env-scoped
- **K8s cluster 側は無変化**: 本 PR は AWS-side only。`monitoring` namespace + 各 SA は Sub-project 2-4 (chart install) で初めて作成

## Code 変更 (本 PR)

- `aws/eks-metrics/` 新規作成 (Makefile + root.hcl + envs/production/{env.hcl,terragrunt.hcl} + modules/{terraform.tf,variables.tf,lookups.tf,main.tf,outputs.tf})
- `aws/eks-logs/` 同型 (retention 30 日 / bucket loki-* / SA loki)
- `aws/eks-traces/` 同型 (retention 7 日 / bucket tempo-* / SA tempo)
- `docs/superpowers/specs/2026-05-05-eks-production-observability-aws-infra-design.md` 新規
- `docs/superpowers/plans/2026-05-05-eks-production-observability-aws-infra.md` 新規

## Documents

- Spec: `docs/superpowers/specs/2026-05-05-eks-production-observability-aws-infra-design.md`
- Plan: `docs/superpowers/plans/2026-05-05-eks-production-observability-aws-infra.md`
- Roadmap reference: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md` Phase 3

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] aws/eks-metrics: `terragrunt validate` 成功
- [x] aws/eks-metrics: `terragrunt plan` が `Plan: ~10 to add, 0 to change, 0 to destroy` で `module.eks` 等の既存 stack に影響なし
- [x] aws/eks-logs: 同上
- [x] aws/eks-traces: 同上

### Cluster-level (CI / operator 実行、merge 後)

- [ ] CI Deploy job で 3 stack (`aws/eks-metrics`, `aws/eks-logs`, `aws/eks-traces`) の terragrunt apply が success
- [ ] `aws s3 ls` で 3 bucket (`thanos-559744160976`, `loki-559744160976`, `tempo-559744160976`) 確認
- [ ] `aws s3api get-bucket-encryption --bucket <bucket>` で SSE-S3 (AES256) 確認 (3 bucket)
- [ ] `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>` で env path 別 retention 確認 (Thanos 90 / Loki 30 / Tempo 7)
- [ ] `aws s3api get-public-access-block --bucket <bucket>` で 4 setting すべて true (3 bucket)
- [ ] `aws iam list-roles` で 3 IAM role (`eks-production-prometheus`, `eks-production-loki`, `eks-production-tempo`) 確認
- [ ] `aws eks list-pod-identity-associations --cluster-name eks-production` で 3 association (`monitoring:prometheus`, `monitoring:loki`, `monitoring:tempo`) 確認
- [ ] `kubectl get namespace monitoring` で **NotFound** (本 PR は AWS-side only、cluster 無変化)
- [ ] 各 stack の `terragrunt output` で `bucket_name` / `bucket_path_prefix` / `pod_identity_role_name` 取得可能
EOF
)"
```

Expected: PR が created、URL が表示される (例: `https://github.com/panicboat/platform/pull/<n>`)。

- [ ] **Step 4: CI ステータス確認**

```bash
gh run list --branch feat/eks-production-observability-aws-infra --limit 5
```

Expected: `Lint GitHub Actions` workflow が success で完了。`Auto Label - Label Resolver` workflow も success。

---

## (USER) PR review + merge → Verification

**Files:** (cluster 状態変更 — AWS-side のみ、K8s 側変化なし)

PR を merge して CI Deploy が apply 実行。3 stack 並列で provision される。

- [ ] **Step 1: PR を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: CI Deploy workflow (`Hydrate Kubernetes` 等は無関係、本 PR は terragrunt apply のみ) が success。3 stack 並列で apply 実行 (= 3 つの terragrunt apply runner)。

- [ ] **Step 2: 3 bucket 作成確認**

```bash
aws s3 ls --region ap-northeast-1 | grep -E "thanos-|loki-|tempo-"
```

Expected:
```
20XX-XX-XX XX:XX:XX thanos-559744160976
20XX-XX-XX XX:XX:XX loki-559744160976
20XX-XX-XX XX:XX:XX tempo-559744160976
```

- [ ] **Step 3: bucket settings 確認 (3 bucket すべて)**

```bash
for BUCKET in thanos-559744160976 loki-559744160976 tempo-559744160976; do
  echo "=== $BUCKET ==="
  echo "--- encryption ---"
  aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
  echo "--- public access block ---"
  aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration' --output json
  echo "--- versioning ---"
  aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text
  echo "--- lifecycle ---"
  aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'Rules[].{ID:ID,Status:Status,Prefix:Filter.Prefix,Days:Expiration.Days}' --output table
done
```

Expected (3 bucket すべて):
- encryption: `AES256`
- public access block: 4 setting すべて `true`
- versioning: 空 or `None` (Disabled の表現)
- lifecycle: filter `prefix: production/` で `Status: Enabled`、retention は thanos=90 / loki=30 / tempo=7

- [ ] **Step 4: 3 IAM role 確認**

```bash
aws iam list-roles --query 'Roles[?Tags && @ != `null` && (contains(@.Tags[?Key==`Component`].Value, `eks-metrics`) || contains(@.Tags[?Key==`Component`].Value, `eks-logs`) || contains(@.Tags[?Key==`Component`].Value, `eks-traces`))].RoleName' --output text 2>&1 || \
  aws iam list-roles --query 'Roles[?starts_with(RoleName, `eks-production-prometheus`) || starts_with(RoleName, `eks-production-loki`) || starts_with(RoleName, `eks-production-tempo`)].RoleName' --output text
```

Expected: `eks-production-prometheus`, `eks-production-loki`, `eks-production-tempo` の 3 つ。

- [ ] **Step 5: 3 Pod Identity Association 確認**

```bash
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 \
  --query 'associations[?namespace==`monitoring`].{ns:namespace,sa:serviceAccount,role:roleArn}' --output table
```

Expected: 3 行 (`monitoring:prometheus`, `monitoring:loki`, `monitoring:tempo`) が table 表示、各 roleArn が前 step の IAM role に対応。

- [ ] **Step 6: K8s cluster 無変化確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get namespace monitoring 2>&1 || echo "expected: NotFound"
kubectl get pods -A | grep -E "prometheus|loki|tempo" || echo "expected: no pods"
```

Expected:
- `monitoring` namespace は **NotFound** (Sub-project 2 で chart install 時に作成)
- prometheus / loki / tempo 系 pod は **存在しない** (chart 未 install)

これにより本 PR が AWS-side のみで cluster 無影響であることを実証。

- [ ] **Step 7: terragrunt outputs 取得確認 (Sub-project 2-4 readiness)**

```bash
for STACK in eks-metrics eks-logs eks-traces; do
  echo "=== aws/$STACK ==="
  cd /Users/takanokenichi/GitHub/panicboat/platform/aws/$STACK/envs/production
  TG_TF_PATH=tofu terragrunt output -json | jq '{bucket_name, bucket_path_prefix, pod_identity_role_name}'
done
```

Expected:
- `aws/eks-metrics`: `{bucket_name: "thanos-559744160976", bucket_path_prefix: "production", pod_identity_role_name: "eks-production-prometheus"}`
- `aws/eks-logs`: 同型 with loki
- `aws/eks-traces`: 同型 with tempo

これらが Sub-project 2-4 で helmfile values に渡される。

---

## Self-review checklist

> Plan 完成後の self-review。Implementer が任意 task を実行する前に、Plan 自体の整合性を確認する。

### Spec coverage

Spec の各セクションが Plan 内のどの task で実装されているか:

- [x] **Goals G1 (3 stack provisioning)** → Tasks 1, 2, 3 (各 stack の S3 + IAM + Pod Identity)
- [x] **Goals G2 (Pod Identity Association、production env path scope)** → Tasks 1, 2, 3 Step 9 の `aws_iam_role_policy.s3_access` + `aws_eks_pod_identity_association.this`
- [x] **Goals G3 (data-type 中立 stack 命名)** → Tasks 1, 2, 3 が `aws/eks-{metrics,logs,traces}/` を採用
- [x] **Goals G4 (env 分離 path prefix)** → Tasks 1, 2, 3 Step 9 の `bucket_name = "<component>-${account-id}"` + `lifecycle_rule.filter.prefix = "${var.environment}/"` + `IAM Resource = "...${var.environment}/*"`
- [x] **Decision 1 (3 stack 構成)** → Tasks 1, 2, 3 で 3 stack 独立に作成
- [x] **Decision 2 (bucket 命名)** → Tasks 1, 2, 3 Step 9 の `local.bucket_name = "<component>-${data.aws_caller_identity.current.account_id}"`
- [x] **Decision 3 (env 分離は bucket prefix)** → Tasks 1, 2, 3 Step 9 lifecycle filter + IAM Resource scope
- [x] **Decision 4 (Lifecycle retention)** → Tasks 1 (90d) / 2 (30d) / 3 (7d) Step 9 `local.retention_days`
- [x] **Decision 5 (SSE-S3)** → Tasks 1, 2, 3 Step 9 `server_side_encryption_configuration.rule.apply_server_side_encryption_by_default.sse_algorithm = "AES256"`
- [x] **Decision 6 (Public access block 4 true)** → Tasks 1, 2, 3 Step 9 `block_public_acls/block_public_policy/ignore_public_acls/restrict_public_buckets = true`
- [x] **Decision 7 (Versioning Disabled)** → Tasks 1, 2, 3 Step 9 `versioning = { status = "Disabled" }`
- [x] **Decision 8 (namespace=monitoring)** → Tasks 1, 2, 3 Step 9 `aws_eks_pod_identity_association.this.namespace = "monitoring"`
- [x] **Decision 9 (SA 短縮名)** → Tasks 1 (`prometheus`) / 2 (`loki`) / 3 (`tempo`) Step 9 `local.service_name`
- [x] **Decision 10 (Pod Identity)** → Tasks 1, 2, 3 Step 9 `aws_eks_pod_identity_association.this`
- [x] **Decision 11 (IAM permission scope production env path)** → Tasks 1, 2, 3 Step 9 `aws_iam_role_policy.s3_access` の `Condition.StringLike.s3:prefix` + `Resource` scope
- [x] **Decision 12 (cross-stack lookup)** → Tasks 1, 2, 3 Step 8 `module "eks" { source = "../../eks/lookup" }`
- [x] **Components matrix の各 stack** → Tasks 1, 2, 3 で 11 ファイル × 3 stack 作成
- [x] **Cross-stack value flow (terragrunt outputs)** → Tasks 1, 2, 3 Step 10 `outputs.tf` で bucket_name / bucket_path_prefix / pod_identity_role_name / pod_identity_role_arn
- [x] **Migration sequence (3 stack 順次/並列 apply)** → Task 4 Step 3 で 1 PR に 3 stack 含めて CI Deploy で並列 apply
- [x] **Verification checklist** → (USER) Step 2-7 で 7-step verification (3 bucket / settings / IAM role / Pod Identity / cluster 無変化 / outputs)
- [x] **Trade-offs (boilerplate 増 / monitoring 集約 / env 識別子なし / DeleteObject 含む)** → 各 Decision の判断根拠で言及済 + Spec で詳細

### Placeholder scan

- [x] **`TBD` / `TODO` / `implement later` / `fill in details` 等の禁止文言**: なし
- [x] **`<account-id>` placeholder**: spec 上では `<account-id>` と書いていたが、本 plan では `data.aws_caller_identity.current.account_id` で動的取得 + Task 4 PR description で実値 `559744160976` を使う。Verification step (Step 2 / 3) も実値 `559744160976` で記述
- [x] **`<bucket>` placeholder**: 各 Verification step で実値 (`thanos-559744160976` 等) で記述
- [x] **`<n>` (PR number)**: Task 4 Step 3 の `gh pr create` の output で確定する placeholder で受容範囲

### Type / signature consistency

- [x] **HCL local 名** (`local.bucket_name` / `local.service_name` / `local.retention_days`): Tasks 1, 2, 3 で同名で定義、retention 値のみ差分
- [x] **HCL resource 名**: `module.s3` / `aws_iam_role.pod_identity` / `aws_iam_role_policy.s3_access` / `aws_eks_pod_identity_association.this` の 4 個が Tasks 1, 2, 3 で一貫
- [x] **terragrunt output 名** (`bucket_name` / `bucket_path_prefix` / `pod_identity_role_name` / `pod_identity_role_arn`): Tasks 1, 2, 3 で 4 outputs 同名
- [x] **K8s namespace + SA**: namespace=`monitoring` (Tasks 1, 2, 3 共通)、SA=`prometheus`/`loki`/`tempo` (Tasks 1/2/3 で差分)
- [x] **IAM role 命名 pattern** (`eks-${var.environment}-${local.service_name}`): Tasks 1, 2, 3 で同形、SA 名のみ差分
- [x] **terragrunt remote state key** (`platform/eks-{metrics,logs,traces}/${local.environment}/terraform.tfstate`): Tasks 1, 2, 3 で stack 名のみ差分
- [x] **terraform-aws-modules/s3-bucket version**: `5.6.0` を Tasks 1, 2, 3 で統一
- [x] **AWS provider version**: `6.43.0` を Tasks 1, 2, 3 で統一 (aws/karpenter/ と consistency)

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) — Tasks 1, 2, 3, 4 の commit step で `-s` 指定
- [x] `Co-Authored-By` 不付与 — 全 task の commit message に無し
- [x] PR は `--draft` — Task 4 Step 3 の `gh pr create --draft`
- [x] 新規ブランチ初回 push: `git push -u origin HEAD` — Task 4 Step 2
- [x] Conventional Commits — 全 commit が `feat(aws/eks-*):` 形式

### Plan 1c-β / Plan 2 / Plan tuning の知見反映

- [x] **Plan 1c-β L1 (IRSA module の random suffix)** → 本 plan は Pod Identity 採用で IRSA は使わない。IAM role は `aws_iam_role` direct resource で fixed name (`eks-${env}-${service}`)、suffix 問題なし
- [x] **Plan 1c-β L2 (.terraform.lock.hcl gitignore)** → 本 plan で git add 対象として言及せず
- [x] **Plan 1c-β L3 (kube-proxy state drift)** → 本 plan は新規 stack なので state drift なし
- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT 不要)** → 本 plan は terragrunt output 取得が Sub-project 2-4 で行われる、本 PR では不要
- [x] **Plan 1c-β L5 (squash merge 後の branch reset rollback)** → Task 0 Step 1 で `git fetch origin main && git log --oneline origin/main..HEAD` 確認
- [x] **Plan 2 L1 (karpenter_bootstrap 命名再考)** → 本 plan は最初から role-explicit な命名 (stack 名 `eks-{metrics,logs,traces}` / SA 名 `prometheus`/`loki`/`tempo`) を採用、後の rename PR 不要
- [x] **Plan 2 L2 (cluster info wiring)** → 本 plan の lookups.tf は `aws/eks/lookup` を使用、cluster info wiring は同 module の output に任せる (本 plan の `module.eks.cluster.name` のみ参照)
- [x] **Plan 2 L3 (inline policy)** → 本 plan は terraform-aws-modules/eks/aws//modules/karpenter を使わない (Karpenter 関連 customer-managed policy size 制約は無関係)、`aws_iam_role_policy` で直接 inline policy を作成 (= 10240 char 上限、本 plan の S3 access policy は短いため問題なし)
- [x] **Plan 2 L4 (consolidationPolicy v1+)** → 本 plan は Karpenter NodePool を扱わない、無関係
- [x] **Plan 2 L5 (node SG 明示 attach)** → 本 plan は MNG を扱わない、無関係
- [x] **Plan 2 L6 (PDB blocker on rolling update)** → 本 plan は cluster 無変化 (chart install しない)、PDB blocker 発生せず
- [x] **Plan 2 L7 (spec/plan divergence)** → 本 plan は spec 通りに書き、divergence 発生時は spec を正とする
- [x] **Plan tuning L1 (IAM name_prefix 38 chars limit)** → 本 plan は `aws_iam_role.name` で fixed name を使い、`name_prefix` 不使用 (= 制約に hit しない)
- [x] **Plan tuning L2 (line-based scope ではなく file-based scope)** → 本 plan は各 task で「ファイル単位」で完結 scope (Step 9 で main.tf を完全置換、line range 指定なし)
- [x] **Plan tuning L3 (PR 中核変更がドキュメント面で閉じる)** → 本 PR の中核 (3 stack) を README に反映する task は Sub-project 2-4 (chart install 時に operational documentation 追加) で扱う、本 sub-project は AWS-side のみで README 反映は時期尚早
- [x] **Plan tuning L4 (K8s NodeSelectorRequirement Ge 不在)** → 本 plan は NodeSelectorRequirement を扱わない、無関係
- [x] **Plan tuning L5 (NodePool drift consolidation)** → 本 plan は NodePool を扱わない、無関係
