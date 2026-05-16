# release-please Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `panicboat-actions` / `platform` / `monorepo` の 3 リポジトリに `googleapis/release-please-action` を導入し、CHANGELOG / semver tag / GitHub Release の自動生成を有効化する。

**Architecture:** `deploy-actions` で稼働中の `release.yml` をテンプレートとして 3 リポジトリに展開。`panicboat-actions` と `platform` は単一 component の `release-type: simple` (非 manifest mode)、`monorepo` は monolith / frontend 2 component の manifest mode。各リポジトリで 1 PR ずつ作成し、ブランチ作成時の `origin/main` SHA を `bootstrap-sha` に埋め込むことで初回 release の CHANGELOG を導入 PR 単体に閉じ込める。

**Tech Stack:**
- `googleapis/release-please-action@v5`
- `actions/create-github-app-token@v3.1.1`
- `actions/checkout@v6.0.2` (panicboat-actions のみ)
- 既存 GitHub App (`vars.APP_ID` / `secrets.APP_PRIVATE_KEY`)

**Reference:**
- Spec: `docs/superpowers/specs/2026-05-16-release-please-rollout-design.md`
- Reference impl: `/Users/takanokenichi/GitHub/panicboat/deploy-actions/.github/workflows/release.yml`

---

## File Structure

各リポジトリで新規作成するファイル:

| Repo | File | Role |
|---|---|---|
| `panicboat-actions` | `.github/workflows/release.yml` | release-please workflow (simple + major tag force update) |
| `platform` | `.github/workflows/release.yml` | release-please workflow (simple) |
| `monorepo` | `.github/workflows/release.yml` | release-please workflow (manifest mode) |
| `monorepo` | `release-please-config.json` | manifest mode の package 設定 |
| `monorepo` | `.release-please-manifest.json` | 各 package の現在バージョン (state) |

既存ファイルへの変更はなし (`.github/renovate.json` は確認のみ、変更不要)。

## Common Conventions

3 Task すべてに共通する規則 (CLAUDE.md 由来):

- worktree は `<repo>/.claude/worktrees/feat-release-please-rollout/` に作成
- ブランチ名は `feat/release-please-rollout`
- ブランチは `origin/main` から切る
- 初回利用時のリポジトリでは `.git/info/exclude` に `/.claude/worktrees/` を追加 (各リポジトリで独立)
- commit メッセージは Conventional Commits + `-s` (sign-off)
- 初回 push は `git push -u origin HEAD`
- PR は必ず `gh pr create --draft` で作成
- `Co-Authored-By` は付けない

---

## Task 1: panicboat-actions に release-please を導入

**Files:**
- Create: `panicboat-actions/.github/workflows/release.yml`

### Setup

- [ ] **Step 1.1: panicboat-actions の worktree exclude を確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
grep -q "^/.claude/worktrees/" .git/info/exclude && echo OK || echo MISSING
```

Expected: `OK`

`MISSING` が返ったら、`.git/info/exclude` の末尾に `/.claude/worktrees/` を追加してから続行する (このコミットは git に残らない、ローカル ignore)。

- [ ] **Step 1.2: panicboat-actions の最新を取得**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git fetch origin main --quiet
```

Expected: no output

- [ ] **Step 1.3: worktree とブランチを作成**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git worktree add -b feat/release-please-rollout .claude/worktrees/feat-release-please-rollout origin/main
```

Expected: `Preparing worktree (new branch 'feat/release-please-rollout')` + `branch 'feat/release-please-rollout' set up to track 'origin/main'.`

- [ ] **Step 1.4: bootstrap-sha を取得して環境変数に保存**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/feat-release-please-rollout
BOOTSTRAP_SHA=$(git rev-parse origin/main)
echo "BOOTSTRAP_SHA=$BOOTSTRAP_SHA"
```

Expected: 40 桁の SHA (例: `f917fa0abc...`)。後続のファイル作成でこの SHA を実値として埋め込む。

### Implementation

- [ ] **Step 1.5: `.github/workflows/release.yml` を作成**

Files: `panicboat-actions/.claude/worktrees/feat-release-please-rollout/.github/workflows/release.yml`

