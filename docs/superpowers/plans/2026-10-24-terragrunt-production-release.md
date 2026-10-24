# Terragrunt Production Release Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws/` の terragrunt stack で、`apply_trigger: merge` の環境は main merge で、`apply_trigger: release` の環境はサービスごとの release 公開で apply されるようにする。

**Architecture:** 環境ごとの apply 契機を `workflow-config.yaml` の環境属性 `apply_trigger` で持つ。main push の deploy-trigger は `merge` の target にだけ apply を割り当てる。release 側は `scripts/terragrunt-release/` の bash スクリプトで tag / branch からサービスを求め、`release` の環境を target にして既存の `reusable--terragrunt-executor.yaml` を呼ぶ。release-please は monorepo と同じく `aws/<service>/` ごとの設定ファイルで動かす。

**Tech Stack:** GitHub Actions、panicboat/deploy-actions v2.0.1、release-please-action v5、bash + yq（mikefarah v4）+ jq、actionlint

**Spec:** `docs/superpowers/specs/2026-10-24-terragrunt-production-release-design.md`

## Global Constraints

- commit は `git commit -s`。`Co-Authored-By` を付けない
- commit message・コード内コメントは英語。コメントは 1 行で、Why not だけを書く。現在のタスクへの言及を書かない
- README は見出しが英語。`README-ja.md` の本文は日本語
- GitHub Actions はすべて 40 文字の SHA で固定し、末尾に `# vX.Y.Z` を付ける（`lint-actions.yml` が検査する）。新しい action を追加しない（既存 workflow で使っている SHA だけを使う）
- workflow に環境名（`production`・`develop` など）を書かない。環境の判定は `apply_trigger` の値だけで行う
- `apply_trigger` の値は `merge` か `release` のどちらか
- release tag の形式は `<service>-vX.Y.Z`、release PR の branch は `release-please--branches--main--components--<service>`
- 対象は `aws/` だけ。`github/` と kubernetes の挙動を変えない
- 新しい依存（bats など）を追加しない。テストは plain bash で書く

## Review Focus

- この実装 PR 自体が `aws/<service>/release-please-config.json` を追加するので、Task 3 の検出で 12 サービスに `deploy:<service>` が付く。merge すると `master` / `develop` の stack（`github-oidc-auth` など）が apply される。merge 前に plan を確認し、apply したくなければ最後の push の後にラベルを外す（Task 8）
- `aws/` の module 変更はこれまで apply されていなかったので、`master` の stack（`cost-management`・`route53`）には未 apply の差分が溜まっている可能性がある。最初の自動 apply にそれが含まれる（Task 8 で plan を確認する）
- `github-environment` が空のとき、executor の job が environment なしで今までどおり動くこと（Task 4。`environment:` に空文字を渡す挙動は ASSUMED なので、Task 8 の PR 上の plan で確かめる）
- `terragrunt-shared` stack の target が `deploy-kubernetes` の matrix に流れると、`kubernetes/manifests/null/<service>` で kustomize が失敗する（Task 3 で matrix から除外し、Task 8 で aws と kubernetes を同時に触る PR の挙動を確かめる）
- tag や branch が形式に合わない、またはサービスに `release` 環境のディレクトリがないときは、apply せずに失敗すること（Task 4 のテスト）

---

### Task 1: `apply_trigger` の検証スクリプトとテスト基盤

**Files:**
- Create: `scripts/terragrunt-release/validate-apply-trigger.sh`
- Create: `scripts/terragrunt-release/test.sh`
- Create: `.github/workflows/test-terragrunt-release.yaml`

**Interfaces:**
- Produces: `bash scripts/terragrunt-release/validate-apply-trigger.sh [config_path]`（既定 `workflow-config.yaml`）。`name: terragrunt` の stack の全環境で `apply_trigger` が `merge` か `release` なら exit 0。そうでなければ環境ごとに `::error::stacks[<index>].environments.<env>.apply_trigger must be merge or release (got '<value>')` を stderr に出して exit 1
- Produces: `bash scripts/terragrunt-release/test.sh`。`test_` で始まる関数をすべて実行し、1 つでも失敗すれば exit 1。各テストは `mktemp -d` の fixture ディレクトリに `cd` して実行する。helper は `assert_eq <expected> <actual>` と `assert_fails <command...>`

- [ ] **Step 1: テストを書く**

