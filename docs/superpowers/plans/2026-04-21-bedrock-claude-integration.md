# ai-assistant Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws/claude-code` と `aws/claude-code-action` を `aws/ai-assistant` に統合し、CLI ロールと Actions ロールを1つのモジュールで管理する。

**Architecture:** 単一 Terraform モジュール (`aws/ai-assistant/modules/`) が CLI 用 IAM ロール（`sts:AssumeRole`）と GitHub Actions 用 IAM ロール（`sts:AssumeRoleWithWebIdentity`）の両方を作成する。Bedrock ポリシーは共有して両ロールにアタッチする。Terragrunt 設定は `env.hcl`（共通）・`cli.hcl`（CLI設定）・`actions.hcl`（Actions設定）に分割し、`terragrunt.hcl` で結合する。

**Tech Stack:** Terraform, Terragrunt, AWS IAM, AWS Bedrock

---

## File Map

| ファイル | 操作 | 内容 |
|---------|------|------|
| `aws/ai-assistant/modules/variables.tf` | 新規作成 | 全変数定義 |
| `aws/ai-assistant/modules/main.tf` | 新規作成 | data sources・locals・共有 Bedrock ポリシー |
| `aws/ai-assistant/modules/role_cli.tf` | 新規作成 | CLI IAM ロール + ポリシーアタッチ |
| `aws/ai-assistant/modules/role_actions.tf` | 新規作成 | Actions IAM ロール + ポリシーアタッチ |
| `aws/ai-assistant/modules/outputs.tf` | 新規作成 | 出力定義 |
| `aws/ai-assistant/root.hcl` | 新規作成 | Terragrunt ルート設定・remote state |
| `aws/ai-assistant/envs/develop/env.hcl` | 新規作成 | 共通環境変数 |
| `aws/ai-assistant/envs/develop/cli.hcl` | 新規作成 | CLI ロール設定 |
| `aws/ai-assistant/envs/develop/actions.hcl` | 新規作成 | Actions ロール設定 |
| `aws/ai-assistant/envs/develop/terragrunt.hcl` | 新規作成 | 3つの hcl を include して inputs に展開 |
| `aws/claude-code/` | 削除 | 旧モジュール（Task 11 で destroy 後に削除） |
| `aws/claude-code-action/` | 削除 | 旧モジュール（Task 11 で destroy 後に削除） |

---

### Task 1: Create `modules/variables.tf`

**Files:**
- Create: `aws/ai-assistant/modules/variables.tf`

- [ ] **Step 1: ディレクトリを作成してファイルを書く**

```bash
mkdir -p aws/ai-assistant/modules
```

`aws/ai-assistant/modules/variables.tf`:

```hcl
variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., develop, staging, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "trusted_principal_arns" {
  description = "List of AWS principal ARNs allowed to assume the CLI role"
  type        = list(string)
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_repos" {
  description = "List of GitHub repository names"
  type        = list(string)
  default     = []
}

variable "oidc_provider_arn" {
  description = "ARN of existing OIDC provider"
  type        = string
}

variable "max_session_duration" {
  description = "Maximum session duration for the IAM role (in seconds)"
  type        = number
  default     = 3600
  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "Max session duration must be between 3600 (1 hour) and 43200 (12 hours) seconds."
  }
}

variable "additional_iam_policies" {
  description = "List of additional IAM policy ARNs to attach to both roles"
  type        = list(string)
  default     = []
}

variable "bedrock_inference_profiles" {
  description = "List of Bedrock cross-region inference profiles to allow access to. Each entry defines the inference profile ID, the underlying foundation model ID, and the source regions the profile routes to."
  type = list(object({
    profile_id     = string
    model_id       = string
    source_regions = list(string)
  }))
  default = [
    {
      profile_id = "us.anthropic.claude-sonnet-4-6"
      model_id   = "anthropic.claude-sonnet-4-6"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
    {
      profile_id = "us.anthropic.claude-opus-4-7"
      model_id   = "anthropic.claude-opus-4-7"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
    {
      profile_id = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      model_id   = "anthropic.claude-haiku-4-5-20251001-v1:0"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
  ]
}

variable "claude_model_region" {
  description = "AWS region where Claude models are available (may differ from main region)"
  type        = string
  default     = "us-west-2"
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terraform fmt -check aws/ai-assistant/modules/variables.tf
```