Step 1.4 で取得した `$BOOTSTRAP_SHA` を `bootstrap-sha:` 行に埋め込んだ状態で以下の内容を作成する。

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
          release-type: simple
          bootstrap-sha: <Step 1.4 で取得した SHA を実値で埋め込む>
          initial-version: "0.1.0"

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

- [ ] **Step 1.6: actionlint で workflow を静的検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/feat-release-please-rollout
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release.yml
```

Expected: no output (exit 0)

`actionlint` がローカルになければ `brew install actionlint` 後に `actionlint .github/workflows/release.yml` でも可。

- [ ] **Step 1.7: bootstrap-sha が実値で埋め込まれていることを確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/feat-release-please-rollout
grep -E "bootstrap-sha:\s*[a-f0-9]{40}" .github/workflows/release.yml
```

Expected: 1 行マッチ (`bootstrap-sha: <40桁 SHA>`)。プレースホルダー (`<...>`) が残っていれば NG。

### Commit and PR

- [ ] **Step 1.8: commit**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/feat-release-please-rollout
git add .github/workflows/release.yml
git commit -s -m "$(cat <<'EOF'
feat(ci): release-please workflow を追加

deploy-actions と同パターンで GitHub Release / CHANGELOG / semver tag を
自動生成する。composite actions の参照を維持するため v0 major tag の
force update も同 workflow で行う。

Spec: docs/superpowers/specs/2026-05-16-release-please-rollout-design.md
EOF
)"
```

Expected: 1 file changed, 41 insertions (commit が作成される)

注: コミットメッセージは panicboat-actions リポでは `docs/superpowers/...` というパスが存在しないが、参照として URL ベースで読めるよう platform リポの spec パスを文中に残す。

- [ ] **Step 1.9: push と PR (draft) 作成**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/feat-release-please-rollout
git push -u origin HEAD
gh pr create --draft --title "feat(ci): release-please workflow を追加" --body "$(cat <<'EOF'
## Summary

- \`googleapis/release-please-action@v5\` を main への push で起動
- \`release-type: simple\`、初期バージョン \`0.1.0\`
- composite actions の参照を維持するため \`v0\` major tag を force update
- \`bootstrap-sha\` は導入 PR のベース main HEAD に固定し、初回 release CHANGELOG をこの PR のコミット 1 件に閉じ込める

## Spec

panicboat/platform リポの \`docs/superpowers/specs/2026-05-16-release-please-rollout-design.md\` を参照。

## Test plan

- [ ] CI (lint-actions / semantic-pull-request) が通る
- [ ] マージ後、release-please PR が自動生成される
- [ ] release-please PR をマージすると \`v0.1.0\` tag、GitHub Release、CHANGELOG.md、\`v0\` tag が生成される
EOF
)"
```

Expected: PR URL が出力される

### Merge and Verification

- [ ] **Step 1.10: PR をマージ (ユーザー操作)**

ユーザーが PR をレビュー、Ready for review に変更してマージする。

完了の判断: `gh pr view --json state -q .state` が `MERGED` を返す。

- [ ] **Step 1.11: release-please PR が自動生成されたことを確認**

マージ完了から 1-2 分待ち、以下を実行:

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
gh pr list --search "in:title release-please" --json number,title,headRefName --jq '.[]'
```

Expected: タイトルが `chore: release ...` または `chore: release 0.1.0` のような PR が 1 件出力される。headRefName は `release-please--branches--main` 系。

出ない場合は `gh run list --workflow=release.yml --limit 1` で Release workflow の実行結果を確認、失敗していればログを取得して原因調査。

- [ ] **Step 1.12: release-please PR をマージ (ユーザー操作)**

ユーザーが release-please PR をレビュー、マージする。

完了の判断: `gh pr view <PR番号> --json state -q .state` が `MERGED` を返す。

- [ ] **Step 1.13: tag / Release / CHANGELOG / v0 tag を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git fetch origin --tags --quiet
echo "--- tags ---"
git tag --list "v*" --sort=-v:refname | head -5
echo "--- v0 points to ---"
git rev-parse v0 2>/dev/null || echo "v0 NOT FOUND"
git rev-parse v0.1.0 2>/dev/null || echo "v0.1.0 NOT FOUND"
echo "--- v0 == v0.1.0 ---"
[ "$(git rev-parse v0)" = "$(git rev-parse v0.1.0)" ] && echo OK || echo NG
echo "--- GitHub Release ---"
gh release view v0.1.0 --json tagName,isDraft,isPrerelease --jq '.'
echo "--- CHANGELOG.md ---"
git show origin/main:CHANGELOG.md 2>/dev/null | head -10
```

