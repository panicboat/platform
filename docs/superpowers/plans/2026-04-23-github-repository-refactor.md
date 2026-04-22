# github/repository Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `github/github-repository` を `github/repository`（リポジトリ管理）と `github/branch`（ブランチ保護管理）に分割し、`envs/` を環境単位の単一実行ユニットに再構成する。

**Architecture:** `github/repository` は `github_repository` と `aws_cloudwatch_log_group` を `for_each` で管理する。`github/branch` は `data "github_repository"` でリポジトリの `node_id` を取得し、`github_branch_protection` を独立して管理する。両サービスとも `envs/develop/` を単一実行ユニットとし、リポジトリごとの `.hcl` ファイルを `read_terragrunt_config()` で読み込む。

**Tech Stack:** Terraform >= 1.14.8, Terragrunt, GitHub Provider ~> 6.11, AWS Provider ~> 6.41

---

## File Map

**New files — `github/repository/`:**
- `github/repository/root.hcl` — remote state + common inputs（project_name = "repository"）
- `github/repository/envs/develop/terragrunt.hcl` — 単一実行ユニット、monorepo.hcl/platform.hcl を読み込む
- `github/repository/envs/develop/monorepo.hcl` — monorepo リポジトリ設定
- `github/repository/envs/develop/platform.hcl` — platform リポジトリ設定
- `github/repository/modules/terraform.tf` — AWS + GitHub provider 設定
- `github/repository/modules/variables.tf` — `repositories = map(object({...}))` （branch_protection なし）
- `github/repository/modules/main.tf` — `github_repository` + `aws_cloudwatch_log_group`（for_each）
- `github/repository/modules/outputs.tf` — for_each 対応の outputs
- `github/repository/Makefile` — ENV=develop に更新

**New files — `github/branch/`:**
- `github/branch/root.hcl` — remote state + common inputs（project_name = "branch"）
- `github/branch/envs/develop/terragrunt.hcl` — 単一実行ユニット
- `github/branch/envs/develop/monorepo.hcl` — monorepo ブランチ保護設定
- `github/branch/envs/develop/platform.hcl` — platform ブランチ保護設定
- `github/branch/modules/terraform.tf` — GitHub provider のみ（AWS 不要）
- `github/branch/modules/variables.tf` — `repositories = map(object({ name, branch_protection }))`
- `github/branch/modules/main.tf` — `data "github_repository"` + `github_branch_protection`（for_each）
- `github/branch/modules/outputs.tf`
- `github/branch/Makefile`

**Deleted:**
- `github/github-repository/` — 全ファイル（state 移行完了後）

---

## Task 1: github/repository のファイルを作成する

**Files:**
- Create: `github/repository/root.hcl`
- Create: `github/repository/envs/develop/terragrunt.hcl`
- Create: `github/repository/envs/develop/monorepo.hcl`
- Create: `github/repository/envs/develop/platform.hcl`
- Create: `github/repository/modules/terraform.tf`
- Create: `github/repository/modules/variables.tf`
- Create: `github/repository/modules/main.tf`
- Create: `github/repository/modules/outputs.tf`
- Create: `github/repository/Makefile`

- [ ] **Step 1: ディレクトリを作成する**

```bash
mkdir -p github/repository/envs/develop
mkdir -p github/repository/modules
```

- [ ] **Step 2: `github/repository/root.hcl` を作成する**

```hcl
locals {
  project_name = "repository"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "repository-management"
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
    key            = "platform/repository/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  project_name = local.project_name
  environment  = local.environment
  common_tags  = local.common_tags
  github_org   = "panicboat"
  aws_region   = "ap-northeast-1"
}
```

- [ ] **Step 3: `github/repository/envs/develop/terragrunt.hcl` を作成する**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../modules"
}

locals {
  monorepo = read_terragrunt_config("monorepo.hcl")
  platform = read_terragrunt_config("platform.hcl")
}

