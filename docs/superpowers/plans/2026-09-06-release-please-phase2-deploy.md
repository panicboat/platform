# release-please Phase 2 Deploy Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** production への deploy を release-please の `release: published` イベント起点に切り替える(aws は component ごとの terragrunt apply、kubernetes は Flux の追従先タグ切り替え)。あわせて #884 以降ライブになっている production 誤爆リスクを止める。

**Architecture:** `release-please-config.json` を manifest mode に切り替え、`aws/{service}` 11 component + `kubernetes` 1 component を管理する。新規 workflow `release-deploy.yml`(`on: release: types: [published]`)が tag 名から component を特定し、aws component は label-resolver を経由せず直接 `reusable--terragrunt-executor.yaml` を呼び出し、kubernetes component は `kubernetes-production` タグを force-update して Flux の追従先を進める。既存の自動 push トリガー(`auto-label--deploy-trigger.yaml`)は `environments: master` を明示して production を対象外にする。

**Tech Stack:**
- `googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7` (v5、既存 pin を継続使用)
- `mikefarah/yq`(aqua 経由、新規追加)
- 既存 GitHub App(`vars.APP_ID` / `secrets.APP_PRIVATE_KEY`)
- 既存 `reusable--terragrunt-executor.yaml`

**Spec:** `docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md`

## Global Constraints

- production 環境のみが対象。`develop` は out of scope(常時起動していないため)
- `github/{service}` は対象外(`master` 専用、`production` ディレクトリを持たない)
- 既存の `master` 向け自動パイプラインの挙動は変更しない(production のみ切り離す)
- GitHub Actions の `uses:` は SHA-pin する(このリポジトリ全体の既存方針)
- commit は Conventional Commits + `-s`(sign-off)
- 初回 push は `git push -u origin HEAD`
- PR は `gh pr create --draft` で作成
- `Co-Authored-By` は付けない
- worktree: `.claude/worktrees/feat-release-please-phase2-deploy`(作成済み)、branch: `feat/release-please-phase2-deploy`(作成済み、`origin/main` の `83d44bfe1f5840da0fe6b9834f5d7d727d68cb4a` から分岐)

---

## File Structure

| File | 種別 | 役割 |
|---|---|---|
| `.github/workflows/auto-label--deploy-trigger.yaml` | Modify | Label Resolver 呼び出しに `environments: master` を明示し、production を対象外にする |
| `aqua.yaml` | Modify | `mikefarah/yq` を追加(workflow-config.yaml の値取得に使う) |
| `release-please-config.json` | Create | manifest mode の component 定義(aws 11 + kubernetes 1) |
| `.release-please-manifest.json` | Create | 各 component の現在バージョン state |
| `.github/workflows/release.yml` | Modify | non-manifest(`release-type: simple`)から manifest mode 呼び出しに変更 |
| `.github/workflows/release-deploy.yml` | Create | `release: published` 起点で aws component は terragrunt apply、kubernetes component は追従タグを force-update |
| `kubernetes/clusters/production/flux-system/gotk-sync.yaml` | Modify | `GitRepository.spec.ref` を `branch: main` から `tag: kubernetes-production` に切り替え |

