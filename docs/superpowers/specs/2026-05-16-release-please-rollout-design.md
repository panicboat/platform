# release-please Rollout Design

## Overview

`googleapis/release-please-action` を `panicboat-actions` / `platform` / `monorepo` の 3 リポジトリに導入し、CHANGELOG 生成・semver tag 付与・GitHub Release 作成までを自動化する。`deploy-actions` で稼働中の release-please をリファレンス実装として踏襲し、3 リポジトリでリリース運用パターンを統一する。

3 リポジトリの性格が異なるため、構成は揃えつつ release-type と manifest mode の有無で差を付ける。

- `panicboat-actions`: composite actions の公開リポ。`deploy-actions` と同じく major tag (`v0`) の force update を行い、`uses: panicboat/panicboat-actions/<name>@v0` 形式を維持する。
- `platform`: インフラ (Terragrunt + Kubernetes) の単一 component リポ。CHANGELOG + tag + GitHub Release で変更履歴とロールバック起点を提供する。
- `monorepo`: アプリ (monolith + frontend) の multi-component リポ。manifest mode で 2 component を独立にバージョン管理する。

## Scope

### In scope

- 3 リポジトリへの `.github/workflows/release.yml` 追加
- monorepo のみ `release-please-config.json` + `.release-please-manifest.json` 追加
- 各リポジトリでの初回 release-please PR 生成と検証
- panicboat-actions の `v0` major tag force update

### Out of scope (Phase 2 で別 spec)

- monorepo の Flux 連携 (release-please tag を起点とした semver image tag + Flux ImagePolicy 切替)
- monorepo / platform の production deploy トリガーを GitHub Release `published` イベントに切替 (`auto-label--deploy-trigger.yaml` の変更を含む)
- Phase 1 で生成される tag と GitHub Release を Phase 2 が消費する。Phase 1 では下流が `on: release: types: [published]` で受けられる状態 (Release が draft ではなく published で作成される) を保証するに留める。

## Repository Configuration

| Item | panicboat-actions | platform | monorepo |
|---|---|---|---|
| release-type | `simple` | `simple` | manifest (2 component) |
| manifest ファイル | なし | なし | あり |
| 初期 version | `0.1.0` | `0.1.0` | monolith: `0.1.0`, frontend: `0.1.0` |
| major tag (force update) | あり (`v0`) | なし | なし |
| GitHub Release | あり (published) | あり (published) | あり (published) |
| バージョンファイル更新 | なし | なし | なし |

### release-type: simple の意図

3 リポジトリすべて `simple` を採用し、コードベース内のバージョンファイル (`package.json` / `version.rb` 等) は更新しない。

- `panicboat-actions` / `platform`: そもそも配布パッケージではないため version 値の同期先がない。
- `monorepo`: `services/frontend/workspace/package.json` は `"private": true` で外部公開しておらず、`services/monolith/workspace/` は Hanami アプリで gemspec を持たない。version の同期先が実質的にない。

version の source of truth は `.release-please-manifest.json` (monorepo のみ) または最新 git tag (panicboat-actions / platform) とする。

### Non-manifest mode (panicboat-actions / platform)

`panicboat-actions` と `platform` は単一 component のため manifest mode を採用せず、設定を workflow の `with:` に集約する。`deploy-actions` と同じパターンになり、`release-please-config.json` / `.release-please-manifest.json` を作成しない。

### Manifest mode (monorepo)

`monorepo` は 2 component を扱うため manifest mode を採用する (release-please の仕様上、複数 package を一つの workflow で扱うには manifest mode が必須)。

## Common Workflow Structure

`deploy-actions/.github/workflows/release.yml` を踏襲した共通テンプレート。3 リポジトリ共通で以下の構造を採る。

```yaml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  release-please:
    runs-on: ubuntu-latest
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@1b10c78c7865c340bc4f6099eb2f838309f1e8c3 # v3.1.1
        with:
          app-id: ${{ vars.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7 # v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          # 以下はリポジトリごとに差分
```

