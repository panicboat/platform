# Renovate Major Update AI Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `📈 major-update` ラベルの Renovate PR に、Bedrock 上の Claude が upstream 一次情報と自リポジトリの定義を突き合わせたレビューコメントを自動投稿する。

**Architecture:** `aws/github-oidc-auth` module に Bedrock 呼び出し専用 IAM role を追加し、`master` だけで作る。独立 workflow がラベル付与で発火し、読み取り専用 token で `claude-code-action` を動かして structured output でコメント本文を受け取り、別 job が `pull-requests: write` だけでコメントを upsert する。

**Tech Stack:** OpenTofu / Terragrunt（`tofu test`）、GitHub Actions、`anthropics/claude-code-action` v1.0.261、Amazon Bedrock（`global.anthropic.claude-sonnet-4-6`）、helm v3.17.3（aqua）

**Spec:** `docs/superpowers/specs/2026-10-24-renovate-major-update-review-design.md`

## Global Constraints

- AGENTS.md のルールを全タスクに適用する（コミットは `git commit -s`、`Co-Authored-By` を付けない、コメントは1行・Why not のみ、コード内の要素は英語）
- third-party action は commit SHA で pin し、`# vX.Y.Z` を併記する。既存 workflow と同じ SHA を使う
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`
  - `aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0`
  - `aquaproj/aqua-installer@82d0e83878a8657c4a6f2ff1755d3bfbfc67f329 # v4.1.0`（`aqua_version: v2.64.0`）
  - `thollander/actions-comment-pull-request@24bffb9b452ba05a4f3f77933840a6a841d1b32b # v3.0.1`
  - `anthropics/claude-code-action@16f9f71ab9c490faf367f94dd294897edc25be33 # v1.0.261`（tag object を deref した commit。VERIFIED: `gh api repos/anthropics/claude-code-action/git/tags/af7730b4…` → `16f9f71a…`）
- AWS account `559744160976`（master）。Bedrock の呼び出し region は `us-east-1`
- model は `global.anthropic.claude-sonnet-4-6`。ルーティング先は `arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6` と `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6`（VERIFIED: `aws bedrock get-inference-profile --region us-east-1 --inference-profile-identifier global.anthropic.claude-sonnet-4-6`）
- Claude を動かす job に、GitHub への書き込み権限を持つ token を渡さない（GitHub App token は使わない）
- push・approve・ラベル変更・マージは一切しない
- `auto-label--deploy-trigger.yaml` と hydrator は変更しない
- `aws/` 配下の変更は CI で apply されない。apply は手元から `terragrunt apply` で行い、実行前にユーザー確認を取る

## Review Focus

- Renovate が PR 作成時にラベルを3〜4個同時に付けても、レビューは `📈 major-update` の `labeled` イベントの1回だけ起動し、他ラベルの run に cancel されない → Task 3 の job `if` と、ラベル名を含めた concurrency group。Task 4 の E2E で確認
- 人が `📈 major-update` を外して付け直すと再レビューされ、新しいコメントは増えず既存コメントが上書きされる → Task 3 の `comment-tag` と Task 4 の E2E で確認
- Renovate 以外が作った PR に `📈 major-update` が付いても起動しない → Task 3 の job `if`
- Bedrock 失敗や structured output が空のときは、空コメントやエラーコメントを投稿しない → Task 3 の post job の `if`
- Helm chart 以外（GitHub Actions 等）のメジャー更新でも、helm を前提にせずレビューが完走する → Task 3 の prompt の分岐。次に来た Actions のメジャー PR で確認する（Task 4 の対象外）

---

### Task 1: Bedrock invoke role in `github-oidc-auth` module

**Files:**
- Create: `aws/github-oidc-auth/modules/bedrock.tf`
- Create: `aws/github-oidc-auth/modules/tests/bedrock_role.tftest.hcl`
- Modify: `aws/github-oidc-auth/modules/variables.tf`（末尾に変数追加）
- Modify: `aws/github-oidc-auth/modules/outputs.tf`（末尾に output 追加）
- Modify: `aws/github-oidc-auth/master/env.hcl`・`aws/github-oidc-auth/master/terragrunt.hcl`