既存ファイルへの変更はなし(`workflow-config.yaml` の `production` エントリは #884 で既に有効化済み、本 plan での変更は不要)。

---

## Task 1: production 誤爆リスクの解消(最優先)

**Files:**
- Modify: `.github/workflows/auto-label--deploy-trigger.yaml`

**Interfaces:**
- 変更なし(既存の label-resolver composite action の呼び出しに input を1つ追加するのみ)

### Setup

- [ ] **Step 1.1: 現状を確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
grep -n "environments:" .github/workflows/auto-label--deploy-trigger.yaml
```

Expected: no output(`environments:` input がまだ存在しないことを確認)

### Implementation

- [ ] **Step 1.2: `environments: master` を追加**

`.github/workflows/auto-label--deploy-trigger.yaml` の Label Resolver ステップを以下のように変更する。

変更前:
```yaml
      - name: Label Resolver
        id: resolver
        uses: panicboat/deploy-actions/label-resolver@0f0a02d87678cf779217ca2056218e2315bc1c61 # refactor/infrastructure-layout (panicboat/deploy-actions#307) — re-point to the v1.3.0 release SHA before merge
        with:
          repository: ${{ github.repository }}
          pr-number: ${{ steps.pr-info.outputs.number }}
          github-token: ${{ steps.app-token.outputs.token }}
          config-path: 'workflow-config.yaml'
```

変更後:
```yaml
      - name: Label Resolver
        id: resolver
        uses: panicboat/deploy-actions/label-resolver@0f0a02d87678cf779217ca2056218e2315bc1c61 # refactor/infrastructure-layout (panicboat/deploy-actions#307) — re-point to the v1.3.0 release SHA before merge
        with:
          repository: ${{ github.repository }}
          pr-number: ${{ steps.pr-info.outputs.number }}
          github-token: ${{ steps.app-token.outputs.token }}
          config-path: 'workflow-config.yaml'
          environments: 'master'
```

- [ ] **Step 1.3: actionlint で検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/auto-label--deploy-trigger.yaml
```

Expected: no output(exit 0)

### Commit

- [ ] **Step 1.4: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add .github/workflows/auto-label--deploy-trigger.yaml
git commit -s -m "$(cat <<'EOF'
fix(ci): pin auto deploy-trigger to master environment only

#884 で workflow-config.yaml の production を有効化したことにより、
label-resolver が environments 未指定時に production も対象にしてしまい、
master のみの変更でも production へ apply されうる状態になっていた。
production 配下しか持たない service では既に実害はないが、master と
production の両方を持つ github-oidc-auth は誤爆しうるため明示的に固定する。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

> **Note:** この Task は独立して安全にマージ可能。他の Task を待たず先に PR 化・マージしたい場合は、ここで一旦 push して単独 PR にしてよい(Task 2 以降とは無関係)。

---

## Task 2: yq を CI ツールチェーンに追加

**Files:**
- Modify: `aqua.yaml`

**Interfaces:**
- Produces: CI 上で `yq` コマンドが使えるようになる(Task 6 で使用)

### Implementation

- [ ] **Step 2.1: `aqua.yaml` に `mikefarah/yq` を追加**

`aqua.yaml` の `packages:` に以下を追加する(既存エントリの並びの末尾に追加、renovate が追跡できるよう aqua 標準の書式に合わせる)。

```yaml
  - name: mikefarah/yq@v4.44.3
```

追加後の `packages:` セクション全体は以下のようになる。

```yaml
packages:
  - name: helmfile/helmfile@v0.169.2
  - name: helm/helm@v3.17.3
  - name: kubernetes-sigs/kustomize@kustomize/v5.6.0
  - name: nektos/act@v0.2.87
  - name: rhysd/actionlint@v1.7.7
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
  - name: mikefarah/yq@v4.44.3
```

- [ ] **Step 2.2: aqua.yaml の構文を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
python3 -c "import yaml,sys; yaml.safe_load(open('aqua.yaml'))" && echo "aqua.yaml OK"
```

Expected: `aqua.yaml OK`

### Commit

- [ ] **Step 2.3: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add aqua.yaml
git commit -s -m "$(cat <<'EOF'
chore(aqua): add yq for workflow-config.yaml value extraction

release-deploy.yml が production の iam_role_apply / aws_region を
workflow-config.yaml から取得するために使う。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

---

## Task 3: release-please を manifest mode に切り替える(設定ファイル)

**Files:**
- Create: `release-please-config.json`
- Create: `.release-please-manifest.json`

**Interfaces:**
- Produces: 12 個の release-please component(`aws/alb` ... `aws/vpc`、`kubernetes`)。tag 形式は `{component}-vX.Y.Z`

### Implementation

- [ ] **Step 3.1: 対象 aws service を実ディレクトリで再確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
for d in aws/*/; do
  svc=$(basename "$d")
  [ -d "${d}production" ] && echo "$svc: production あり"
done
```

Expected: 以下11行が出力される(spec のスナップショットと一致することを確認)
```
alb: production あり
eks: production あり
eks-holmesgpt: production あり
eks-karpenter: production あり
eks-logs: production あり
eks-metrics: production あり
eks-secrets: production あり
eks-traces: production あり
github-oidc-auth: production あり
iam-service-linked-roles: production あり
vpc: production あり
```

差分があれば(directory が増減していれば)後続の JSON の component 一覧をこの実測結果に合わせる。

- [ ] **Step 3.2: `release-please-config.json` を作成**

Files: `release-please-config.json`

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "83d44bfe1f5840da0fe6b9834f5d7d727d68cb4a",
  "separate-pull-requests": true,
  "packages": {
    "aws/alb": { "release-type": "simple", "component": "alb", "include-component-in-tag": true },
    "aws/eks": { "release-type": "simple", "component": "eks", "include-component-in-tag": true },
    "aws/eks-holmesgpt": { "release-type": "simple", "component": "eks-holmesgpt", "include-component-in-tag": true },
    "aws/eks-karpenter": { "release-type": "simple", "component": "eks-karpenter", "include-component-in-tag": true },
    "aws/eks-logs": { "release-type": "simple", "component": "eks-logs", "include-component-in-tag": true },
    "aws/eks-metrics": { "release-type": "simple", "component": "eks-metrics", "include-component-in-tag": true },
    "aws/eks-secrets": { "release-type": "simple", "component": "eks-secrets", "include-component-in-tag": true },
    "aws/eks-traces": { "release-type": "simple", "component": "eks-traces", "include-component-in-tag": true },
    "aws/github-oidc-auth": { "release-type": "simple", "component": "github-oidc-auth", "include-component-in-tag": true },
    "aws/iam-service-linked-roles": { "release-type": "simple", "component": "iam-service-linked-roles", "include-component-in-tag": true },
    "aws/vpc": { "release-type": "simple", "component": "vpc", "include-component-in-tag": true },
    "kubernetes": { "release-type": "simple", "component": "kubernetes", "include-component-in-tag": true }
  }
}
```

- [ ] **Step 3.3: `.release-please-manifest.json` を作成**

Files: `.release-please-manifest.json`

```json
{
  "aws/alb": "0.1.0",
  "aws/eks": "0.1.0",
  "aws/eks-holmesgpt": "0.1.0",
  "aws/eks-karpenter": "0.1.0",
  "aws/eks-logs": "0.1.0",
  "aws/eks-metrics": "0.1.0",
  "aws/eks-secrets": "0.1.0",
  "aws/eks-traces": "0.1.0",
  "aws/github-oidc-auth": "0.1.0",
  "aws/iam-service-linked-roles": "0.1.0",
  "aws/vpc": "0.1.0",
  "kubernetes": "0.1.0"
}
```

- [ ] **Step 3.4: JSON 構文と整合性を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
jq empty release-please-config.json && echo "config OK"
jq empty .release-please-manifest.json && echo "manifest OK"
echo "--- config packages ---"
jq -r '.packages | keys[]' release-please-config.json | sort
echo "--- manifest packages ---"
jq -r 'keys[]' .release-please-manifest.json | sort
```