Expected: 出力なし（差分なし）

- [ ] **Step 3: Commit**

```bash
git add aws/ai-assistant/modules/variables.tf
git commit -s -m "feat: add ai-assistant variables.tf"
```

---

### Task 2: Create `modules/main.tf`

**Files:**
- Create: `aws/ai-assistant/modules/main.tf`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/modules/main.tf`:

```hcl
# main.tf - Data sources, locals, and shared Bedrock policy

# Get current AWS account information
data "aws_caller_identity" "current" {}

locals {
  # ARNs of the cross-region inference profiles (created in claude_model_region)
  inference_profile_arns = [
    for p in var.bedrock_inference_profiles :
    "arn:aws:bedrock:${var.claude_model_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${p.profile_id}"
  ]

  # ARNs of the underlying foundation models in every source region the profile
  # may route to. Both the profile ARN and the FM ARNs must be allowed or
  # InvokeModel returns AccessDenied, but the FM ARNs are only granted when the
  # request is routed through an approved inference profile (see the
  # bedrock:InferenceProfileArn condition below).
  foundation_model_arns = flatten([
    for p in var.bedrock_inference_profiles : [
      for r in p.source_regions :
      "arn:aws:bedrock:${r}::foundation-model/${p.model_id}"
    ]
  ])
}

# Shared IAM Policy for Bedrock Claude Access
resource "aws_iam_policy" "bedrock_claude_policy" {
  name        = "${var.project_name}-${var.environment}-ai-assistant-policy"
  description = "Policy for Bedrock Claude model access via cross-region inference profiles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.inference_profile_arns
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.foundation_model_arns
        Condition = {
          StringLike = {
            "bedrock:InferenceProfileArn" = local.inference_profile_arns
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-ai-assistant-policy"
    Purpose = "ai-assistant-access"
  })
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terraform fmt -check aws/ai-assistant/modules/main.tf
```

Expected: 出力なし

- [ ] **Step 3: Commit**

```bash
git add aws/ai-assistant/modules/main.tf
git commit -s -m "feat: add ai-assistant shared Bedrock policy in main.tf"
```

---

### Task 3: Create `modules/role_cli.tf`

**Files:**
- Create: `aws/ai-assistant/modules/role_cli.tf`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/modules/role_cli.tf`:

```hcl
# role_cli.tf - CLI IAM role for local development

resource "aws_iam_role" "cli_role" {
  name                 = "${var.project_name}-${var.environment}-cli-role"
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.trusted_principal_arns
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-cli-role"
    Purpose = "ai-assistant-cli"
  })
}

resource "aws_iam_role_policy_attachment" "cli_bedrock_policy" {
  role       = aws_iam_role.cli_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

resource "aws_iam_role_policy_attachment" "cli_additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.cli_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terraform fmt -check aws/ai-assistant/modules/role_cli.tf
```

Expected: 出力なし

- [ ] **Step 3: Commit**

```bash
git add aws/ai-assistant/modules/role_cli.tf
git commit -s -m "feat: add CLI IAM role in role_cli.tf"
```

---

### Task 4: Create `modules/role_actions.tf`

**Files:**
- Create: `aws/ai-assistant/modules/role_actions.tf`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/modules/role_actions.tf`:

```hcl
# role_actions.tf - GitHub Actions IAM role for CI/CD

resource "aws_iam_role" "actions_role" {
  name                 = "${var.project_name}-${var.environment}-github-actions-role"
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              for repo in var.github_repos : "repo:${var.github_org}/${repo}:*"
            ]
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name        = "${var.project_name}-${var.environment}-github-actions-role"
    GitHubOrg   = var.github_org
    GitHubRepos = join("+", var.github_repos)
    Purpose     = "ai-assistant-github-actions"
  })
}