`test.sh` に helper と次のテストを書く。fixture の `workflow-config.yaml` は heredoc で作る。

```bash
test_validate_accepts_merge_and_release()  # master: merge, production: release → exit 0
test_validate_rejects_missing_trigger()    # production に apply_trigger なし → exit 1、stderr に "environments.production.apply_trigger"
test_validate_rejects_unknown_value()      # apply_trigger: relase → exit 1、stderr に "(got 'relase')"
test_validate_ignores_non_terragrunt_stacks()  # name: kubernetes の stack に environments がなくても exit 0
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: FAIL（`validate-apply-trigger.sh` が存在しない）

- [ ] **Step 3: `validate-apply-trigger.sh` を実装する**

`set -euo pipefail`。`yq -o=json` で config を JSON にし、`jq` で `.stacks | to_entries[] | select(.value.name == "terragrunt")` の各環境を検査する。

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 全テスト PASS、exit 0

- [ ] **Step 5: CI workflow を追加する**

`test-terragrunt-release.yaml` は `on: pull_request` と `push: branches: [main]`、`permissions: contents: read`。job は `actions/checkout`（既存と同じ SHA）の後に `bash scripts/terragrunt-release/test.sh` を実行する。Task 2・Task 5 でこの job に検証コマンドを足す。

Run: `actionlint .github/workflows/test-terragrunt-release.yaml`
Expected: 出力なし、exit 0

- [ ] **Step 6: commit する**

```bash
git add scripts/terragrunt-release .github/workflows/test-terragrunt-release.yaml
git commit -s -m "ci: validate apply_trigger in workflow-config"
```

---

### Task 2: 環境の宣言と main merge の apply を `apply_trigger` で絞る

**Files:**
- Modify: `workflow-config.yaml`
- Modify: `.github/workflows/auto-label--deploy-trigger.yaml`
- Modify: `.github/workflows/test-terragrunt-release.yaml`
- Modify: `scripts/terragrunt-release/test.sh`

**Interfaces:**
- Consumes: Task 1 の `validate-apply-trigger.sh`
- Produces: resolver の target に `apply_trigger` キーが入る（`matrix.target.apply_trigger`）

- [ ] **Step 1: リポジトリの config を検査するテストを書く**

`test.sh` に追加する。fixture ではなくリポジトリの `workflow-config.yaml` を読む（`$REPO_ROOT` を `git rev-parse --show-toplevel` で求める）。

```bash
test_repository_config_is_valid()                 # validate-apply-trigger.sh "$REPO_ROOT/workflow-config.yaml" が exit 0
test_repository_config_never_merges_production()  # terragrunt stack の production.apply_trigger == "release"
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: FAIL（`master` に `apply_trigger` がない）

- [ ] **Step 3: `workflow-config.yaml` の terragrunt stack に環境を宣言する**

- `master`：既存の値に `apply_trigger: merge` を足す
- `develop`：`aws_region: ap-northeast-1`、`iam_role_plan: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-plan-role`、`iam_role_apply: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-apply-role`、`apply_trigger: merge`
- `production`：`aws_region: ap-northeast-1`、`iam_role_plan: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-plan-role`、`iam_role_apply: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-apply-role`、`apply_trigger: release`
- `aws_region` は stack の state bucket の region（`aws/*/root.hcl` の `remote_state.config.region`）に揃える。`aws/github-oidc-auth/develop/env.hcl` の `us-east-1` には合わせない（実装時の判断として PR description に書く）

- [ ] **Step 4: develop と production の role が実在することをユーザーに確認してもらう**

ユーザーに次のコマンドの実行を依頼し、4 つとも `RoleName` が返ることを確認する。返らなければ作業を止めて報告する。

```bash
aws iam get-role --role-name github-oidc-auth-develop-github-actions-plan-role --query Role.Arn   # develop account
aws iam get-role --role-name github-oidc-auth-develop-github-actions-apply-role --query Role.Arn
aws iam get-role --role-name github-oidc-auth-production-github-actions-plan-role --query Role.Arn  # production account
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role --query Role.Arn
```

- [ ] **Step 5: deploy-trigger の apply 割り当てと検証を変える**

- `deploy-trigger` job の先頭に `actions/checkout`（既存 SHA）と `bash scripts/terragrunt-release/validate-apply-trigger.sh` を足す。`Label Resolver` より前に置く
- `deploy-terragrunt` の `action-type` を次にする