Expected:
- tags に `v0` と `v0.1.0` が含まれる
- `v0` と `v0.1.0` が同じコミットを指す (`OK`)
- GitHub Release の `isDraft: false` (published 状態)
- `CHANGELOG.md` が存在し、`## [0.1.0]` または `## 0.1.0` で始まる

いずれかが NG なら Task 1 を完了とせず、原因を調査してから次の Task に進む。

- [ ] **Step 1.14: worktree をクリーンアップ**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git worktree remove .claude/worktrees/feat-release-please-rollout
git worktree prune
```

Expected: no error。worktree ディレクトリが削除される。

---

## Task 2: platform に release-please を導入

**Files:**
- Create: `platform/.github/workflows/release.yml`

> **Note:** platform リポの worktree は本実装計画の作成に使用中 (`.claude/worktrees/feat-release-please-rollout/`)。実装作業は同じ worktree 内で続行する (新規に worktree を作る必要はない)。

### Setup

- [ ] **Step 2.1: platform の最新を取得**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
git fetch origin main --quiet
```

Expected: no output

- [ ] **Step 2.2: bootstrap-sha を取得して環境変数に保存**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
BOOTSTRAP_SHA=$(git rev-parse origin/main)
echo "BOOTSTRAP_SHA=$BOOTSTRAP_SHA"
```

Expected: 40 桁の SHA

### Implementation

- [ ] **Step 2.3: `.github/workflows/release.yml` を作成**

Files: `platform/.claude/worktrees/feat-release-please-rollout/.github/workflows/release.yml`

Step 2.2 で取得した `$BOOTSTRAP_SHA` を実値で埋め込んだ状態で以下の内容を作成する。

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
          release-type: simple
          bootstrap-sha: <Step 2.2 で取得した SHA を実値で埋め込む>
          initial-version: "0.1.0"
```

major tag の force update ステップは含めない (platform は他リポから参照されないため)。

- [ ] **Step 2.4: actionlint で workflow を静的検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release.yml
```

Expected: no output (exit 0)

- [ ] **Step 2.5: bootstrap-sha が実値で埋め込まれていることを確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
grep -E "bootstrap-sha:\s*[a-f0-9]{40}" .github/workflows/release.yml
```

Expected: 1 行マッチ。プレースホルダーが残っていれば NG。

### Commit and PR

- [ ] **Step 2.6: commit**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
git add .github/workflows/release.yml
git commit -s -m "$(cat <<'EOF'
feat(ci): release-please workflow を追加

deploy-actions と同パターンで GitHub Release / CHANGELOG / semver tag を
自動生成する。bootstrap-sha は導入 PR のベース main HEAD に固定し、
初回 release CHANGELOG をこの PR のコミット 1 件に閉じ込める。

Spec: docs/superpowers/specs/2026-05-16-release-please-rollout-design.md
EOF
)"
```

Expected: 1 file changed, 23 insertions

- [ ] **Step 2.7: push と PR (draft) 作成**

> **Note:** 同じブランチに spec / plan の docs commit が既に乗っている。Task 2 の commit はそれらに追加で乗る形になる。PR は workflow 追加 + spec / plan の docs commit がまとまった 1 PR。

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-rollout
git push -u origin HEAD
gh pr create --draft --title "feat(ci): release-please workflow を追加" --body "$(cat <<'EOF'
## Summary

- \`googleapis/release-please-action@v5\` を main への push で起動
- \`release-type: simple\`、初期バージョン \`0.1.0\`
- major tag は持たない (platform は他リポから参照されない)
- \`bootstrap-sha\` は導入 PR のベース main HEAD に固定
- 併せて Phase 1 全体の spec / plan ドキュメントも含む

## Spec / Plan

- \`docs/superpowers/specs/2026-05-16-release-please-rollout-design.md\`
- \`docs/superpowers/plans/2026-05-16-release-please-rollout.md\`

## Test plan

- [ ] CI (lint-actions / semantic-pull-request) が通る
- [ ] マージ後、release-please PR が自動生成される
- [ ] release-please PR をマージすると \`v0.1.0\` tag、GitHub Release、CHANGELOG.md が生成される
EOF
)"
```