### Repository-Specific Differences

#### panicboat-actions

```yaml
        with:
          token: ${{ steps.app-token.outputs.token }}
          release-type: simple
          bootstrap-sha: <導入 PR マージ直後の main HEAD SHA>
          initial-version: "0.1.0"
```

加えて、`deploy-actions` と同じ major tag force update ステップを追加する。

```yaml
      - name: Checkout for major tag update
        if: ${{ steps.release.outputs.release_created }}
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          token: ${{ steps.app-token.outputs.token }}
          fetch-depth: 0

      - name: Update major version tag
        if: ${{ steps.release.outputs.release_created }}
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          git tag -f v${{ steps.release.outputs.major }} ${{ steps.release.outputs.tag_name }}
          git push origin v${{ steps.release.outputs.major }} --force
```

v0 系のうちは `steps.release.outputs.major` が `0` を返すため、`v0` tag が force update される。`uses: panicboat/panicboat-actions/<name>@v0` で参照できる状態を維持する。

#### platform

```yaml
        with:
          token: ${{ steps.app-token.outputs.token }}
          release-type: simple
          bootstrap-sha: <導入 PR マージ直後の main HEAD SHA>
          initial-version: "0.1.0"
```

major tag ステップは持たない (platform は他リポから参照されないため)。

#### monorepo

```yaml
        with:
          token: ${{ steps.app-token.outputs.token }}
          # config / manifest ファイルがあれば release-type は指定不要
```

manifest mode のため、設定は `release-please-config.json` と `.release-please-manifest.json` に委譲する。

## monorepo Manifest Configuration

`release-please-config.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<導入 PR マージ直後の main HEAD SHA>",
  "separate-pull-requests": true,
  "packages": {
    "services/monolith": {
      "release-type": "simple",
      "component": "monolith",
      "include-component-in-tag": true
    },
    "services/frontend": {
      "release-type": "simple",
      "component": "frontend",
      "include-component-in-tag": true
    }
  }
}
```

`.release-please-manifest.json`:

```json
{
  "services/monolith": "0.1.0",
  "services/frontend": "0.1.0"
}
```

### Tag Format

`include-component-in-tag: true` により tag は以下の形式になる。

- `monolith-v0.2.0`
- `frontend-v0.5.0`

この tag 形式は Phase 2 (Flux 連携) で image tag のソースとして消費される前提。

### Separate Pull Requests

`separate-pull-requests: true` により、monolith / frontend の変更は別々の release PR として作成される。各 component を独立にリリースできる。

### Path-Based Commit Routing

monorepo の release-please は commit の変更パスで component を判定する (`services/monolith/` 配下の変更は monolith の CHANGELOG に、`services/frontend/` 配下の変更は frontend の CHANGELOG に振り分けられる)。Conventional Commits の scope (`feat(monolith):` 等) は CHANGELOG の表記に使われるが、振り分け自体はパスベース。

## Initial Version and Bootstrap SHA

### Initial Version

3 リポジトリすべて v0 系で開始する。

- v0.x.x の間は破壊的変更でも minor bump に留まる (release-please のデフォルト動作、SemVer 0.x の慣習)。
- 1.0.0 に上げる判断は別タイミングで行う (`Release-As: 1.0.0` コミットまたは release PR の手動編集で bump)。

### Bootstrap SHA

各リポジトリの全 git 履歴を release-please が走査して CHANGELOG に巻き込むのを防ぐため、`bootstrap-sha` で起点を固定する。

- 値は「release-please 導入 PR がマージされた直後の main HEAD SHA」
- release-please は `bootstrap-sha` より新しいコミットを CHANGELOG の対象として扱う
- 導入 PR 自体を CHANGELOG から除外する効果がある

## SHA Pinning

