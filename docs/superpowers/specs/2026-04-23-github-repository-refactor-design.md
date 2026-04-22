# github/github-repository Refactoring Design

## Overview

`github/github-repository` 配下の `envs/` と `modules/` を整理するリファクタリング。

現状の課題：
- `envs/monorepo/terragrunt.hcl` と `envs/platform/terragrunt.hcl` の内容が完全に重複している
- `modules/main.tf` にリポジトリ作成・ブランチ保護・CloudWatch ログの3つの関心事が混在している
- `envs/{env}` の `{env}` が実際にはリポジトリ名（monorepo/platform）であり `workflow-config.yaml` の環境定義と整合していない

## Directory Structure

### Before

```
envs/
  monorepo/
    terragrunt.hcl   # 全リポジトリで同一内容（重複）
    env.hcl
  platform/
    terragrunt.hcl   # 全リポジトリで同一内容（重複）
    env.hcl
modules/
  main.tf            # 3つの関心事が混在
  variables.tf
  outputs.tf
  terraform.tf
```

### After

```
envs/
  develop/
    terragrunt.hcl   # 単一実行単位
    monorepo.hcl     # リポジトリ設定
    platform.hcl     # リポジトリ設定
modules/
  terraform.tf
  variables.tf         # repositories = map(object({...})) に変更
  repository.tf        # github_repository
  branch_protection.tf # github_branch_protection
  logging.tf           # aws_cloudwatch_log_group
  outputs.tf
```

## Module Interface

### variables.tf

`repository_config`（単一オブジェクト）を `repositories`（map）に変更する。

```hcl
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

### リソースの for_each

```hcl
# repository.tf
resource "github_repository" "repository" {
  for_each    = var.repositories
  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility
  ...
}

# branch_protection.tf
locals {
  branch_protection_rules = merge([
    for repo_key, repo in var.repositories : {
      for branch_key, branch in repo.branch_protection :
      "${repo_key}-${branch_key}" => merge(branch, { repository_node_id = github_repository.repository[repo_key].node_id })
    }
  ]...)
}

resource "github_branch_protection" "branches" {
  for_each      = local.branch_protection_rules
  repository_id = each.value.repository_node_id
  ...
}
```

## Data Flow

### envs/develop/monorepo.hcl

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
    branch_protection = {
      main = {
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

### envs/develop/terragrunt.hcl

```hcl
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

## State Migration

### 現状の state ファイル

```
platform/github-repository/monorepo/terraform.tfstate
platform/github-repository/platform/terraform.tfstate
```

### 移行後の state ファイル

```
platform/github-repository/develop/terraform.tfstate
```

### 移行手順

1. 新構造のコードを適用する前に `terraform state mv` で各リソースを移行する
2. `monorepo` state から新 state へ移行：
   - `github_repository.repository` → `github_repository.repository["monorepo"]`
   - `github_branch_protection.branches["main"]` → `github_branch_protection.branches["monorepo-main"]`
   - `aws_cloudwatch_log_group.github_repository_logs` → `aws_cloudwatch_log_group.github_repository_logs["monorepo"]`
3. `platform` state から新 state へ移行：
   - `github_repository.repository` → `github_repository.repository["platform"]`
   - `github_branch_protection.branches["main"]` → `github_branch_protection.branches["platform-main"]`
   - `aws_cloudwatch_log_group.github_repository_logs` → `aws_cloudwatch_log_group.github_repository_logs["platform"]`
4. 移行後に `terraform plan` で差分ゼロを確認
5. 旧 state ファイルを削除

`moved` ブロックは異なる state ファイル間の移行に対応していないため使用しない。

## Success Criteria

- `terraform plan` で差分がゼロになること
- 既存リソース（GitHub リポジトリ・ブランチ保護・CloudWatch ログ）が削除・再作成されないこと
- 新しいリポジトリの追加が `envs/develop/` に `.hcl` ファイルを1つ追加するだけで完結すること