inputs = {
  repositories = {
    monorepo = local.monorepo.locals.repository
    platform = local.platform.locals.repository
  }
  github_token = get_env("GITHUB_TOKEN", "")
}
```

- [ ] **Step 4: `github/repository/envs/develop/monorepo.hcl` を作成する**

```hcl
locals {
  repository = {
    name        = "monorepo"
    description = "Monorepo for multiple services and infrastructure configurations"
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

- [ ] **Step 5: `github/repository/envs/develop/platform.hcl` を作成する**

```hcl
locals {
  repository = {
    name        = "platform"
    description = "Platform for multiple services and infrastructure configurations"
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

- [ ] **Step 6: `github/repository/modules/terraform.tf` を作成する**

```hcl
terraform {
  required_version = ">= 1.14.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.41"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
```

- [ ] **Step 7: `github/repository/modules/variables.tf` を作成する**

```hcl
variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
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

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_token" {
  description = "GitHub personal access token"
  type        = string
  sensitive   = true
}

variable "repositories" {
  description = "Map of repository configurations"
  type = map(object({
    name        = string
    description = string
    visibility  = string
    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })
  }))
}

variable "log_retention_days" {
  description = "CloudWatch Log Group log retention period (days)"
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653
    ], var.log_retention_days)
    error_message = "The log retention period must be a valid value in CloudWatch."
  }
}
```

- [ ] **Step 8: `github/repository/modules/main.tf` を作成する**

```hcl
data "aws_caller_identity" "current" {}

resource "github_repository" "repository" {
  for_each = var.repositories

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility

  has_issues   = each.value.features.issues
  has_wiki     = each.value.features.wiki
  has_projects = each.value.features.projects

  vulnerability_alerts = true

  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_update_branch    = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  archived = false
}

resource "aws_cloudwatch_log_group" "github_repository_logs" {
  for_each = var.repositories

  name              = "/github-repository/${each.value.name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.common_tags, {
    LogGroup = "${var.project_name}-${each.value.name}"
    Purpose  = "github-repository-management"
  })
}
```

- [ ] **Step 9: `github/repository/modules/outputs.tf` を作成する**

```hcl
output "repository_ids" {
  description = "GitHub repository IDs"
  value       = { for k, v in github_repository.repository : k => v.repo_id }
}

output "repository_node_ids" {
  description = "GitHub repository node IDs"
  value       = { for k, v in github_repository.repository : k => v.node_id }
}

output "repository_full_names" {
  description = "Full names of the repositories (org/repo)"
  value       = { for k, v in github_repository.repository : k => v.full_name }
}

output "repository_html_urls" {
  description = "URLs to the repositories on GitHub"
  value       = { for k, v in github_repository.repository : k => v.html_url }
}

output "repository_http_clone_urls" {
  description = "URLs for cloning repositories via HTTPS"
  value       = { for k, v in github_repository.repository : k => v.http_clone_url }
}

output "repository_ssh_clone_urls" {
  description = "URLs for cloning repositories via SSH"
  value       = { for k, v in github_repository.repository : k => v.ssh_clone_url }
}

output "cloudwatch_log_group_names" {
  description = "Names of the CloudWatch log groups"
  value       = { for k, v in aws_cloudwatch_log_group.github_repository_logs : k => v.name }
}

output "cloudwatch_log_group_arns" {
  description = "ARNs of the CloudWatch log groups"
  value       = { for k, v in aws_cloudwatch_log_group.github_repository_logs : k => v.arn }
}
```

- [ ] **Step 10: `github/repository/Makefile` を作成する**

```makefile
ENV ?= develop

RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
NC     := \033[0m

.PHONY: help init plan apply destroy validate fmt check clean show output refresh

help:
	@echo "GitHub Repository Management - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments: develop"

init: ## Initialize Terragrunt
	@echo "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@echo "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@echo "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@echo "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)"
	@echo "$(RED)WARNING: This will destroy all resources!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		echo "$(YELLOW)Cancelled.$(NC)"; \
	fi

validate: ## Validate Terragrunt configuration
	@echo "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@echo "$(YELLOW)Formatting Terraform files...$(NC)"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@echo "$(GREEN)All checks completed for $(ENV)$(NC)"

clean: ## Clean Terragrunt cache
	@echo "$(YELLOW)Cleaning Terragrunt cache...$(NC)"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@echo "$(YELLOW)Showing current state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@echo "$(YELLOW)Showing outputs for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@echo "$(YELLOW)Refreshing state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt refresh