Expected:
- `config OK` / `manifest OK`
- 2つの package 一覧(12件ずつ)が完全に一致する

### Commit

- [ ] **Step 3.5: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add release-please-config.json .release-please-manifest.json
git commit -s -m "$(cat <<'EOF'
feat(ci): switch release-please to manifest mode

aws/{service}(production ディレクトリを持つ11 service)と kubernetes を
それぞれ独立 component として管理する。tag は {component}-vX.Y.Z 形式
(include-component-in-tag: true)。bootstrap-sha は本ブランチの分岐元
main HEAD に固定し、既存 CHANGELOG.md の履歴とは独立した起点にする。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 2 files changed

---

## Task 4: release.yml を manifest mode 呼び出しに変更

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: Task 3 で作成した `release-please-config.json` / `.release-please-manifest.json`

### Implementation

- [ ] **Step 4.1: `release-type: simple` を削除し manifest mode 呼び出しにする**

変更前:
```yaml
      - uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7 # v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          release-type: simple
```

変更後:
```yaml
      - uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7 # v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
```

(`release-please-config.json` / `.release-please-manifest.json` が存在するため `release-type` の指定は不要。Phase 1 の monorepo 展開時と同じパターン。)

- [ ] **Step 4.2: actionlint で検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release.yml
```

Expected: no output(exit 0)

### Commit

- [ ] **Step 4.3: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add .github/workflows/release.yml
git commit -s -m "$(cat <<'EOF'
feat(ci): drive release.yml from manifest config

release-please-config.json / .release-please-manifest.json の追加に伴い、
with: の release-type 指定を削除し manifest mode に委譲する。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

---

## Task 5: 旧 release PR #422 を close する

**Files:** なし(GitHub 上の操作)

manifest mode への切り替えにより、非 manifest 時代の単一 component release PR(#422, `chore(main): release 1.0.0`)は成立しなくなる。

- [ ] **Step 5.1: #422 の現状を確認**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
gh pr view 422 --json number,title,state,headRefName
```