**Interfaces:**
- Produces:
  - variable `bedrock_models` (`list(string)`, default `[]`)。空なら role を作らない
  - resource `aws_iam_role.bedrock[0]`、name `"${var.project_name}-${var.environment}-github-actions-bedrock-role"` → master では `github-oidc-auth-master-github-actions-bedrock-role`
  - output `bedrock_role_arn`（`string`、role 未作成時は `null`）
  - Task 3 はこの role ARN `arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-bedrock-role` を直書きで使う（`workflow-config.yaml` の既存 role と同じ流儀）

- [ ] **Step 1: Write the failing test** `aws/github-oidc-auth/modules/tests/bedrock_role.tftest.hcl`

`aws/vpc/modules/tests/private_trust.tftest.hcl` の書式に合わせる。`mock_provider "aws" {}`・`mock_provider "tls" {}`、`override_data { target = data.aws_caller_identity.current values = { account_id = "123456789012" } }`。共通 variables は `project_name = "github-oidc-auth"`・`environment = "master"`・`github_org = "panicboat"`・`github_repos = ["monorepo", "platform"]`・`create_oidc_provider = false`・`oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"`（`tls_certificate` の index 参照を避けるため）。

```hcl
run "skips_bedrock_role_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role.bedrock) == 0
    error_message = "The bedrock role must not exist when bedrock_models is empty."
  }
}

run "creates_bedrock_role_for_listed_models" {
  command = plan
  variables {
    bedrock_models = ["anthropic.claude-sonnet-4-6"]
  }
  assert {
    condition     = aws_iam_role.bedrock[0].name == "github-oidc-auth-master-github-actions-bedrock-role"
    error_message = "The bedrock role must use the stable name."
  }
  assert {
    condition     = jsondecode(aws_iam_role.bedrock[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:panicboat/platform:pull_request"]
    error_message = "Only pull_request runs of panicboat/platform may assume the bedrock role."
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 0 must allow only the global inference profile."
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Resource) == toset([
      "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 1 must allow the foundation models the global profile routes to."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Condition.StringLike["bedrock:InferenceProfileArn"] == ["arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6"]
    error_message = "Foundation model access must be limited to calls routed through the profile."
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd aws/github-oidc-auth/modules && tofu init -backend=false -input=false && tofu test`
Expected: FAIL（`bedrock_models` 未定義 / `aws_iam_role.bedrock` 未定義のエラー）