```

- [ ] **Step 11: コミットする**

```bash
git add github/repository/
git commit -s -m "feat(github/repository): add new service structure"
```

---

## Task 2: github/repository を validate する

**Files:**
- `github/repository/envs/develop/`

- [ ] **Step 1: init + validate を実行する**

```bash
cd github/repository/envs/develop
export GITHUB_TOKEN=<your-token>
terragrunt init
terragrunt validate
```

期待: `Success! The configuration is valid.`

---

## Task 3: github/branch のファイルを作成する

**Files:**
- Create: `github/branch/root.hcl`
- Create: `github/branch/envs/develop/terragrunt.hcl`
- Create: `github/branch/envs/develop/monorepo.hcl`
- Create: `github/branch/envs/develop/platform.hcl`
- Create: `github/branch/modules/terraform.tf`
- Create: `github/branch/modules/variables.tf`
- Create: `github/branch/modules/main.tf`
- Create: `github/branch/modules/outputs.tf`
- Create: `github/branch/Makefile`

- [ ] **Step 1: ディレクトリを作成する**

```bash
mkdir -p github/branch/envs/develop
mkdir -p github/branch/modules
```

- [ ] **Step 2: `github/branch/root.hcl` を作成する**

```hcl
locals {
  project_name = "branch"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "branch-protection-management"
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
    key            = "platform/branch/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  project_name = local.project_name
  environment  = local.environment
  common_tags  = local.common_tags
  github_org   = "panicboat"
}
```

- [ ] **Step 3: `github/branch/envs/develop/terragrunt.hcl` を作成する**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../modules"
}

locals {
  monorepo = read_terragrunt_config("monorepo.hcl")
  platform = read_terragrunt_config("platform.hcl")
}

inputs = {
  repositories = {
    monorepo = local.monorepo.locals.repository
    platform = local.platform.locals.repository
  }
  github_token = get_env("GITHUB_TOKEN", "")
}
```

- [ ] **Step 4: `github/branch/envs/develop/monorepo.hcl` を作成する**

```hcl
locals {
  repository = {
    name = "monorepo"
    branch_protection = {
      main = {
        pattern                         = null
        required_reviews                = 0
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = false
        restrict_pushes                 = true
        require_last_push_approval      = false
        required_status_checks          = ["CI Gatekeeper"]
        enforce_admins                  = false
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }
    }
  }
}
```

- [ ] **Step 5: `github/branch/envs/develop/platform.hcl` を作成する**

```hcl
locals {
  repository = {
    name = "platform"
    branch_protection = {
      main = {
        pattern                         = null
        required_reviews                = 0
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = false
        restrict_pushes                 = true
        require_last_push_approval      = false
        required_status_checks          = ["CI Gatekeeper"]
        enforce_admins                  = false
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }
    }
  }
}
```

- [ ] **Step 6: `github/branch/modules/terraform.tf` を作成する**

AWS リソースがないため GitHub provider のみ。

```hcl
terraform {
  required_version = ">= 1.14.8"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
```

- [ ] **Step 7: `github/branch/modules/variables.tf` を作成する**

```hcl
variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_token" {
  description = "GitHub personal access token"
  type        = string
  sensitive   = true
}

variable "repositories" {
  description = "Map of branch protection configurations per repository"
  type = map(object({
    name = string
    branch_protection = map(object({
      pattern                         = optional(string)
      required_reviews                = number
      dismiss_stale_reviews           = bool
      require_code_owner_reviews      = bool
      restrict_pushes                 = bool
      require_last_push_approval      = bool
      required_status_checks          = list(string)
      enforce_admins                  = bool
      allow_force_pushes              = bool
      allow_deletions                 = bool
      required_linear_history         = bool
      require_conversation_resolution = bool
      require_signed_commits          = bool
    }))
  }))
}
```

- [ ] **Step 8: `github/branch/modules/main.tf` を作成する**

`pattern` は locals で `branch_key`（例: "main"）にフォールバックさせ、resource では `each.value.pattern` を参照する。