Expected: `"state": "OPEN"`, `"headRefName": "release-please--branches--main"`

- [ ] **Step 5.2: close する(ユーザー確認推奨)**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
gh pr close 422 --comment "release-please を manifest mode に切り替えるため close します。以降は component ごとに release PR が生成されます。Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md"
```

Expected: `Closed pull request #422 ...`

> **Note:** #422 の4ヶ月分の変更履歴は CHANGELOG.md(`v0.1.0` リリース以降の commit)としては失われるが、Git の commit history 自体には残るため追跡は可能。close は破壊的操作(GitHub 上で他者に見える状態変更)のため、実行前にユーザーに確認する。

---

## Task 6: release-deploy.yml(aws 経路)を作成

**Files:**
- Create: `.github/workflows/release-deploy.yml`

**Interfaces:**
- Consumes: `workflow-config.yaml` の `environments[] | select(.environment == "production")`、`reusable--terragrunt-executor.yaml` の `workflow_call` インターフェース(`service-name`, `environment`, `action-type`, `iam-role`, `aws-region`, `working-directory`, `app-id`, `secrets.private-key`)
- Produces: `parse-tag` job の outputs `component` / `is-aws` / `is-kubernetes`(Task 7 で kubernetes job から参照)

### Implementation

- [ ] **Step 6.1: `release-deploy.yml` を作成(parse-tag + resolve-aws-config + deploy-aws)**

Files: `.github/workflows/release-deploy.yml`

```yaml
name: Release Deploy

on:
  release:
    types: [published]

permissions:
  id-token: write
  contents: write

jobs:
  parse-tag:
    name: 'Parse Release Tag'
    runs-on: ubuntu-latest
    outputs:
      component: ${{ steps.parse.outputs.component }}
      is-aws: ${{ steps.parse.outputs.is-aws }}
      is-kubernetes: ${{ steps.parse.outputs.is-kubernetes }}
    steps:
      - name: Parse component from tag
        id: parse
        env:
          TAG_NAME: ${{ github.event.release.tag_name }}
        run: |
          set -euo pipefail
          if [[ "$TAG_NAME" =~ ^([a-z0-9-]+)-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            component="${BASH_REMATCH[1]}"
          else
            echo "Tag '$TAG_NAME' does not match <component>-vX.Y.Z, skipping"
            echo "component=" >> "$GITHUB_OUTPUT"
            echo "is-aws=false" >> "$GITHUB_OUTPUT"
            echo "is-kubernetes=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "component=$component" >> "$GITHUB_OUTPUT"
          case "$component" in
            alb|eks|eks-holmesgpt|eks-karpenter|eks-logs|eks-metrics|eks-secrets|eks-traces|github-oidc-auth|iam-service-linked-roles|vpc)
              echo "is-aws=true" >> "$GITHUB_OUTPUT"
              echo "is-kubernetes=false" >> "$GITHUB_OUTPUT"
              ;;
            kubernetes)
              echo "is-aws=false" >> "$GITHUB_OUTPUT"
              echo "is-kubernetes=true" >> "$GITHUB_OUTPUT"
              ;;
            *)
              echo "Unknown component '$component', skipping"
              echo "is-aws=false" >> "$GITHUB_OUTPUT"
              echo "is-kubernetes=false" >> "$GITHUB_OUTPUT"
              ;;
          esac

  resolve-aws-config:
    name: 'Resolve Production AWS Config'
    needs: parse-tag
    if: needs.parse-tag.outputs.is-aws == 'true'
    runs-on: ubuntu-latest
    outputs:
      aws-region: ${{ steps.config.outputs.aws-region }}
      iam-role-apply: ${{ steps.config.outputs.iam-role-apply }}
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.release.tag_name }}

      - name: Setup aqua
        uses: aquaproj/aqua-installer@96a9bc20066c5bf5e275b41019cfc165b25f4e2e # v2.48.2
        with:
          aqua_version: v2.48.2

      - name: Resolve production config
        id: config
        run: |
          set -euo pipefail
          aws_region=$(yq '.environments[] | select(.environment == "production") | .stacks.terragrunt.aws_region' workflow-config.yaml)
          iam_role_apply=$(yq '.environments[] | select(.environment == "production") | .stacks.terragrunt.iam_role_apply' workflow-config.yaml)
          echo "aws-region=$aws_region" >> "$GITHUB_OUTPUT"
          echo "iam-role-apply=$iam_role_apply" >> "$GITHUB_OUTPUT"

  deploy-aws:
    name: 'Deploy AWS (${{ needs.parse-tag.outputs.component }})'
    needs: [parse-tag, resolve-aws-config]
    uses: ./.github/workflows/reusable--terragrunt-executor.yaml
    with:
      service-name: ${{ needs.parse-tag.outputs.component }}
      environment: production
      action-type: apply
      iam-role: ${{ needs.resolve-aws-config.outputs.iam-role-apply }}
      aws-region: ${{ needs.resolve-aws-config.outputs.aws-region }}
      working-directory: aws/${{ needs.parse-tag.outputs.component }}/production
      app-id: ${{ vars.APP_ID }}
    secrets:
      private-key: ${{ secrets.APP_PRIVATE_KEY }}
```