- [ ] **Step 3: Implement**
  - `variables.tf` に `variable "bedrock_models"`（`list(string)`、default `[]`、description は "Bedrock foundation model IDs invokable via global inference profiles; the role is skipped when empty"）
  - `bedrock.tf` に `aws_iam_role.bedrock`（`count = length(var.bedrock_models) > 0 ? 1 : 0`、`max_session_duration` は default の 3600 のまま）と `aws_iam_role_policy.bedrock_invoke`（name `bedrock-invoke`）
    - trust は既存 `aws_iam_role.plan` と同じ形で、`sub` を `StringEquals` で `repo:${var.github_org}/platform:pull_request` に固定する
    - policy は削除済み `aws/ai-assistant/modules/main.tf`（`git show ac621b0^:aws/ai-assistant/modules/main.tf`）の2 statement 構成（profile ARN を無条件許可、FM ARN を `bedrock:InferenceProfileArn` 条件付きで許可）を踏襲し、Action は `bedrock:InvokeModel`・`bedrock:InvokeModelWithResponseStream` のみ
    - tags は既存 role と同じく `Name` と `Purpose = "github-actions-oidc-bedrock"` を merge する
  - `outputs.tf` に `bedrock_role_arn = one(aws_iam_role.bedrock[*].arn)`
  - `master/env.hcl` に `bedrock_models = ["anthropic.claude-sonnet-4-6"]`、`master/terragrunt.hcl` の inputs に `bedrock_models = include.env.locals.bedrock_models`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd aws/github-oidc-auth/modules && tofu test && tofu fmt -check -recursive .. && tofu validate`
Expected: `Success! 2 passed, 0 failed.`、fmt の出力なし、`The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add aws/github-oidc-auth
git commit -s -m "feat(aws/github-oidc-auth): add bedrock invoke role for github actions"
```

### Task 2: Apply the role to master

**Files:** なし（AWS への適用のみ）

**Interfaces:**
- Consumes: Task 1 の `bedrock_models` と `master/env.hcl`
- Produces: AWS 上の role `github-oidc-auth-master-github-actions-bedrock-role`

- [ ] **Step 1: Plan**

Run: `cd aws/github-oidc-auth/master && terragrunt plan`（master account の credential で。`! eks-login` ではなく通常の AWS profile）
Expected: `Plan: 2 to add, 0 to change, 0 to destroy.`（`aws_iam_role.bedrock[0]` と `aws_iam_role_policy.bedrock_invoke[0]` のみ）

- [ ] **Step 2: ユーザーに plan 結果を提示し、apply の承認を得る**

完了条件: ユーザーが apply を明示的に承認した。

- [ ] **Step 3: Apply**

Run: `cd aws/github-oidc-auth/master && terragrunt apply`
Expected: `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.`、`bedrock_role_arn = "arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-bedrock-role"`

### Task 3: Review workflow and prompt

**Files:**
- Create: `.github/workflows/renovate-major-review.yaml`
- Create: `.github/prompts/renovate-major-review.md`

**Interfaces:**
- Consumes: Task 1 の role ARN `arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-bedrock-role`
- Produces: PR コメント（`comment-tag: renovate-major-review`）

- [ ] **Step 1: Write the prompt** `.github/prompts/renovate-major-review.md`

本文は英語で書き、出力コメントは日本語で書くよう指示する。必ず含める指示:
  - 対象の特定: `gh pr view <PR>` と `git diff origin/main...HEAD` から、変更された依存の名前・現バージョン・新バージョン・種別（Helm chart / GitHub Action / その他）と、Renovate が変更したファイルを特定する
  - PR 本文のリリースノートは参考扱いとし、upstream（chart の source repo の releases / CHANGELOG / UPGRADING 等）から現バージョンの次から新バージョンまでの全リリースを取得する。PR 本文のノートが別パッケージのものだった場合や途中が欠けていた場合はその旨を記録する
  - 突き合わせ対象: Helm chart なら `kubernetes/components/<svc>/<env>/` の `helmfile.yaml`・`values.yaml.gotmpl`（または `values.yaml`）・`kustomization/` 配下。GitHub Action なら `.github/workflows/` でその action を使っている箇所。その他は Renovate が変更したファイルと、その依存を参照している定義
  - Helm chart の場合: `helm repo add` 後に `helm show values --version <old>` と `--version <new>` を取り、default 値の差分を確認する。values に現れないテンプレート変化（StatefulSet の selector・PVC・Service 名）が疑われる場合だけ `helm template` で新旧を描画し、該当リソースを比較する
  - 判定: ✅ そのままマージ可 / ⚠️ 修正が必要 / 🛑 手動作業が必要（CRD 適用・データ移行など）の3択。一次情報が取れなかった範囲が1つでもあれば ✅ にせず ⚠️ にし、取れなかった範囲を「影響のある変更」の先頭に書く
  - コメント構成は spec の「Review Comment Format」の 1〜5 をこの順で使う。「影響のある変更」の各項目にファイル:行番号・一次情報 URL・修正案のコードブロックを付ける。「影響のない変更」は `<details>` に入れる。5 は `helm template` を実行しなかった場合は省略する
  - 根拠 URL のない主張を書かない。リポジトリのファイルを変更しない
  - 最終出力は structured output の `body` にコメント本文全体を入れる

- [ ] **Step 2: Write the workflow** `.github/workflows/renovate-major-review.yaml`

決定済みの骨格（step の細部は実装者が埋める）:

```yaml
name: 'Renovate Major Review'
on:
  pull_request:
    types: [labeled]
permissions: {}
concurrency:
  group: renovate-major-review-${{ github.event.pull_request.number }}-${{ github.event.label.name }}
  cancel-in-progress: true