```hcl
data "github_repository" "repo" {
  for_each = var.repositories
  name     = each.value.name
}

locals {
  branch_protection_rules = merge([
    for repo_key, repo in var.repositories : {
      for branch_key, branch in repo.branch_protection :
      "${repo_key}-${branch_key}" => {
        repository_node_id              = data.github_repository.repo[repo_key].node_id
        pattern                         = branch.pattern != null ? branch.pattern : branch_key
        required_reviews                = branch.required_reviews
        dismiss_stale_reviews           = branch.dismiss_stale_reviews
        require_code_owner_reviews      = branch.require_code_owner_reviews
        require_last_push_approval      = branch.require_last_push_approval
        required_status_checks          = branch.required_status_checks
        enforce_admins                  = branch.enforce_admins
        allow_force_pushes              = branch.allow_force_pushes
        allow_deletions                 = branch.allow_deletions
        required_linear_history         = branch.required_linear_history
        require_conversation_resolution = branch.require_conversation_resolution
        require_signed_commits          = branch.require_signed_commits
      }
    }
  ]...)
}

resource "github_branch_protection" "branches" {
  for_each = local.branch_protection_rules

  repository_id = each.value.repository_node_id
  pattern       = each.value.pattern

  required_pull_request_reviews {
    required_approving_review_count = each.value.required_reviews
    dismiss_stale_reviews           = each.value.dismiss_stale_reviews
    require_code_owner_reviews      = each.value.require_code_owner_reviews
    require_last_push_approval      = each.value.require_last_push_approval
  }

  required_status_checks {
    strict   = false
    contexts = each.value.required_status_checks
  }

  enforce_admins                  = each.value.enforce_admins
  allows_force_pushes             = each.value.allow_force_pushes
  allows_deletions                = each.value.allow_deletions
  required_linear_history         = each.value.required_linear_history
  require_conversation_resolution = each.value.require_conversation_resolution
  require_signed_commits          = each.value.require_signed_commits
}
```

- [ ] **Step 9: `github/branch/modules/outputs.tf` を作成する**

```hcl
output "branch_protection_rules" {
  description = "Information about created branch protection rules"
  value = {
    for key, rule in github_branch_protection.branches : key => {
      id      = rule.id
      pattern = rule.pattern
    }
  }
}
```

- [ ] **Step 10: `github/branch/Makefile` を作成する**

```makefile
ENV ?= develop

RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
NC     := \033[0m

.PHONY: help init plan apply destroy validate fmt check clean show output refresh

help:
	@echo "GitHub Branch Protection Management - Terragrunt Commands"
	@echo ""
	@echo "Usage: make <target> [ENV=<environment>]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available environments: develop"

init: ## Initialize Terragrunt
	@echo "$(YELLOW)Initializing Terragrunt for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt init

plan: ## Plan Terragrunt changes
	@echo "$(YELLOW)Planning Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt plan

apply: ## Apply Terragrunt changes
	@echo "$(YELLOW)Applying Terragrunt changes for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt apply -auto-approve

destroy: ## Destroy Terragrunt resources
	@echo "$(RED)Destroying Terragrunt resources for $(ENV)...$(NC)"
	@echo "$(RED)WARNING: This will destroy all resources!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd envs/$(ENV) && terragrunt destroy; \
	else \
		echo "$(YELLOW)Cancelled.$(NC)"; \
	fi

validate: ## Validate Terragrunt configuration
	@echo "$(YELLOW)Validating Terragrunt configuration for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt validate

fmt: ## Format Terraform files
	@echo "$(YELLOW)Formatting Terraform files...$(NC)"
	terraform fmt -recursive .

check: validate fmt ## Run validation and formatting checks
	@echo "$(GREEN)All checks completed for $(ENV)$(NC)"

clean: ## Clean Terragrunt cache
	@echo "$(YELLOW)Cleaning Terragrunt cache...$(NC)"
	find . -type d -name ".terragrunt-cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.tfplan" -delete 2>/dev/null || true

show: ## Show current Terragrunt state
	@echo "$(YELLOW)Showing current state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt show

output: ## Show Terragrunt outputs
	@echo "$(YELLOW)Showing outputs for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt output

refresh: ## Refresh Terragrunt state
	@echo "$(YELLOW)Refreshing state for $(ENV)...$(NC)"
	cd envs/$(ENV) && terragrunt refresh
```

- [ ] **Step 11: コミットする**

```bash
git add github/branch/
git commit -s -m "feat(github/branch): add new service structure"
```

---

## Task 4: github/branch を validate する