```yaml
action-type: ${{ matrix.target.stack == 'terragrunt' && (github.event_name == 'pull_request' && 'plan' || (matrix.target.apply_trigger == 'merge' && 'apply' || '')) || '' }}
```

- [ ] **Step 6: CI に repo config の検証を足し、テストと lint を通す**

`test-terragrunt-release.yaml` の job に `bash scripts/terragrunt-release/validate-apply-trigger.sh` を足す。

Run: `bash scripts/terragrunt-release/test.sh && bash scripts/terragrunt-release/validate-apply-trigger.sh && actionlint`
Expected: 全テスト PASS、actionlint の出力なし

Run（deploy-actions の config 検証。セッションの scratchpad に v2.0.1 の worktree を作る）:
```bash
git -C /Users/takanokenichi/GitHub/panicboat/deploy-actions worktree add "$SCRATCH/deploy-actions-v2" 1ab520e5ef33b8d744982762ffc4e08009a34744
(cd "$SCRATCH/deploy-actions-v2/action-scripts" && bundle install --quiet && \
  WORKFLOW_CONFIG_PATH="$PWD_REPO/workflow-config.yaml" SOURCE_REPO_PATH="$PWD_REPO" \
  bundle exec ruby config-manager/bin/config-manager validate)
```
Expected: 検証成功（エラーなし）。`$SCRATCH` はセッションの scratchpad、`$PWD_REPO` はこの worktree の絶対パス

- [ ] **Step 7: commit する**

```bash
git add workflow-config.yaml .github/workflows scripts/terragrunt-release/test.sh
git commit -s -m "ci: apply only merge-triggered environments on push to main"
```

---

### Task 3: 全環境に効くファイルの変更を検出する

**Files:**
- Modify: `workflow-config.yaml`
- Modify: `.github/workflows/auto-label--deploy-trigger.yaml`
- Modify: `.github/workflows/auto-label--label-dispatcher.yaml`

**Interfaces:**
- Produces: stack `name: terragrunt-shared`（`paths: ["aws/{service}"]`、`attributes: {}`）。resolver はこの stack の target を `stack: terragrunt-shared`、`environment: null`、`working_directory: aws/<service>` で出す。どの job もこの target を実行しない

- [ ] **Step 1: 検出されないことを確認する（失敗の確認）**

`aws/vpc/modules/main.tf` の末尾に空行を足し（commit しない）、v2.0.1 の dispatcher で作業ツリーの変更から検出結果を見る（Task 2 Step 6 の worktree を使う）。作業ツリーの変更が検出対象にならない場合は、一時 commit を作って `--base-ref HEAD~1 --head-ref HEAD` を付ける。

```bash
(cd "$SCRATCH/deploy-actions-v2/action-scripts" && \
  WORKFLOW_CONFIG_PATH="$PWD_REPO/workflow-config.yaml" SOURCE_REPO_PATH="$PWD_REPO" \
  bundle exec ruby label-dispatcher/bin/dispatcher test)
```
Expected: `SERVICES_DETECTED` に `vpc` が含まれない

- [ ] **Step 2: `terragrunt-shared` stack を追加する**

`workflow-config.yaml` の `stacks` に、terragrunt stack の後へ次を足す。

```yaml
  - name: terragrunt-shared
    paths:
      - "aws/{service}"
    attributes: {}
```

- [ ] **Step 3: 検出されることを確認する**

Run: Step 1 と同じコマンド
Expected: `SERVICES_DETECTED: ["vpc"]`、`DEPLOY_LABELS` に `deploy:vpc`。確認後、`git checkout -- aws/vpc/modules/main.tf` で空行を戻す（一時 commit を作った場合は、`git log -1` で一時 commit であることを確かめてから `git reset --hard HEAD~1`）

- [ ] **Step 4: `terragrunt-shared` の target を実行 job から外す**

`auto-label--deploy-trigger.yaml` の `deploy-terragrunt` と `deploy-kubernetes` の matrix に `exclude: - target: { stack: terragrunt-shared }` を足す（`deploy-kubernetes` は既存の `stack: terragrunt` の exclude に並べる）。

- [ ] **Step 5: release PR でラベル付与を走らせない**