jobs:
  review:
    if: github.event.label.name == '📈 major-update' && github.event.pull_request.user.login == 'renovate[bot]'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      pull-requests: read
      id-token: write
    outputs:
      body: ${{ steps.claude.outputs.structured_output && fromJSON(steps.claude.outputs.structured_output).body || '' }}
    steps: [checkout (fetch-depth: 0), aqua-installer, configure-aws-credentials (role-to-assume: <Task 1 ARN>, aws-region: us-east-1), claude-code-action (id: claude)]
  post:
    needs: review
    if: needs.review.result == 'success' && needs.review.outputs.body != ''
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps: [thollander/actions-comment-pull-request (message: needs.review.outputs.body, comment-tag: renovate-major-review, mode: upsert, pr-number: github.event.pull_request.number)]
```

`claude-code-action` の入力:
  - `use_bedrock: "true"`、`github_token: ${{ github.token }}`（読み取り専用。未指定だと Claude GitHub App の書き込み token を取りに行くため必ず指定する）、`allowed_bots: "renovate"`
  - `prompt`: `.github/prompts/renovate-major-review.md` を読んで従うこと、対象 PR 番号 `${{ github.event.pull_request.number }}` を渡す
  - `claude_args`:
    - `--model global.anthropic.claude-sonnet-4-6`
    - `--json-schema '{"type":"object","properties":{"body":{"type":"string","minLength":1}},"required":["body"]}'`
    - `--allowedTools` は `Read,Glob,Grep,WebFetch,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh api:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(helm repo add:*),Bash(helm repo update:*),Bash(helm show:*),Bash(helm template:*)` に限定する（`env`・`curl` 等を許可しないことで、環境変数中の AWS credential や OIDC request token の持ち出しを防ぐ）

- [ ] **Step 3: Lint**

Run: `actionlint .github/workflows/renovate-major-review.yaml`
Expected: 出力なし・exit 0

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/renovate-major-review.yaml .github/prompts/renovate-major-review.md
git commit -s -m "feat(.github/workflows): review renovate major updates with claude on bedrock"
```

### Task 4: Ship and verify on the open major PRs

**Files:** なし

`pull_request` イベントは PR の merge ref（base = `main`）の workflow を使うため、E2E は main への merge 後にしか実行できない。

- [ ] **Step 1: Push and open a Draft PR**

`.github/pull_request_template.md` の有無を確認し、あればその構成で本文を書く。`git push -u origin HEAD` → `gh pr create --draft`（タイトルは英語の Conventional Commits）。
完了条件: Draft PR の URL をユーザーに提示した。Task 2 の apply が済んでいることを PR 本文に書く。

- [ ] **Step 2: ユーザーの merge を待つ**

完了条件: ユーザーが merge したと報告した、または `gh pr view <PR> --json state` が `MERGED`。

- [ ] **Step 3: ユーザー確認のうえ #1019 で再レビューを起動**

確認を取ってから `gh pr edit 1019 --remove-label "📈 major-update"` → `gh pr edit 1019 --add-label "📈 major-update"`。
Expected: `gh run list --workflow renovate-major-review.yaml --limit 1` が `success`、#1019 に `renovate-major-review` コメントが1件。
確認項目: 対象範囲が `grafana-community/tempo` chart の 2.4.0 → 3.0.0（`tempo-distributed` ではない）、PR 本文のノートが別 chart のものだった旨の記載、各指摘にファイル:行番号と URL。

- [ ] **Step 4: 同じ手順で #1018 を確認**

確認項目: 対象範囲に v89・v90・v91 の全メジャーが含まれる、各指摘にファイル:行番号と URL。

- [ ] **Step 5: 冪等性と権限の確認**

#1019 のラベルをもう一度付け直す。
Expected: `renovate-major-review` コメントは1件のまま更新される。`gh pr view 1019 --json commits,reviews,labels` で、新しい commit・review・ラベル変更がないこと。

- [ ] **Step 6: 失敗時の切り分け**

Bedrock の `AccessDeniedException` が出た場合は、Task 1 の FM ARN（`arn:aws:bedrock:*::` と `arn:aws:bedrock:::`）と CloudTrail の拒否 resource を照合してから Task 1 に戻る。`allowed_bots` で弾かれた場合は action ログの actor 名と照合する。