- [ ] **Step 6.2: actionlint で検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release-deploy.yml
```

Expected: no output(exit 0)

### Commit

- [ ] **Step 6.3: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add .github/workflows/release-deploy.yml
git commit -s -m "$(cat <<'EOF'
feat(ci): deploy aws components to production on release published

release タグ名(<component>-vX.Y.Z)から component を直接特定し、
label-resolver / label-dispatcher を経由せず reusable--terragrunt-executor
を直接呼び出す。production への apply は release published イベントのみが
唯一の経路になる。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

---

## Task 7: release-deploy.yml(kubernetes 経路)を追加

**Files:**
- Modify: `.github/workflows/release-deploy.yml`

**Interfaces:**
- Consumes: Task 6 の `parse-tag` job の `is-kubernetes` output

### Implementation

- [ ] **Step 7.1: `deploy-kubernetes` job を追加**

`.github/workflows/release-deploy.yml` の末尾(`deploy-aws` job の後)に以下を追加する。

```yaml

  deploy-kubernetes:
    name: 'Advance Flux Production Tag'
    needs: parse-tag
    if: needs.parse-tag.outputs.is-kubernetes == 'true'
    runs-on: ubuntu-latest
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          app-id: ${{ vars.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}

      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          token: ${{ steps.app-token.outputs.token }}
          ref: ${{ github.event.release.tag_name }}
          fetch-depth: 0

      - name: Force-update kubernetes-production tag
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          set -euo pipefail
          git tag -f kubernetes-production "${{ github.event.release.tag_name }}"
          git push origin kubernetes-production --force
```

- [ ] **Step 7.2: actionlint で検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release-deploy.yml
```

Expected: no output(exit 0)

### Commit

- [ ] **Step 7.3: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add .github/workflows/release-deploy.yml
git commit -s -m "$(cat <<'EOF'
feat(ci): advance Flux production tag on kubernetes release published

panicboat-actions の v0 major tag force-update と同じパターンで、
kubernetes component の release published を kubernetes-production タグの
force-update に変換する。Flux はこのタグを追従先にする(Task 8)。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

---

## Task 8: kubernetes-production タグの初期作成と Flux 追従先の切り替え

**Files:**
- Modify: `kubernetes/clusters/production/flux-system/gotk-sync.yaml`

**Interfaces:** なし

`kubernetes-production` タグが存在しない状態で `gotk-sync.yaml` の `ref` を切り替えると Flux が解決できなくなるため、**タグの作成を先に行う**。

### Setup

- [ ] **Step 8.1: 現在の main HEAD に `kubernetes-production` タグを作成して push**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git fetch origin main --quiet
git tag kubernetes-production origin/main
git push origin kubernetes-production
```

Expected: `* [new tag]         kubernetes-production -> kubernetes-production`

> **Note:** タグの push は他者から見える共有状態への変更。実行前にユーザーに確認する。

### Implementation

- [ ] **Step 8.2: `gotk-sync.yaml` の `ref` を切り替え**

変更前:
```yaml
spec:
  interval: 1m
  url: https://github.com/panicboat/platform.git
  ref:
    branch: main
```

変更後:
```yaml
spec:
  interval: 1m
  url: https://github.com/panicboat/platform.git
  ref:
    tag: kubernetes-production
```

(`kubernetes/clusters/production/flux-system/gotk-sync.yaml` の `GitRepository` リソースのみを変更する。同ファイル内の `Kustomization` リソースは変更しない。)

- [ ] **Step 8.3: YAML 構文を検証**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('kubernetes/clusters/production/flux-system/gotk-sync.yaml')))" && echo "gotk-sync.yaml OK"
```

Expected: `gotk-sync.yaml OK`

### Commit

- [ ] **Step 8.4: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git add kubernetes/clusters/production/flux-system/gotk-sync.yaml
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): track kubernetes-production tag instead of main branch