`auto-label--label-dispatcher.yaml` の `dispatch-labels` job に `if: ${{ !startsWith(github.head_ref, 'release-please--') }}` を足す。release-please が書き込む `aws/<service>/CHANGELOG.md` が `terragrunt-shared` に一致して全環境の plan が走るのを防ぐため。

- [ ] **Step 6: lint と config 検証を通す**

Run: `actionlint && bash scripts/terragrunt-release/test.sh` と Task 2 Step 6 の config-manager validate
Expected: すべて成功

- [ ] **Step 7: commit する**

```bash
git add workflow-config.yaml .github/workflows
git commit -s -m "ci: detect changes to files shared across terragrunt environments"
```

---

### Task 4: release の target を求めるスクリプトと executor の入力

**Files:**
- Create: `scripts/terragrunt-release/release-service.sh`
- Create: `scripts/terragrunt-release/release-targets.sh`
- Modify: `scripts/terragrunt-release/test.sh`
- Modify: `.github/workflows/reusable--terragrunt-executor.yaml`

**Interfaces:**
- Produces: `bash scripts/terragrunt-release/release-service.sh --tag <tag>` → stdout に `<service>`。`^([a-z0-9-]+)-v[0-9]+\.[0-9]+\.[0-9]+$` に合わなければ `::error::` を出して exit 1
- Produces: `bash scripts/terragrunt-release/release-service.sh --branch <branch>` → `release-please--branches--main--components--<service>` から `<service>` を出す。合わなければ exit 1
- Produces: `bash scripts/terragrunt-release/release-targets.sh <service> [config_path]` → cwd をリポジトリルートとみなし、terragrunt stack の `apply_trigger: release` の環境のうち `aws/<service>/<env>` が存在するものを、compact JSON 配列で stdout に出す。要素のキーは `service`・`environment`・`working_directory`・`aws_region`・`iam_role_plan`・`iam_role_apply`。1 つもなければ `::error::no release targets for <service>` を出して exit 1
- Produces: executor の optional input `ref`（既定 `''`、checkout の `ref:` に渡す）と `github-environment`（既定 `''`、job の `environment:` に渡す）

- [ ] **Step 1: テストを書く**

```bash
test_release_service_parses_tag()             # eks-holmesgpt-v1.2.3 → "eks-holmesgpt"
test_release_service_rejects_root_tag()       # v0.1.0 → exit 1
test_release_service_rejects_flux_tag()       # kubernetes-production → exit 1
test_release_service_parses_branch()          # release-please--branches--main--components--vpc → "vpc"
test_release_service_rejects_root_branch()    # release-please--branches--main → exit 1
test_release_targets_lists_release_envs()     # master: merge / production: release、aws/vpc/{master,production} がある → [{"service":"vpc","environment":"production","working_directory":"aws/vpc/production",...}] の 1 要素だけ
test_release_targets_skips_missing_dirs()     # release 環境が 2 つ、ディレクトリは片方だけ → 1 要素
test_release_targets_fails_without_targets()  # aws/route53/master だけ → exit 1、stderr に "no release targets for route53"
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 追加したテストが FAIL

- [ ] **Step 3: 2 つのスクリプトを実装する**

`release-targets.sh` は `yq -o=json` + `jq` で環境を抜き出し、ディレクトリの存在を bash で確かめてから `jq -c -s` で配列にする。

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 全テスト PASS

- [ ] **Step 5: executor に入力を足す**

`reusable--terragrunt-executor.yaml` に `ref` と `github-environment` を `required: false`、`default: ''` で足す。`execute-terragrunt` job に `environment: ${{ inputs.github-environment }}`、`Checkout` step に `with: ref: ${{ inputs.ref }}` を足す。既存の呼び出し元は変更しない。

Run: `actionlint`
Expected: 出力なし

- [ ] **Step 6: commit する**

```bash
git add scripts/terragrunt-release .github/workflows/reusable--terragrunt-executor.yaml
git commit -s -m "ci: resolve release targets from workflow-config"
```

---

### Task 5: サービスごとの release-please 設定

**Files:**
- Create: `aws/<service>/release-please-config.json` と `aws/<service>/release-please-manifest.json`（`release` 環境のディレクトリを持つ全サービス）
- Create: `scripts/terragrunt-release/check-release-configs.sh`
- Modify: `scripts/terragrunt-release/test.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/test-terragrunt-release.yaml`

**Interfaces:**
- Consumes: Task 4 の `release-targets.sh`（`release` 環境を持つサービスの判定に使う）
- Produces: `bash scripts/terragrunt-release/check-release-configs.sh [config_path]` → cwd をリポジトリルートとみなす。`release-targets.sh` が成功する `aws/*` のサービスの集合と、`aws/*/release-please-config.json` を持つサービスの集合が一致し、各 config の `packages["aws/<service>"].component == "<service>"`、各 manifest に `"aws/<service>"` キーがあれば exit 0。不一致はサービスごとに `::error::` を出して exit 1

- [ ] **Step 1: テストを書く**

```bash
test_check_configs_accepts_matching_set()     # aws/vpc/production と aws/vpc/release-please-{config,manifest}.json → exit 0
test_check_configs_rejects_missing_config()   # aws/eks/production があり config がない → exit 1、stderr に "eks"
test_check_configs_rejects_orphan_config()    # aws/route53/master だけで config がある → exit 1、stderr に "route53"
test_check_configs_rejects_wrong_component()  # component が "eks" の aws/vpc config → exit 1
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 追加したテストが FAIL