panicboat 4リポジトリで SHA-pinned uses が強制されている。`deploy-actions/release.yml` で稼働実績のある以下のピンを再利用する。

- `actions/create-github-app-token@1b10c78c7865c340bc4f6099eb2f838309f1e8c3` (v3.1.1)
- `googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7` (v5)
- `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd` (v6.0.2) — panicboat-actions のみ

導入後の SHA 更新は Renovate に委ねる前提。各リポジトリの `.github/renovate.json` で release-please-action / create-github-app-token / checkout が更新対象に含まれていることは実装時に確認する。

## Existing Workflow Integration

3 リポジトリすべてに `semantic-pull-request.yml` が既に存在し、Conventional Commits の PR title 検証が稼働している。release-please の前提 (CC 形式の commit/PR title) はこの仕組みで担保されているため、追加変更は不要。

## Branch Protection Compatibility

`platform/github/branch/` で管理されている branch protection は release-please の動作と互換である。

- release-please は release PR を自動で作成・更新する (push ではなく PR 経由)
- release PR は人がレビュー&マージする運用 (自動マージしない) ため、レビュー必須・status check 必須の保護要件と矛盾しない
- GitHub App token (`vars.APP_ID` / `secrets.APP_PRIVATE_KEY`) が PR 作成権限を持つことが前提

branch protection 設定自体への変更は不要。

## GitHub App

既存の `vars.APP_ID` / `secrets.APP_PRIVATE_KEY` を 3 リポジトリで流用する。`deploy-actions` で実績がある。

## Phase 2 Dependencies (Out of Scope, for Reference)

Phase 1 で生成される以下のアーティファクトを Phase 2 が消費する。

- **monorepo の tag** (`monolith-v0.X.0` / `frontend-v0.X.0`): Phase 2 で Docker image tag のソースとして使用
- **monorepo の GitHub Release (published)**: Phase 2 で production deploy トリガーとして使用 (`on: release: types: [published]`)
- **platform の GitHub Release (published)**: Phase 2 で production deploy トリガーとして使用

Phase 1 では GitHub Release が draft ではなく published 状態で作成されることを保証する (release-please-action のデフォルト挙動と一致するため特別な設定は不要だが、Phase 2 で前提として依存)。

## Implementation Order

3 リポジトリは独立しており並列実行可能だが、レビュー負荷とリスク軽減のため以下の順で導入する。

1. **panicboat-actions**: 最小構成 (single component + major tag) で `deploy-actions` パターンの再現性を検証
2. **platform**: panicboat-actions と同等、major tag ステップを除くだけ
3. **monorepo**: manifest mode で複雑度が一段上、最後に導入

各リポジトリの導入手順は同パターン:

1. `release.yml` (および monorepo は config/manifest) を含む PR を作成・マージ
2. マージ後の main HEAD SHA を取得
3. `bootstrap-sha` を当該 SHA に更新する追従 PR を作成・マージ
4. 次の main 更新で release-please PR が自動生成されることを確認
5. release-please PR をマージして tag / GitHub Release / CHANGELOG.md が生成されることを確認
6. (panicboat-actions のみ) `v0` tag が force update されることを確認

## Verification

各リポジトリで以下を確認する。

- [ ] release-please PR が main への push を契機に自動作成される
- [ ] release-please PR を main にマージすると以下が生成される
  - [ ] semver tag (panicboat-actions: `v0.X.0`、platform: `v0.X.0`、monorepo: `monolith-v0.X.0` / `frontend-v0.X.0`)
  - [ ] GitHub Release (published 状態)
  - [ ] CHANGELOG.md (monorepo は `services/monolith/CHANGELOG.md` と `services/frontend/CHANGELOG.md` の 2 ファイル)
- [ ] (panicboat-actions のみ) `v0` tag が当該 release の tag に force update されている
- [ ] (monorepo のみ) monolith と frontend が独立した release PR として生成される