resource "aws_iam_role_policy_attachment" "actions_bedrock_policy" {
  role       = aws_iam_role.actions_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

resource "aws_iam_role_policy_attachment" "actions_additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.actions_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terraform fmt -check aws/ai-assistant/modules/role_actions.tf
```

Expected: 出力なし

- [ ] **Step 3: Commit**

```bash
git add aws/ai-assistant/modules/role_actions.tf
git commit -s -m "feat: add Actions IAM role in role_actions.tf"
```

---

### Task 5: Create `modules/outputs.tf` and validate module

**Files:**
- Create: `aws/ai-assistant/modules/outputs.tf`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/modules/outputs.tf`:

```hcl
# outputs.tf

output "cli_role_arn" {
  description = "ARN of the CLI IAM role"
  value       = aws_iam_role.cli_role.arn
}

output "cli_role_name" {
  description = "Name of the CLI IAM role"
  value       = aws_iam_role.cli_role.name
}

output "actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.actions_role.arn
}

output "actions_role_name" {
  description = "Name of the GitHub Actions IAM role"
  value       = aws_iam_role.actions_role.name
}

output "bedrock_policy_arn" {
  description = "ARN of the shared Bedrock policy"
  value       = aws_iam_policy.bedrock_claude_policy.arn
}

output "bedrock_inference_profiles" {
  description = "List of allowed Bedrock cross-region inference profiles"
  value       = var.bedrock_inference_profiles
}

output "claude_model_region" {
  description = "AWS region where Claude models are available"
  value       = var.claude_model_region
}

output "cli_configuration" {
  description = "Configuration for local Claude Code CLI"
  value = {
    role_arn                   = aws_iam_role.cli_role.arn
    aws_region                 = var.aws_region
    claude_model_region        = var.claude_model_region
    bedrock_inference_profiles = var.bedrock_inference_profiles
  }
}

output "github_actions_configuration" {
  description = "Configuration for GitHub Actions"
  value = {
    role_arn                   = aws_iam_role.actions_role.arn
    aws_region                 = var.aws_region
    claude_model_region        = var.claude_model_region
    bedrock_inference_profiles = var.bedrock_inference_profiles
  }
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terraform fmt -check aws/ai-assistant/modules/outputs.tf
```

Expected: 出力なし

- [ ] **Step 3: モジュール全体を validate**

```bash
cd aws/ai-assistant/modules && terraform init -backend=false && terraform validate
```

Expected:
```
Success! The configuration is valid.
```

- [ ] **Step 4: Commit**

```bash
git add aws/ai-assistant/modules/outputs.tf
git commit -s -m "feat: add outputs.tf for ai-assistant module"
```

---

### Task 6: Create `root.hcl`

**Files:**
- Create: `aws/ai-assistant/root.hcl`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/root.hcl`:

```hcl
# root.hcl - Root Terragrunt configuration for ai-assistant

locals {
  project_name = "ai-assistant"

  # Parse environment from the directory path
  # This assumes environments are in envs/<environment>/ directories
  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "panicboat/platform"
    Component   = "ai-assistant"
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
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "platform/ai-assistant/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

# Common inputs passed to all Terraform modules
inputs = {
  project_name = local.project_name
  environment  = local.environment
  common_tags  = local.common_tags
  aws_region   = "ap-northeast-1"
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terragrunt hcl fmt --check --file aws/ai-assistant/root.hcl
```

Expected: 出力なし

- [ ] **Step 3: Commit**

```bash
git add aws/ai-assistant/root.hcl
git commit -s -m "feat: add ai-assistant root.hcl with remote state config"
```

---

### Task 7: Create `envs/develop/env.hcl`, `cli.hcl`, `actions.hcl`

**Files:**
- Create: `aws/ai-assistant/envs/develop/env.hcl`
- Create: `aws/ai-assistant/envs/develop/cli.hcl`
- Create: `aws/ai-assistant/envs/develop/actions.hcl`

- [ ] **Step 1: ディレクトリを作成して env.hcl を書く**

```bash
mkdir -p aws/ai-assistant/envs/develop
```

`aws/ai-assistant/envs/develop/env.hcl`:

```hcl
# env.hcl - Common environment configuration for develop

locals {
  environment         = "develop"
  aws_region          = "ap-northeast-1"
  claude_model_region = "us-west-2"
  max_session_duration = 7200 # 2 hours for development work

  additional_iam_policies = []

  environment_tags = {
    Environment = local.environment
    Purpose     = "ai-assistant"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 2: cli.hcl を書く**

`aws/ai-assistant/envs/develop/cli.hcl`:

```hcl
# cli.hcl - CLI role configuration for develop

locals {
  trusted_principal_arns = [
    "arn:aws:iam::559744160976:user/panicboat",
  ]
}
```

- [ ] **Step 3: actions.hcl を書く**

`aws/ai-assistant/envs/develop/actions.hcl`:

```hcl
# actions.hcl - GitHub Actions role configuration for develop

locals {
  github_repos = ["monorepo", "platform", "deploy-actions"]

  oidc_provider_arn = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"
}
```

- [ ] **Step 4: フォーマット確認**

```bash
terragrunt hcl fmt --check --file aws/ai-assistant/envs/develop/env.hcl
terragrunt hcl fmt --check --file aws/ai-assistant/envs/develop/cli.hcl
terragrunt hcl fmt --check --file aws/ai-assistant/envs/develop/actions.hcl
```

Expected: いずれも出力なし

- [ ] **Step 5: Commit**

```bash
git add aws/ai-assistant/envs/develop/env.hcl \
        aws/ai-assistant/envs/develop/cli.hcl \
        aws/ai-assistant/envs/develop/actions.hcl
git commit -s -m "feat: add develop environment hcl config files"
```

---

### Task 8: Create `envs/develop/terragrunt.hcl` and validate

**Files:**
- Create: `aws/ai-assistant/envs/develop/terragrunt.hcl`

- [ ] **Step 1: ファイルを書く**

`aws/ai-assistant/envs/develop/terragrunt.hcl`:

```hcl
# terragrunt.hcl - develop environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

include "cli" {
  path   = "cli.hcl"
  expose = true
}

include "actions" {
  path   = "actions.hcl"
  expose = true
}

terraform {
  source = "../../modules"
}

inputs = {
  project_name = "ai-assistant"
  environment  = include.env.locals.environment

  # AWS configuration
  aws_region          = include.env.locals.aws_region
  claude_model_region = include.env.locals.claude_model_region

  # IAM configuration
  max_session_duration    = include.env.locals.max_session_duration
  additional_iam_policies = include.env.locals.additional_iam_policies

  # CLI role
  trusted_principal_arns = include.cli.locals.trusted_principal_arns

  # Actions role
  github_org        = "panicboat"
  github_repos      = include.actions.locals.github_repos
  oidc_provider_arn = include.actions.locals.oidc_provider_arn

  # Tags
  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "ai-assistant"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 2: フォーマット確認**

```bash
terragrunt hcl fmt --check --file aws/ai-assistant/envs/develop/terragrunt.hcl
```

Expected: 出力なし

- [ ] **Step 3: Terragrunt 全体を validate**

```bash
cd aws/ai-assistant/envs/develop && terragrunt validate
```

Expected:
```
Success! The configuration is valid.
```

- [ ] **Step 4: Commit**

```bash
git add aws/ai-assistant/envs/develop/terragrunt.hcl
git commit -s -m "feat: add develop terragrunt.hcl"
```

---

### Task 9: Run `terragrunt plan`

**Files:** 変更なし（計画確認のみ）

- [ ] **Step 1: plan を実行して作成リソースを確認**

```bash
cd aws/ai-assistant/envs/develop && terragrunt plan
```

Expected: 以下3リソースの作成が表示される
```
# aws_iam_policy.bedrock_claude_policy will be created
# aws_iam_role.cli_role will be created
# aws_iam_role.actions_role will be created
# aws_iam_role_policy_attachment.cli_bedrock_policy will be created
# aws_iam_role_policy_attachment.actions_bedrock_policy will be created

Plan: 5 to add, 0 to change, 0 to destroy.
```

`additional_iam_policies` が空なので `cli_additional_policies` と `actions_additional_policies` は 0 count で表示されない。

- [ ] **Step 2: plan の差分に予期しないリソースがないことを確認**

destroy や change がゼロであること、作成されるリソース名が以下であることを確認する:
- `ai-assistant-develop-ai-assistant-policy`
- `ai-assistant-develop-cli-role`
- `ai-assistant-develop-github-actions-role`

---

### Task 10: Apply new module and update workflow-config.yaml

**Files:**
- Modify: `workflow-config.yaml`（Actions ロール ARN 更新が必要な場合のみ）

- [ ] **Step 1: apply を実行**

```bash
cd aws/ai-assistant/envs/develop && terragrunt apply
```

Expected:
```
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
```

- [ ] **Step 2: CLI ロールの Assume を確認**

```bash
aws sts assume-role \
  --role-arn "arn:aws:iam::559744160976:role/ai-assistant-develop-cli-role" \
  --role-session-name test-session
```

Expected: `AssumedRoleUser` を含む JSON レスポンス

- [ ] **Step 3: Actions ロール ARN を確認して参照先を更新**

```bash
cd aws/ai-assistant/envs/develop && terragrunt output actions_role_arn
```

Expected:
```
"arn:aws:iam::559744160976:role/ai-assistant-develop-github-actions-role"
```

GitHub Actions ワークフローで Claude Code Action に渡している `AWS_ROLE_ARN`（シークレット or ワークフロー YAML 内）を上記 ARN に更新する。

- [ ] **Step 4: Commit（変更した場合）**

```bash
git add <changed-files>
git commit -s -m "feat: update Actions role ARN to ai-assistant-develop-github-actions-role"
```

---

### Task 11: Destroy old modules and delete legacy directories

> **Note:** This task is deferred to a separate follow-up PR after runtime validation of the new `ai-assistant` module (confirm `aws sts assume-role` and GitHub Actions OIDC work correctly before destroying the old resources).

- [ ] **Step 1: 旧 claude-code-action を destroy**

```bash
cd aws/claude-code-action/envs/develop && terragrunt destroy
```

Expected:
```
Destroy complete! Resources: X destroyed.
```

- [ ] **Step 2: 旧 claude-code を destroy**

```bash
cd aws/claude-code/envs/develop && terragrunt destroy
```

Expected:
```
Destroy complete! Resources: X destroyed.
```

- [ ] **Step 3: 旧ディレクトリを削除**

```bash
git rm -r aws/claude-code aws/claude-code-action
```

- [ ] **Step 4: Commit**

```bash
git commit -s -m "chore: remove legacy claude-code and claude-code-action modules"
```

---

### Task 12: Open Pull Request

- [ ] **Step 1: ブランチを push**

```bash
git push -u origin feat/ai-assistant-integration
```

- [ ] **Step 2: PR を作成**

```bash
gh pr create \
  --title "feat: integrate claude-code and claude-code-action into ai-assistant" \
  --body "$(cat <<'EOF'
## Summary
- `aws/claude-code` と `aws/claude-code-action` を `aws/ai-assistant` に統合
- CLI ロール（`sts:AssumeRole`）と Actions ロール（`sts:AssumeRoleWithWebIdentity`）を単一モジュールで管理
- Terragrunt 設定を `env.hcl`・`cli.hcl`・`actions.hcl` に分割
- `bedrock:InferenceProfileArn` 条件キーを `StringLike` に統一（旧 `StringEquals` バグを修正）

## Migration
1. `aws/ai-assistant/envs/develop` で `terragrunt apply` 済み
2. 旧モジュールの destroy と旧ディレクトリ削除は runtime 検証後の follow-up PR で実施

## Test plan
- [ ] `terragrunt plan` で差分ゼロを確認
- [ ] `aws sts assume-role` で CLI ロールの Assume が通ることを確認
- [ ] GitHub Actions で `configure-aws-credentials` が通ることを確認
- [ ] `aws bedrock invoke-model` で Bedrock 呼び出しが通ることを確認
EOF
)"
```