- [ ] **Step 3: `check-release-configs.sh` を実装し、テストを通す**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 全テスト PASS

- [ ] **Step 4: リポジトリで検査が失敗することを確認する**

Run: `bash scripts/terragrunt-release/check-release-configs.sh`
Expected: exit 1。不足として 12 サービス（`alb`・`eks`・`eks-holmesgpt`・`eks-karpenter`・`eks-logs`・`eks-metrics`・`eks-secrets`・`eks-traces`・`github-oidc-auth`・`iam-service-linked-roles`・`secrets-manager`・`vpc`）が出る。一覧が違えば実態を優先し、PR description に差分を書く

- [ ] **Step 5: 設定ファイルを生成する**

`git fetch origin main && git merge-base HEAD origin/main` の SHA を `bootstrap-sha` に使う。各サービスの config は次の形（`<service>` を置き換える）。manifest は `{"aws/<service>": "0.1.0"}`。

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<merge-base SHA>",
  "separate-pull-requests": true,
  "label": "autorelease: pending,release: <service>",
  "changelog-sections": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "perf", "section": "Performance Improvements" },
    { "type": "revert", "section": "Reverts" },
    { "type": "refactor", "section": "Code Refactoring" },
    { "type": "chore", "section": "Miscellaneous Chores" },
    { "type": "docs", "section": "Documentation", "hidden": true },
    { "type": "style", "section": "Styles", "hidden": true },
    { "type": "test", "section": "Tests", "hidden": true },
    { "type": "build", "section": "Build System", "hidden": true },
    { "type": "ci", "section": "Continuous Integration", "hidden": true }
  ],
  "packages": {
    "aws/<service>": {
      "release-type": "simple",
      "component": "<service>",
      "include-component-in-tag": true
    }
  }
}
```

Run: `bash scripts/terragrunt-release/check-release-configs.sh`
Expected: exit 0

- [ ] **Step 6: `release.yml` を設定ファイルの探索方式に置き換える**

monorepo の `.github/workflows/release.yml` と同じ構成にする（`discover` job が `git ls-files '*/release-please-config.json'` で path を集め、`release-please` job が matrix で `config-file` / `manifest-file` を渡す。`workflow_dispatch: {}` と `concurrency: release-please` も同じ）。action の SHA は platform の既存のものを使う。`test-terragrunt-release.yaml` の job に `bash scripts/terragrunt-release/check-release-configs.sh` を足す。

Run: `actionlint && bash scripts/terragrunt-release/test.sh`
Expected: すべて成功

- [ ] **Step 7: commit する**

```bash
git add aws/*/release-please-config.json aws/*/release-please-manifest.json scripts/terragrunt-release .github/workflows
git commit -s -m "ci: release each terragrunt service with its own release-please config"
```

---

### Task 6: release PR に plan を出す

**Files:**
- Create: `.github/workflows/auto-release--plan.yaml`

**Interfaces:**
- Consumes: Task 4 の `release-service.sh --branch`、`release-targets.sh`、executor

- [ ] **Step 1: workflow を書く**

- `on: pull_request: types: [opened, synchronize, reopened]`
- `resolve` job：`if: startsWith(github.head_ref, 'release-please--branches--main--components--')`。checkout の後、`release-service.sh --branch "$HEAD_REF"`（`HEAD_REF` は `env:` で渡す）と `release-targets.sh` の結果を output `targets` にする
- `plan` job：`needs: resolve`、matrix `target: ${{ fromJson(needs.resolve.outputs.targets) }}`、`fail-fast: false`。`reusable--terragrunt-executor.yaml` を `action-type: plan`、`iam-role: matrix.target.iam_role_plan`、`aws-region`・`working-directory`・`service-name`・`environment` は target から渡す。`ref` と `github-environment` は渡さない
- `permissions`：`id-token: write`、`contents: read`、`pull-requests: write`
- plan の出し直しは、この workflow run の「Re-run all jobs」で行う（README に書く。Task 7）

- [ ] **Step 2: lint を通す**

Run: `actionlint .github/workflows/auto-release--plan.yaml`
Expected: 出力なし

- [ ] **Step 3: commit する**

```bash
git add .github/workflows/auto-release--plan.yaml
git commit -s -m "ci: plan release environments on release pull requests"
```

---

### Task 7: release 公開で apply する

**Files:**
- Create: `.github/workflows/auto-release--trigger.yaml`
- Modify: `README.md`
- Modify: `README-ja.md`

**Interfaces:**
- Consumes: Task 4 の `release-service.sh --tag`、`release-targets.sh`、executor の `ref` / `github-environment`

- [ ] **Step 1: workflow を書く**

- `on: release: types: [published]` と `workflow_dispatch: inputs: tag`（`required: true`、`type: string`、description `Release tag to (re-)apply (e.g. vpc-v0.2.0)`）
- `concurrency: group: auto-release-trigger-${{ github.event.release.tag_name || inputs.tag }}`、`cancel-in-progress: false`
- `resolve` job：`TAG` を `env:` で渡し、tag を ref にして checkout してから `release-service.sh --tag "$TAG"` と `release-targets.sh` を実行し、output `targets` と `tag` を出す
- `apply` job：matrix で executor を `action-type: apply`、`iam-role: matrix.target.iam_role_apply`、`ref: needs.resolve.outputs.tag`、`github-environment: matrix.target.environment` で呼ぶ
- `permissions`：`id-token: write`、`contents: read`、`pull-requests: write`
- GitHub environment `production` は job の宣言で GitHub が自動で作るものを使い、Terraform（`github/repository`）では管理しない（required reviewers を付けないので、管理する設定がない）

- [ ] **Step 2: lint を通す**

Run: `actionlint .github/workflows/auto-release--trigger.yaml`
Expected: 出力なし

- [ ] **Step 3: README を更新する**

`README.md` と `README-ja.md` の `## 🚢 Deployment` を更新する。
- `### Trigger` に、`apply_trigger: merge` の環境は main push で、`apply_trigger: release` の環境は `aws/<service>` の release 公開で apply されることを書く
- `### Environments and authentication` に `apply_trigger` の意味と値を書く
- release PR の plan の出し直しは `auto-release--plan` の run の「Re-run all jobs」、apply の再実行は `auto-release--trigger` の `workflow_dispatch` に tag を渡すことを書く
- `Pipeline Flow` の mermaid に `release published → auto-release--trigger → terragrunt apply` を足す