Flux の GitRepository が main を継続追従する状態から、release published
のたびに Task 7 が force-update する kubernetes-production タグを追従する
状態に切り替える。切り替え時点でタグは main の現在地を指しているため、
反映内容に差分は発生しない。

Spec: docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md
EOF
)"
```

Expected: 1 file changed

---

## Merge and Verification

- [ ] **Step 9.1: push と PR(draft)作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-release-please-phase2-deploy
git push -u origin HEAD
gh pr create --draft --title "feat(ci): release-please phase 2 — production deploy trigger" --body "$(cat <<'EOF'
## Summary

- `auto-label--deploy-trigger.yaml` を `environments: master` に固定し、#884 以降ライブになっていた production 誤爆リスクを解消
- release-please を manifest mode に切り替え、aws 11 component + kubernetes 1 component を管理
- `release-deploy.yml` を新規追加。release published イベントで aws component は terragrunt apply、kubernetes component は `kubernetes-production` タグを force-update
- `gotk-sync.yaml` の Flux 追従先を `main` ブランチから `kubernetes-production` タグに変更

## Spec

`docs/superpowers/specs/2026-09-06-release-please-phase2-deploy-design.md`

## Test plan

- [ ] CI(lint-actions / semantic-pull-request)が通る
- [ ] マージ後、旧 release PR #422 が close 済みであることを確認
- [ ] 11 component + kubernetes の release PR が個別に生成される
- [ ] いずれかの aws component の release PR をマージすると、その component だけ production に terragrunt apply される(他 component・master には影響しない)
- [ ] kubernetes component の release PR をマージすると `kubernetes-production` タグが移動し、Flux が新しい manifest を反映する
EOF
)"
```

Expected: PR URL が出力される

- [ ] **Step 9.2: PR をマージ(ユーザー操作)**

完了の判断: `gh pr view --json state -q .state` が `MERGED` を返す。

- [ ] **Step 9.3: release-please PR が component ごとに生成されたことを確認**

マージ完了から1〜2分待ち、以下を実行:

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
gh pr list --search "in:title release-please" --json number,title,headRefName --jq '.[]'
```

Expected: 最大12件(その時点で pending commits がある component の分だけ)、タイトルは `chore(<component>): release 0.1.0` 形式

- [ ] **Step 9.4: いずれかの aws component をマージして deploy を検証(ユーザー操作)**

component の release PR を1つマージし、release published を待つ(数分):

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
gh run list --workflow=release-deploy.yml --limit 3
```

Expected: 対象 component の `deploy-aws` job が `success` で完了し、他の component・master には影響が出ていないこと(`gh run view <id> --log` で `working_directory: aws/<component>/production` を確認)

- [ ] **Step 9.5: kubernetes component をマージして Flux 反映を検証(ユーザー操作、任意タイミング)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin --tags --quiet
git rev-parse kubernetes-production
git rev-parse origin/main
```

Expected: kubernetes の release PR マージ直後は両者が一致(タグが最新コミットに追従したことを確認)

---

## Notes

- Task 1 は他の Task と独立してマージ可能。#884 由来の誤爆リスクを早く止めたい場合は Task 1 単体を先に PR 化してよい
- Task 5(#422 close)と Task 8.1(タグ push)は GitHub 上の共有状態を変える操作のため、実行前にユーザー確認を挟む
- release-please PR のレビュー・マージ頻度をどう改善するか(auto-merge 導入など)は本 spec の out of scope。今回の設計は「レビューが定期的に回る」ことを前提にしている