Expected: PR URL が出力される

### Merge and Verification

- [ ] **Step 2.8: PR をマージ (ユーザー操作)**

完了の判断: `gh pr view --json state -q .state` が `MERGED` を返す。

- [ ] **Step 2.9: release-please PR が自動生成されたことを確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
gh pr list --search "in:title release-please" --json number,title,headRefName --jq '.[]'
```

Expected: タイトルが `chore: release ...` の PR が 1 件出力される。

- [ ] **Step 2.10: release-please PR をマージ (ユーザー操作)**

完了の判断: `gh pr view <PR番号> --json state -q .state` が `MERGED` を返す。

- [ ] **Step 2.11: tag / Release / CHANGELOG を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin --tags --quiet
echo "--- tags ---"
git tag --list "v*" --sort=-v:refname | head -5
echo "--- GitHub Release ---"
gh release view v0.1.0 --json tagName,isDraft,isPrerelease --jq '.'
echo "--- CHANGELOG.md ---"
git show origin/main:CHANGELOG.md 2>/dev/null | head -10
```

Expected:
- tags に `v0.1.0` が含まれる (platform では `v0` major tag は作らない)
- GitHub Release の `isDraft: false`
- `CHANGELOG.md` が存在し、`## [0.1.0]` または `## 0.1.0` で始まる

- [ ] **Step 2.12: worktree をクリーンアップ**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-release-please-rollout
git worktree prune
```

Expected: no error

---

## Task 3: monorepo に release-please を導入 (manifest mode)

**Files:**
- Create: `monorepo/.github/workflows/release.yml`
- Create: `monorepo/release-please-config.json`
- Create: `monorepo/.release-please-manifest.json`

### Setup

- [ ] **Step 3.1: monorepo の worktree exclude を確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
grep -q "^/.claude/worktrees/" .git/info/exclude && echo OK || echo MISSING
```

Expected: `OK`

`MISSING` が返ったら `.git/info/exclude` に `/.claude/worktrees/` を追加してから続行。

- [ ] **Step 3.2: monorepo の最新を取得**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin main --quiet
```

Expected: no output

- [ ] **Step 3.3: worktree とブランチを作成**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree add -b feat/release-please-rollout .claude/worktrees/feat-release-please-rollout origin/main
```

Expected: `Preparing worktree (new branch 'feat/release-please-rollout')`

- [ ] **Step 3.4: bootstrap-sha を取得して環境変数に保存**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
BOOTSTRAP_SHA=$(git rev-parse origin/main)
echo "BOOTSTRAP_SHA=$BOOTSTRAP_SHA"
```

Expected: 40 桁の SHA

### Implementation

- [ ] **Step 3.5: `release-please-config.json` を作成**

Files: `monorepo/.claude/worktrees/feat-release-please-rollout/release-please-config.json`

Step 3.4 で取得した `$BOOTSTRAP_SHA` を `bootstrap-sha` に実値で埋め込んだ状態で以下の内容を作成する。

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<Step 3.4 で取得した SHA を実値で埋め込む>",
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

- [ ] **Step 3.6: `.release-please-manifest.json` を作成**

Files: `monorepo/.claude/worktrees/feat-release-please-rollout/.release-please-manifest.json`

```json
{
  "services/monolith": "0.1.0",
  "services/frontend": "0.1.0"
}
```

- [ ] **Step 3.7: `.github/workflows/release.yml` を作成**

Files: `monorepo/.claude/worktrees/feat-release-please-rollout/.github/workflows/release.yml`

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
        with:
          token: ${{ steps.app-token.outputs.token }}
```

manifest mode のため `release-type` / `bootstrap-sha` / `initial-version` は `with:` に書かない (config / manifest ファイルが代替)。