- [ ] **Step 4: commit する**

```bash
git add .github/workflows/auto-release--trigger.yaml README.md README-ja.md
git commit -s -m "ci: apply release environments when a service release is published"
```

---

### Task 8: PR 作成と E2E 確認

ユーザーと一緒に行う。各 Step の結果を PR description の Test plan に記録する。

- [ ] **Step 1: 全体の検証を通す**

Run: `bash scripts/terragrunt-release/test.sh && bash scripts/terragrunt-release/validate-apply-trigger.sh && bash scripts/terragrunt-release/check-release-configs.sh && actionlint`
Expected: すべて成功

- [ ] **Step 2: push して Draft PR を作る**

`git push -u origin HEAD`。`.github/pull_request_template.md` の有無を確認し、あればその構成で本文を書く。`gh pr create --draft`。タイトルは英語（例：`ci: gate production terragrunt applies behind service releases`）。本文に Review Focus の 1・2 番目を書く。

- [ ] **Step 3: PR 上の plan を確認する**

- 12 サービスに `deploy:<service>` が付き、`master` / `develop` / `production` のうち存在する環境で plan が走ることを確認する
- plan job が environment なしで動いていること（`github-environment` が空）を確認する
- `master`（`github-oidc-auth`）と `develop` の plan の差分をユーザーに見せ、merge で apply してよいか確認する。してほしくなければ、最後の push の後にラベルを外す
- open のままの release PR #890 を close してよいかユーザーに確認し、了承されたら `gh pr close 890` を実行する