**Files:**
- `github/branch/envs/develop/`

- [ ] **Step 1: init + validate を実行する**

```bash
cd github/branch/envs/develop
export GITHUB_TOKEN=<your-token>
terragrunt init
terragrunt validate
```

期待: `Success! The configuration is valid.`

---

## Task 5: github/repository へ state を移行する

**Files:**
- 変更なし（state 操作のみ）

> state を移行する前に新しいサービスの validate が通っていることを確認すること。

- [ ] **Step 1: 既存の state を pull する**

```bash
cd github/github-repository/envs/monorepo
terragrunt state pull > /tmp/monorepo.tfstate

cd ../platform
terragrunt state pull > /tmp/platform.tfstate
```

- [ ] **Step 2: monorepo の github_repository を新 state に移行する**

```bash
terraform state mv \
  -state=/tmp/monorepo.tfstate \
  -state-out=/tmp/repository-develop.tfstate \
  'github_repository.repository' \
  'github_repository.repository["monorepo"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 3: monorepo の aws_cloudwatch_log_group を新 state に移行する**

```bash
terraform state mv \
  -state=/tmp/monorepo.tfstate \
  -state-out=/tmp/repository-develop.tfstate \
  'aws_cloudwatch_log_group.github_repository_logs' \
  'aws_cloudwatch_log_group.github_repository_logs["monorepo"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 4: platform の github_repository を新 state に移行する**

```bash
terraform state mv \
  -state=/tmp/platform.tfstate \
  -state-out=/tmp/repository-develop.tfstate \
  'github_repository.repository' \
  'github_repository.repository["platform"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 5: platform の aws_cloudwatch_log_group を新 state に移行する**

```bash
terraform state mv \
  -state=/tmp/platform.tfstate \
  -state-out=/tmp/repository-develop.tfstate \
  'aws_cloudwatch_log_group.github_repository_logs' \
  'aws_cloudwatch_log_group.github_repository_logs["platform"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 6: 新 state を github/repository にプッシュする**

```bash
cd github/repository/envs/develop
terragrunt state push /tmp/repository-develop.tfstate
```

---

## Task 6: github/branch へ state を移行する

**Files:**
- 変更なし（state 操作のみ）

- [ ] **Step 1: monorepo の github_branch_protection を新 state に移行する**

`/tmp/monorepo.tfstate` は Task 5 Step 2・3 で一部変更済み。`github_branch_protection` はまだ残っている。

```bash
terraform state mv \
  -state=/tmp/monorepo.tfstate \
  -state-out=/tmp/branch-develop.tfstate \
  'github_branch_protection.branches["main"]' \
  'github_branch_protection.branches["monorepo-main"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 2: platform の github_branch_protection を新 state に移行する**

```bash
terraform state mv \
  -state=/tmp/platform.tfstate \
  -state-out=/tmp/branch-develop.tfstate \
  'github_branch_protection.branches["main"]' \
  'github_branch_protection.branches["platform-main"]'
```

期待: `Successfully moved 1 object(s).`

- [ ] **Step 3: 新 state を github/branch にプッシュする**

```bash
cd github/branch/envs/develop
terragrunt state push /tmp/branch-develop.tfstate
```

---

## Task 7: 両サービスで plan を実行して差分ゼロを確認する

**Files:**
- 変更なし

- [ ] **Step 1: github/repository の plan を実行する**

```bash
cd github/repository/envs/develop
terragrunt plan
```

期待: `No changes. Your infrastructure matches the configuration.`

差分が出た場合は state 移行の漏れを確認すること。

- [ ] **Step 2: github/branch の plan を実行する**

```bash
cd github/branch/envs/develop
terragrunt plan
```

期待: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 3: コミットする**

```bash
git commit -s -m "chore: verify state migration for github/repository and github/branch"
```

---

## Task 8: github/github-repository を削除する

**Files:**
- Delete: `github/github-repository/`

> Task 7 で両サービスの plan が差分ゼロであることを確認してから実施すること。

- [ ] **Step 1: 旧ディレクトリを削除する**

```bash
rm -rf github/github-repository
```

- [ ] **Step 2: コミットする**

```bash
git add -A
git commit -s -m "refactor(github): split github-repository into repository and branch services"
```
