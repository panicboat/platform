# Disable Forking on Selected Public Repositories

## Background

GitHub リポジトリは Terraform / Terragrunt（`github/repository/` 配下）で管理している。現状の `github_repository` リソースでは `allow_forking` を明示しておらず、すべてのリポジトリで fork が暗黙的に許可されている（public リポジトリにおいて意味を持つ。private/internal の fork 可否は org 設定で制御される）。

特定の public リポジトリで fork を禁止しつつ、リポジトリごとに切り替えられるようにしたい。

## Goals

- 各リポジトリの `.hcl` で fork 可否を個別に指定できるようにする。
- 今回の変更で `monorepo` と `platform` の fork を禁止する。
- それ以外のリポジトリは現状の挙動（fork 許可）を維持する。

## Non-Goals

- 組織レベルの fork ポリシーは変更しない。
- 可視性、ブランチ保護、その他のリポジトリ設定は変更しない。
- per-repo 設定を `terragrunt.hcl` に渡す経路の構造は変えない。

## Design

### Module schema change

`github/repository/modules/variables.tf`

`repositories` map の値オブジェクトに optional な `allow_forking` を追加し、デフォルト値を `true` として既存挙動を維持する。

```hcl
variable "repositories" {
  description = "Map of repository configurations. visibility must be one of: public, private, internal"
  type = map(object({
    name          = string
    description   = string
    visibility    = string
    allow_forking = optional(bool, true)
    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })
  }))
}
```

### Resource change

`github/repository/modules/main.tf`

`github_repository` リソースに `allow_forking` を渡す。collaboration 系の `features` ではなく、access / security 系の `vulnerability_alerts` の近くに配置する。

```hcl
resource "github_repository" "repository" {
  ...
  vulnerability_alerts = true
  allow_forking        = each.value.allow_forking
  ...
}
```

### Per-repository configuration

fork を禁止する 2 リポジトリの `.hcl` に `allow_forking = false` を追加する。

- `github/repository/envs/develop/monorepo.hcl`
- `github/repository/envs/develop/platform.hcl`

その他 4 ファイル（`deploy-actions.hcl`, `panicboat-actions.hcl`, `ansible.hcl`, `dotfiles.hcl`）は変更せず、デフォルトの `true` を継承する。

変更後の例:

```hcl
locals {
  repository = {
    name          = "monorepo"
    description   = "Monorepo for multiple services and infrastructure configurations."
    visibility    = "public"
    allow_forking = false
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

## Verification

1. `github/repository/envs/develop/` で `terragrunt plan` を実行し、以下を確認する。
   - `monorepo` と `platform` で `allow_forking: true -> false` の差分が出ること。
   - 他の 4 リポジトリで `allow_forking` の差分が出ないこと。
2. `terragrunt apply` 後、GitHub UI で `monorepo` と `platform` の "Allow forking" がオフになっていること、それ以外のリポジトリで設定が変わっていないことを確認する。

## Rollback

該当コミットを revert し、`terragrunt apply` を実行することで `allow_forking = true` に戻す。