- [ ] **Step 4: merge 後の確認（ユーザーが merge した後）**

- main push の deploy-trigger で production の apply job が skip されていること
- 次に `aws/<service>/modules/` を変える PR で、ラベルの自動付与、全環境の plan、merge 後の `merge` 環境だけの apply、`aws/<service>` の release PR の作成、release PR への production の plan を順に確認する
- release PR の merge で production だけが承認待ちなしに apply されること、`workflow_dispatch` に同じ tag を渡して再実行できることを確認する
- aws と kubernetes を同時に変える PR で、`deploy-kubernetes` が `terragrunt-shared` の target を実行しないことを確認する
- `aws/github-oidc-auth/develop/` だけを変える PR を merge しても、`github-oidc-auth` の release PR ができないことを確認する（Task 9）

---

### Task 9: merge 環境だけの変更を release から外す

**Files:**
- Modify: `scripts/terragrunt-release/check-release-configs.sh`
- Modify: `scripts/terragrunt-release/test.sh`
- Modify: `aws/<service>/release-please-config.json`（12 サービスすべて）
- Modify: `README.md`・`README-ja.md`（`## 🚢 Deployment` の `### Trigger`）

**Interfaces:**
- Consumes: Task 5 の `check-release-configs.sh` と `write_service_release_config`（test.sh）
- Produces: `check-release-configs.sh` は、release 環境を持つ各サービスについて、`packages["aws/<service>"]["exclude-paths"]` を順序を無視して期待値と比べる。期待値は、`workflow-config.yaml` で `name: terragrunt` の stack にある `apply_trigger: merge` の全環境の `aws/<service>/<environment>` で、ディレクトリの有無は問わない。一致しなければ `::error::aws/<service>: exclude-paths must be <expected> (got <actual>)` を出して exit 1。`<expected>` と `<actual>` は 1 行の JSON 配列で、`exclude-paths` がないときの `<actual>` は `null`

- [ ] **Step 1: テストを書く**

`write_service_release_config` は既定で `"exclude-paths":["aws/<service>/master"]` を書く（`write_release_config` の merge 環境が `master` だけなので）。既存のテストは変えずに通ること。

```bash
test_check_configs_rejects_missing_exclude_paths()   # exclude-paths を消した aws/vpc config → exit 1、stderr に 'aws/vpc: exclude-paths must be ["aws/vpc/master"] (got null)'
test_check_configs_rejects_relative_exclude_paths()  # exclude-paths が ["master"] → exit 1、stderr に 'aws/vpc: exclude-paths must be ["aws/vpc/master"]'
test_check_configs_accepts_exclude_paths_in_any_order()  # merge 環境が master と develop の config で、exclude-paths が ["aws/vpc/develop","aws/vpc/master"] → 出力なしで exit 0
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 追加した 2 つの rejects テストが FAIL

- [ ] **Step 3: `check-release-configs.sh` に検査を足し、テストを通す**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 全テスト PASS

- [ ] **Step 4: リポジトリで検査が失敗することを確認する**

Run: `bash scripts/terragrunt-release/check-release-configs.sh`
Expected: exit 1。12 サービスすべてについて exclude-paths のエラーが出る

- [ ] **Step 5: 12 サービスの config に `exclude-paths` を足す**

各 `aws/<service>/release-please-config.json` の `packages["aws/<service>"]` に `"exclude-paths": ["aws/<service>/master", "aws/<service>/develop"]` を足す。既存のキーの順序と 2 スペースのインデントを保つ。

Run: `bash scripts/terragrunt-release/check-release-configs.sh && bash scripts/terragrunt-release/test.sh`
Expected: どちらも成功

- [ ] **Step 6: README に動作を書く**

`### Trigger` の release-please 設定の項目の下に、`apply_trigger: merge` の環境ディレクトリだけを変える commit は `exclude-paths` で release から外れること、`check-release-configs.sh` がその一覧を `workflow-config.yaml` と照合することを書く。`README-ja.md` も同じ内容を日本語で書く。

- [ ] **Step 7: commit する**

