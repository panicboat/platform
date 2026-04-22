# github/repository Refactoring Design

## Overview

`github/github-repository` を `github/repository` と `github/branch` の2サービスに分割しつつ、`envs/` と `modules/` を整理するリファクタリング。

現状の課題：
- ディレクトリ名 `github-repository` が `github/` 配下に置かれており `github-` プレフィックスが冗長
- `envs/monorepo/terragrunt.hcl` と `envs/platform/terragrunt.hcl` の内容が完全に重複している
- `modules/main.tf` にリポジトリ作成・ブランチ保護・CloudWatch ログの3つの関心事が混在している
- `envs/{env}` の `{env}` が実際にはリポジトリ名（monorepo/platform）であり `workflow-config.yaml` の環境定義と整合していない

## Directory Structure

### Before

```
github/
  github-repository/
    root.hcl
    envs/
      monorepo/
        terragrunt.hcl
        env.hcl
      platform/
        terragrunt.hcl
        env.hcl
    modules/
      main.tf            # github_repository + github_branch_protection + aws_cloudwatch_log_group が混在
      variables.tf
      outputs.tf
      terraform.tf
```

### After

```
github/
  repository/            # github_repository + aws_cloudwatch_log_group
    root.hcl
    envs/
      develop/
        terragrunt.hcl
        monorepo.hcl
        platform.hcl
    modules/
      terraform.tf
      variables.tf
      main.tf            # github_repository + aws_cloudwatch_log_group
      outputs.tf
  branch/                # github_branch_protection
    root.hcl
    envs/
      develop/
        terragrunt.hcl
        monorepo.hcl
        platform.hcl
    modules/
      terraform.tf
      variables.tf
      main.tf            # github_branch_protection
      outputs.tf
```

## Module Interface

### github/repository

`variables.tf` はリポジトリ設定のみ（ブランチ保護を含まない）。

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
  }))
}
```

### github/branch

`variables.tf` はリポジトリ名とブランチ保護ルールのみ。

```hcl
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

### github/branch の main.tf

`data "github_repository"` でリポジトリの `node_id` を取得する。

```hcl
data "github_repository" "repo" {
  for_each = var.repositories
  name     = each.value.name
}

locals {
  branch_protection_rules = merge([
    for repo_key, repo in var.repositories : {
      for branch_key, branch in repo.branch_protection :
      "${repo_key}-${branch_key}" => merge(branch, {
        repository_node_id = data.github_repository.repo[repo_key].node_id
      })
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

### github/repository/envs/develop/monorepo.hcl

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

### github/branch/envs/develop/monorepo.hcl

```hcl
locals {
  repository = {
    name = "monorepo"
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

### envs/develop/terragrunt.hcl（両サービス共通パターン）

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

## root.hcl の変更

各サービスの `root.hcl` で `project_name` と state キーを変更する。

```hcl
# github/repository/root.hcl
locals {
  project_name = "repository"
}
remote_state {
  config = {
    key = "platform/repository/${local.environment}/terraform.tfstate"
  }
}

# github/branch/root.hcl
locals {
  project_name = "branch"
}
remote_state {
  config = {
    key = "platform/branch/${local.environment}/terraform.tfstate"
  }
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
platform/repository/develop/terraform.tfstate   # github_repository + aws_cloudwatch_log_group
platform/branch/develop/terraform.tfstate        # github_branch_protection
```

### 移行手順

1. 新構造のコードを適用する前に `terraform state mv` で各リソースを移行する
2. `monorepo` state から `platform/repository/develop` へ：
   - `github_repository.repository` → `github_repository.repository["monorepo"]`
   - `aws_cloudwatch_log_group.github_repository_logs` → `aws_cloudwatch_log_group.github_repository_logs["monorepo"]`
3. `platform` state から `platform/repository/develop` へ：
   - `github_repository.repository` → `github_repository.repository["platform"]`
   - `aws_cloudwatch_log_group.github_repository_logs` → `aws_cloudwatch_log_group.github_repository_logs["platform"]`
4. `monorepo` state から `platform/branch/develop` へ：
   - `github_branch_protection.branches["main"]` → `github_branch_protection.branches["monorepo-main"]`
5. `platform` state から `platform/branch/develop` へ：
   - `github_branch_protection.branches["main"]` → `github_branch_protection.branches["platform-main"]`
6. 移行後に各サービスで `terraform plan` を実行し差分ゼロを確認
7. 旧 state ファイルを削除

`moved` ブロックは異なる state ファイル間の移行に対応していないため使用しない。

## Success Criteria

- `terraform plan` で差分がゼロになること（`github/repository`・`github/branch` 両サービス）
- 既存リソース（GitHub リポジトリ・ブランチ保護・CloudWatch ログ）が削除・再作成されないこと
- 新しいリポジトリの追加が各サービスの `envs/develop/` に `.hcl` ファイルを1つ追加するだけで完結すること