- [ ] **Step 3.8: actionlint で workflow を静的検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release.yml
```

Expected: no output (exit 0)

- [ ] **Step 3.9: JSON ファイルの構文を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
jq empty release-please-config.json && echo "config OK"
jq empty .release-please-manifest.json && echo "manifest OK"
```

Expected:
```
config OK
manifest OK
```

- [ ] **Step 3.10: config の整合性を確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
echo "--- config packages ---"
jq -r '.packages | keys[]' release-please-config.json | sort
echo "--- manifest packages ---"
jq -r 'keys[]' .release-please-manifest.json | sort
echo "--- bootstrap-sha ---"
jq -r '."bootstrap-sha"' release-please-config.json | grep -E "^[a-f0-9]{40}$" && echo "bootstrap-sha OK"
```

Expected:
- config packages と manifest packages が一致 (`services/frontend` / `services/monolith` の 2 行ずつ)
- bootstrap-sha が 40 桁の SHA で `bootstrap-sha OK` が出力される

### Commit and PR

- [ ] **Step 3.11: commit**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
git add .github/workflows/release.yml release-please-config.json .release-please-manifest.json
git commit -s -m "$(cat <<'EOF'
feat(ci): release-please workflow を manifest mode で追加

services/monolith と services/frontend を独立 component として管理する
manifest mode。各 component は release-type: simple、初期バージョン 0.1.0。
tag は monolith-v0.X.0 / frontend-v0.X.0 形式。

bootstrap-sha は導入 PR のベース main HEAD に固定し、初回 release CHANGELOG
をこの PR のコミット 1 件に閉じ込める。

Spec: panicboat/platform docs/superpowers/specs/2026-05-16-release-please-rollout-design.md
EOF
)"
```

Expected: 3 files changed (release.yml, release-please-config.json, .release-please-manifest.json)

- [ ] **Step 3.12: push と PR (draft) 作成**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-release-please-rollout
git push -u origin HEAD
gh pr create --draft --title "feat(ci): release-please workflow を manifest mode で追加" --body "$(cat <<'EOF'
## Summary

- \`googleapis/release-please-action@v5\` を manifest mode で導入
- monolith / frontend を独立 component として管理 (separate-pull-requests: true)
- 各 component の初期バージョン 0.1.0、release-type: simple (コードベースの version ファイルは更新しない)
- tag 形式: \`monolith-v0.X.0\` / \`frontend-v0.X.0\` (Phase 2 で Flux ImagePolicy のソースとして使用予定)
- \`bootstrap-sha\` は導入 PR のベース main HEAD に固定

## Spec

panicboat/platform リポの \`docs/superpowers/specs/2026-05-16-release-please-rollout-design.md\` を参照。

## Test plan

- [ ] CI (lint-actions / semantic-pull-request) が通る
- [ ] マージ後、release-please PR が monolith / frontend それぞれ独立に生成される (初回は 2 PR)
- [ ] 各 release-please PR をマージすると、対応する \`monolith-v0.1.0\` / \`frontend-v0.1.0\` tag、GitHub Release、CHANGELOG.md (services/monolith/CHANGELOG.md / services/frontend/CHANGELOG.md) が生成される
EOF
)"
```

Expected: PR URL が出力される

### Merge and Verification

- [ ] **Step 3.13: PR をマージ (ユーザー操作)**

完了の判断: `gh pr view --json state -q .state` が `MERGED` を返す。

- [ ] **Step 3.14: release-please PR が monolith / frontend それぞれ生成されたことを確認**