```bash
git add scripts/terragrunt-release aws/*/release-please-config.json README.md README-ja.md
git commit -s -m "ci: keep merge-only environment changes out of service releases"
```

---

### Task 10: production を除外環境にする

**Files:**
- Modify: `workflow-config.yaml`
- Modify: `scripts/terragrunt-release/release-targets.sh`
- Modify: `scripts/terragrunt-release/test.sh`
- Modify: `.github/workflows/auto-release--plan.yaml`
- Modify: `.github/workflows/auto-release--trigger.yaml`
- Modify: `README.md`・`README-ja.md`（`## 🚢 Deployment` の `### Trigger`）

**Interfaces:**
- Consumes: Task 4 の `release-targets.sh`、Task 5・9 の `check-release-configs.sh`（変更しない）
- Produces: `release-targets.sh <service> [config]` は、`name: terragrunt` の stack の `exclude` の各 rule（キーは `service` と `environment`。rule のキーがすべて一致したら除外。deploy-actions の `excluded?` と同じ意味）に一致する target を外す。`apply_trigger: release` の環境のディレクトリが 1 つもなければ今までどおり `::error::no release targets for <service>` で exit 1。ディレクトリはあるが全部除外されたら `[]` を出して exit 0。`exclude` がない stack は今までどおり

- [ ] **Step 1: テストを書く**

```bash
test_release_targets_skips_excluded_envs()          # write_release_config に exclude [{environment: production}] を足し、aws/vpc/production と aws/vpc/staging → staging だけの配列
test_release_targets_returns_empty_when_all_excluded()  # exclude [{environment: production}, {environment: staging}]、aws/vpc/production だけ → stdout が "[]"、exit 0
test_release_targets_honors_service_scoped_exclude()    # exclude [{service: vpc, environment: production}]、aws/vpc/production と aws/eks/production → vpc は "[]"、eks は production の 1 件
test_check_configs_requires_config_for_excluded_env()   # exclude [{environment: production}]、aws/eks/production があり config がない → exit 1、stderr に "aws/eks/release-please-config.json"。config を足すと出力なしで exit 0
test_release_workflows_skip_empty_targets()          # auto-release--plan.yaml の jobs.plan.if と auto-release--trigger.yaml の jobs.apply.if が "needs.resolve.outputs.targets != '[]'"
test_repository_config_excludes_production()        # リポジトリの workflow-config.yaml の terragrunt stack の exclude に {environment: production} がある
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 追加したテストのうち、`test_check_configs_requires_config_for_excluded_env` 以外が FAIL

- [ ] **Step 3: `release-targets.sh` に除外を足し、2 つの workflow の job に `if: needs.resolve.outputs.targets != '[]'` を付け、`workflow-config.yaml` の terragrunt stack の末尾に `exclude: [{environment: production}]` を足す**

`workflow-config.yaml` の `exclude` は monorepo と同じ block style で書き、`production` の環境定義は残す（deploy-actions は `exclude` の環境が `environments` に宣言されていることを要求する）。

Run: `bash scripts/terragrunt-release/test.sh && bash scripts/terragrunt-release/validate-apply-trigger.sh && bash scripts/terragrunt-release/check-release-configs.sh && actionlint`
Expected: test・validate・check は成功。actionlint は既存の `target-environment` の 1 件だけ

- [ ] **Step 4: deploy-actions の config 検証を通す**

deploy-actions v2.0.1（`1ab520e5ef33b8d744982762ffc4e08009a34744`）の `WorkflowConfig` で、リポジトリの `workflow-config.yaml` が検証を通り、`excluded?` が `aws/vpc/production` を除外することを確かめる（`.git` がファイルの worktree では動かないので、platform の通常 clone か `git archive` で取り出した tree で実行する）。

Expected: 検証エラーなし、production が excluded

- [ ] **Step 5: README に動作を書く**

`### Trigger` に、terragrunt stack の `exclude` に一致する環境は label 付与・PR の plan・main merge の apply・release の plan / apply のすべてから外れ、release PR はできるが merge しても apply しないことを書く。`README-ja.md` も同じ内容を日本語で書く。

- [ ] **Step 6: commit する**

```bash
git add workflow-config.yaml scripts/terragrunt-release .github/workflows README.md README-ja.md
git commit -s -m "ci: exclude production from platform terragrunt runs"
```
