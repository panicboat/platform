# Disable Forking on Selected Public Repositories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `github_repository` モジュールに `allow_forking` を追加し、`monorepo` と `platform` リポジトリで fork を禁止する。

**Architecture:** `repository` モジュールの `repositories` 変数のスキーマに optional な `allow_forking`（デフォルト `true`）を追加し、`github_repository` リソースに渡す。fork を禁止したいリポジトリの `.hcl` で `allow_forking = false` を明示する。

**Tech Stack:** Terraform >= 1.14.8, Terragrunt, GitHub Provider ~> 6.11

**Spec:** `docs/superpowers/specs/2026-04-28-disable-forking-design.md`

---

## File Map

**Modify:**
- `github/repository/modules/variables.tf` — `repositories` の object 型に `allow_forking = optional(bool, true)` を追加
- `github/repository/modules/main.tf` — `github_repository` リソースに `allow_forking = each.value.allow_forking` を追加
- `github/repository/envs/develop/monorepo.hcl` — `allow_forking = false` を追加
- `github/repository/envs/develop/platform.hcl` — `allow_forking = false` を追加

**Unchanged:**
- `github/repository/envs/develop/deploy-actions.hcl`
- `github/repository/envs/develop/panicboat-actions.hcl`
- `github/repository/envs/develop/ansible.hcl`
- `github/repository/envs/develop/dotfiles.hcl`

---

## Task 1: モジュールスキーマに `allow_forking` を追加する

**Files:**
- Modify: `github/repository/modules/variables.tf:34-46`

- [ ] **Step 1: `repositories` 変数の object 型に `allow_forking` を追加する**

`github/repository/modules/variables.tf` の `repositories` 変数を以下に置き換える。

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

- [ ] **Step 2: `terraform fmt` でフォーマットする**

Run: `cd github/repository && make fmt`
Expected: 終了コード 0、整形差分があれば適用される。

- [ ] **Step 3: コミット**

```bash
git add github/repository/modules/variables.tf
git commit -s -m "feat(github/repository): add allow_forking field to repositories variable"
```

---

## Task 2: リソースに `allow_forking` を渡す

**Files:**
- Modify: `github/repository/modules/main.tf:12`

- [ ] **Step 1: `github_repository` リソースに `allow_forking` を追加する**

`github/repository/modules/main.tf` の `vulnerability_alerts = true` の直後に `allow_forking = each.value.allow_forking` を追加する。差分は以下の通り。

```hcl
  vulnerability_alerts = true
  allow_forking        = each.value.allow_forking

  allow_merge_commit     = false
```

変更後の該当部分:

```hcl
resource "github_repository" "repository" {
  for_each = var.repositories

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility

  has_issues   = each.value.features.issues
  has_wiki     = each.value.features.wiki
  has_projects = each.value.features.projects

  vulnerability_alerts = true
  allow_forking        = each.value.allow_forking

  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_update_branch    = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  squash_merge_commit_message = "BLANK"
  squash_merge_commit_title   = "PR_TITLE"

  archived = false
}
```

- [ ] **Step 2: `terraform fmt` でフォーマットする**

Run: `cd github/repository && make fmt`
Expected: 終了コード 0。

- [ ] **Step 3: `terragrunt validate` で構文確認する**

Run: `cd github/repository && make validate ENV=develop`
Expected: 終了コード 0、`Success!` が表示される。

- [ ] **Step 4: コミット**

```bash
git add github/repository/modules/main.tf
git commit -s -m "feat(github/repository): wire allow_forking through to github_repository resource"
```

---

## Task 3: `monorepo` と `platform` で fork を禁止する

**Files:**
- Modify: `github/repository/envs/develop/monorepo.hcl`
- Modify: `github/repository/envs/develop/platform.hcl`

- [ ] **Step 1: `monorepo.hcl` に `allow_forking = false` を追加する**

`github/repository/envs/develop/monorepo.hcl` を以下に置き換える。

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

- [ ] **Step 2: `platform.hcl` に `allow_forking = false` を追加する**

`github/repository/envs/develop/platform.hcl` を以下に置き換える。

```hcl
locals {
  repository = {
    name          = "platform"
    description   = "Platform for multiple services and infrastructure configurations"
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

- [ ] **Step 3: `terraform fmt` でフォーマットする**

Run: `cd github/repository && make fmt`
Expected: 終了コード 0。

- [ ] **Step 4: `terragrunt plan` で差分を確認する**

Run: `cd github/repository && make plan ENV=develop`
Expected:
- `github_repository.repository["monorepo"]` で `allow_forking: true -> false` の差分が出る。
- `github_repository.repository["platform"]` で `allow_forking: true -> false` の差分が出る。
- `deploy-actions`, `panicboat-actions`, `ansible`, `dotfiles` の 4 リポジトリで `allow_forking` の差分が出ない（リフレッシュ差分以外）。
- `Plan: 0 to add, 2 to change, 0 to destroy.` と表示される（他に未適用の差分が無い前提）。

差分が想定外（4 リポジトリのいずれかで `allow_forking` が変化した、あるいは `monorepo`/`platform` で変化しなかった）の場合は、Task 1〜2 のスキーマ・リソース定義を見直す。

- [ ] **Step 5: コミット**

```bash
git add github/repository/envs/develop/monorepo.hcl github/repository/envs/develop/platform.hcl
git commit -s -m "feat(github/repository): disable forking on monorepo and platform"
```

---

## Task 4: 適用と検証

**Files:** （変更なし、運用作業のみ）

- [ ] **Step 1: `terragrunt apply` を実行する**

Run: `cd github/repository && make apply ENV=develop`
Expected: `Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`

- [ ] **Step 2: GitHub UI で確認する**

ブラウザで以下を確認する。
- `https://github.com/panicboat/monorepo/settings` の "Features" セクションで "Allow forking" がオフになっている。
- `https://github.com/panicboat/platform/settings` の "Features" セクションで "Allow forking" がオフになっている。
- `deploy-actions`, `panicboat-actions`, `ansible`, `dotfiles` の "Allow forking" は変更されていない（オン）。

差分が想定通りでない場合は revert + 再適用で `allow_forking = true` に戻す。

- [ ] **Step 3: PR を作成する**

`feat/disable-forking` を origin に push し、Draft PR を作成する。

```bash
git push -u origin HEAD
gh pr create --draft --title "feat(github/repository): disable forking on monorepo and platform" --body "$(cat <<'EOF'
## Summary
- `repositories` 変数に `allow_forking`（optional, default true）を追加
- `monorepo` と `platform` で `allow_forking = false` に設定

## Spec
docs/superpowers/specs/2026-04-28-disable-forking-design.md

## Test plan
- [ ] `make plan ENV=develop` で `monorepo` / `platform` のみ `allow_forking: true -> false`
- [ ] `make apply ENV=develop` 後、GitHub UI で 2 リポジトリの "Allow forking" がオフ
- [ ] 他 4 リポジトリの "Allow forking" は変化なし
EOF
)"
```