マージ完了から 1-2 分待ち、以下を実行:

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
gh pr list --search "in:title release-please" --json number,title,headRefName --jq '.[]'
```

Expected: 2 件の PR (monolith 用と frontend 用)。タイトル例:
- `chore(monolith): release 0.1.0`
- `chore(frontend): release 0.1.0`

1 件しか出ない / 0 件の場合は `gh run list --workflow=release.yml --limit 1` で workflow 実行結果を確認、ログを取得して原因調査。

- [ ] **Step 3.15: monolith の release-please PR をマージ (ユーザー操作)**

完了の判断: 該当 PR の state が `MERGED`。

- [ ] **Step 3.16: frontend の release-please PR をマージ (ユーザー操作)**

完了の判断: 該当 PR の state が `MERGED`。

- [ ] **Step 3.17: tag / Release / CHANGELOG を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin --tags --quiet
echo "--- tags ---"
git tag --list "monolith-v*" "frontend-v*" --sort=-v:refname
echo "--- GitHub Release (monolith) ---"
gh release view monolith-v0.1.0 --json tagName,isDraft,isPrerelease --jq '.'
echo "--- GitHub Release (frontend) ---"
gh release view frontend-v0.1.0 --json tagName,isDraft,isPrerelease --jq '.'
echo "--- CHANGELOG (monolith) ---"
git show origin/main:services/monolith/CHANGELOG.md 2>/dev/null | head -10
echo "--- CHANGELOG (frontend) ---"
git show origin/main:services/frontend/CHANGELOG.md 2>/dev/null | head -10
echo "--- manifest ---"
git show origin/main:.release-please-manifest.json
```

Expected:
- tags に `monolith-v0.1.0` と `frontend-v0.1.0` が含まれる
- 両 GitHub Release が `isDraft: false`
- `services/monolith/CHANGELOG.md` と `services/frontend/CHANGELOG.md` がそれぞれ存在
- `.release-please-manifest.json` の値が `0.1.0` のまま (初回 release では bump されない可能性あり、release-please の挙動に依存)

`.release-please-manifest.json` が release-please PR のマージで `0.1.0` に書き換わっていれば、それは正常 (release-please が自身で manifest を更新する)。

- [ ] **Step 3.18: worktree をクリーンアップ**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree remove .claude/worktrees/feat-release-please-rollout
git worktree prune
```

Expected: no error

---

## Post-Implementation Checks

3 Task すべてが完了した後、以下を確認する。

- [ ] **Step 4.1: deploy-actions を含む 4 リポジトリで release-please が稼働している**

Run (各リポジトリで):
```bash
for repo in deploy-actions panicboat-actions platform monorepo; do
  echo "=== $repo ==="
  cd /Users/takanokenichi/GitHub/panicboat/$repo
  ls .github/workflows/release.yml 2>/dev/null && echo "  release.yml: OK" || echo "  release.yml: MISSING"
  cd - > /dev/null
done
```

Expected: 4 リポジトリすべて `release.yml: OK`

- [ ] **Step 4.2: Renovate が release-please-action / create-github-app-token / checkout を更新対象にしていることを確認**

Run:
```bash
for repo in panicboat-actions platform monorepo; do
  echo "=== $repo ==="
  cd /Users/takanokenichi/GitHub/panicboat/$repo
  grep -E "helpers:pinGitHubActionDigests|github-actions" .github/renovate.json | head -5
  cd - > /dev/null
done
```

Expected: 各リポジトリで `helpers:pinGitHubActionDigests` を extend している (deploy-actions と同じ設定)。これにより Renovate が GitHub Action の SHA を自動更新する。

含まれていない場合は Renovate の設定を別途検討する (本実装計画のスコープ外、別 PR で対応)。

- [ ] **Step 4.3: panicboat-actions の v0 tag を実 PR で参照できることを確認 (smoke test)**

任意の他リポジトリの workflow で `uses: panicboat/panicboat-actions/claude-run@v0` のような参照が解決できることを確認する (実装計画上は確認のみ、変更は不要)。

Run:
```bash
git ls-remote --tags https://github.com/panicboat/panicboat-actions.git refs/tags/v0
```

Expected: `<SHA>\trefs/tags/v0` の行が 1 行出力される。

---

## Notes

- 3 Task はリポジトリが独立しているため並列実行可能。subagent-driven-development で並列ディスパッチも検討可。
- 各 Task の Step 1.10 / 2.8 / 3.13 (導入 PR のマージ) と Step 1.12 / 2.10 / 3.15-3.16 (release-please PR のマージ) はユーザー操作。実装エージェントはここで停止し、ユーザーのマージ完了を待ってから検証ステップに進む。
- branch protection の関係で release-please PR がマージできない場合は、GitHub App に必要な権限 (Contents: write / Pull requests: write / Workflows: write) が付与されていることを確認する。
- 初回 release の CHANGELOG は導入 PR の commit 1 件のみのため貧弱になる。これは仕様 (本格的なリリースノートは 2 回目以降から充実)。
