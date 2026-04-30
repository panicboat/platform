# OIDC Trust Policy Tightening and Plan/Apply Role Split

## Background

`monorepo` と `platform` は GitHub Actions から OIDC で AWS に認証している（`aws/github-oidc-auth/`）。現在の構成は fork PR が許可されると AdministratorAccess を持つ role を assume できる経路が開く。

主な問題点:

1. **Trust policy の `sub` 条件が広い**: `repo:panicboat/{repo}:*` が含まれ、PR トリガー（`:pull_request`）も match する。fork PR の OIDC token も `sub` の repo 部分は base リポジトリ名になるため、fork PR からも assume できる。
2. **plan / apply の権限分離がない**: `iam_role_plan` と `iam_role_apply` が同一 role（`AdministratorAccess` アタッチ）。plan 経路でも全権限が付く。
3. **`GITHUB_TOKEN` 既定権限が広い**: monorepo / platform の Actions 設定で default workflow permissions が write のままで、workflow が `permissions:` を宣言しなければ書き込み可能。

`allow_forking = false`（PR #224）が一次ゲートだが、設定が逆戻りしたり内部脅威に対する防御を持たないため、AWS 認証層と GitHub Actions 設定層で多層防御を入れる。

## Goals

- AWS OIDC trust policy から `repo:panicboat/{repo}:*` を除去する
- IAM role を **plan-role**（ReadOnly + state lock RW）と **apply-role**（AdministratorAccess）に分離する
- plan-role の trust は PR と main に限定、apply-role の trust は main push と environment ゲートに限定する
- `monorepo` と `platform` の Actions の default workflow permissions を read-only にする
- `workflow-config.yaml` の `iam_role_plan` / `iam_role_apply` を新 ARN に切り替える

## Non-Goals

- monorepo / platform 以外のリポジトリの OIDC 設定変更
- monorepo と platform で OIDC role を repo 別に分離する（共有を維持）
- GitHub Environments + required reviewers の追加（Approach C の領域、本 spec の対象外）
- `allowed_actions` allowlist 化（Approach C の領域）
- `.github/CODEOWNERS` の細分化（既存の `* @panicboat` を維持）
- Branch protection の追加変更
- `terragrunt apply` の実機適用（plan / 実行は別途）

## Design

### AWS layer (`aws/github-oidc-auth/`)

#### Trust policy の構成変更

`modules/main.tf` の `local.all_conditions` を廃止し、role ごとに専用の条件リストを用意する。

新しい条件リスト:

```hcl
locals {
  # plan-role: PR トリガーと main 上での plan を許可
  plan_conditions = flatten([
    for repo in var.github_repos : [
      "repo:${var.github_org}/${repo}:pull_request",
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
    ]
  ])

  # apply-role: main push と environment 経由のみ
  apply_conditions = flatten([
    for repo in var.github_repos : concat(
      ["repo:${var.github_org}/${repo}:ref:refs/heads/main"],
      [for env in var.github_environments :
        "repo:${var.github_org}/${repo}:environment:${env}"]
    )
  ])
}
```

旧 `repo_conditions`（`repo:.../{repo}:*`）と `branch_conditions`（`["*"]` の展開で実質ワイルドカードになっていた）は削除する。`var.github_branches` 変数も用途がなくなるため削除（envs 側でも参照を外す）。

#### IAM role の分割

旧 `aws_iam_role.github_actions_role`（単一 role に AdministratorAccess）を廃止し、以下 2 つに置き換える:

1. **`aws_iam_role.plan`**
   - 名前: `${var.project_name}-${var.environment}-github-actions-plan-role`
   - Trust: `plan_conditions`
   - アタッチポリシー:
     - `arn:aws:iam::aws:policy/ReadOnlyAccess`
     - 新規 customer-managed policy: Terragrunt state lock 用に DynamoDB lock table（`terragrunt-state-locks`）への `PutItem` / `DeleteItem` / `GetItem`
   - 備考: state バケット（`terragrunt-state-${account_id}`）の読み取りは `ReadOnlyAccess` の `s3:Get*` / `s3:List*` でカバーされる。書き込みは付与しない。

2. **`aws_iam_role.apply`**
   - 名前: `${var.project_name}-${var.environment}-github-actions-apply-role`
   - Trust: `apply_conditions`
   - アタッチポリシー:
     - `arn:aws:iam::aws:policy/AdministratorAccess`（現状維持）

`var.additional_iam_policies` は apply-role にのみアタッチする。

#### Outputs の更新

`modules/outputs.tf`:

- 削除: `github_actions_role_arn`, `github_actions_role_name`, `allowed_branches`
- 追加: `plan_role_arn`, `plan_role_name`, `apply_role_arn`, `apply_role_name`

`oidc_provider_arn`, `oidc_provider_url`, `cloudwatch_log_group_*`, `github_org`, `github_repos`, `allowed_environments` は維持。

#### Variables の整理

`modules/variables.tf`:

- 削除: `github_branches`
- それ以外は維持

`envs/{develop,production}/env.hcl`:

- `github_branches = ["*"]` の行を削除
- `github_environments` は環境名（`develop` / `production`）のまま維持

`envs/staging/` は env.hcl / terragrunt.hcl が無く未使用のため対象外。

#### terragrunt.hcl の更新

`envs/{env}/terragrunt.hcl` の `inputs` から `github_branches` 参照を削除。

### GitHub Actions layer (`github/repository/`)

#### Default workflow permissions の read 化

`github/repository/` 配下で `monorepo` と `platform` の default workflow permissions（GitHub Settings → Actions → General → Workflow permissions に対応）を `read` に設定する。

実装は `integrations/github` provider が提供する Terraform リソースで管理することを前提とし、状態管理外の手段（`null_resource` + `local-exec` 等）でのフォールバックは取らない。失敗がサイレントになり、plan/apply の差分追跡が効かなくなるため。

provider のリソース調査結果（6.12 系のスキーマで確認）:

- `github_actions_repository_permissions` は `enabled` / `allowed_actions` / `sha_pinning_required` を扱うリソースで、`default_workflow_permissions` は持たない
- `github_workflow_repository_permissions` が `repository` / `default_workflow_permissions` / `can_approve_pull_request_reviews` を持つ別リソース。本 spec の目的にはこちらを使う

`variables.tf` に `actions_default_permissions_read = optional(bool, false)` を追加し、`envs/develop/{monorepo,platform}.hcl` で `true` を指定する。`github_workflow_repository_permissions` を `actions_default_permissions_read = true` のリポジトリにのみ作成し、`default_workflow_permissions = "read"` と `can_approve_pull_request_reviews = false` を設定する。他のリポジトリは既定値 `false` のままで挙動変化なし。

#### Workflow 側の影響

既存 workflow を確認した結果、書き込み権限が要る workflow は top-level `permissions:` で明示宣言済:

- `auto-approve.yaml`: `pull-requests: write`
- `auto-label--deploy-trigger.yaml`: `id-token: write`, `contents: write`, `pull-requests: write`
- `auto-label--label-dispatcher.yaml`: `pull-requests: write`, `issues: write`
- `reusable--*.yaml`: 各 job 内で `permissions:` 宣言

`ci-gatekeeper.yaml` のみ `permissions:` 未宣言。default を `read` にすると `GITHUB_TOKEN` には `contents: read` / `packages: read` / `metadata: read` 程度しか付かず、`int128/wait-for-workflows-action` が要求する `actions: read`（workflow run の状態を REST API で取得）が無くなる。default 切替前に以下の `permissions:` を追加する必要がある:

```yaml
permissions:
  actions: read
```

### `workflow-config.yaml` の更新

各環境の `iam_role_plan` / `iam_role_apply` を新 role の ARN に置換。フィールド構造（`required_attributes` 含む）は維持。

```yaml
- environment: develop
  stacks:
    terragrunt:
      aws_region: us-east-1
      iam_role_plan:  arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-plan-role
      iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-apply-role
      kubernetes: {}
```

`production` も同様。`local` は変更なし。

## Apply ordering

破壊的変更を含むため、新 role の作成と旧 role の削除を分離した段階適用とする:

1. **AWS apply (Phase 1)**: `aws/github-oidc-auth/modules/` を改修し、旧 `aws_iam_role.github_actions_role` リソースを残したまま新 plan-role / apply-role を**追加で**作成する PR をマージ。develop / production の各環境で apply（staging は未使用のため対象外）
2. **`workflow-config.yaml` 切替 PR**: `iam_role_plan` / `iam_role_apply` を新 role の ARN に書き換える PR をマージ。マージ後、PR で plan が plan-role で動くこと、main マージ後の apply が apply-role で動くことを確認する
3. **AWS apply (Phase 2)**: 手順 2 の動作確認後、旧 `aws_iam_role.github_actions_role` リソース定義を削除する PR をマージし、各環境で apply。これにより不可逆な旧 role 削除を新 role の運用実績がある状態で実施する
4. **`ci-gatekeeper.yaml` 修正 PR**: `permissions: actions: read` を追加する PR をマージ（次手順の前提）
5. **GitHub default permissions apply**: `github/repository/envs/develop/{monorepo,platform}.hcl` で `actions_default_permissions_read = true` を有効化して apply。`ci-gatekeeper.yaml` を含む全 workflow が完走することを確認する

## Verification

- 手順 1（AWS apply Phase 1）の `terragrunt plan` で以下の差分が出る:
  - `aws_iam_role.plan` 新規作成
  - `aws_iam_role.apply` 新規作成
  - 関連ポリシーアタッチメントの差分
  - 旧 `aws_iam_role.github_actions_role` は差分に含まれない（残存）
- 手順 3（AWS apply Phase 2）の `terragrunt plan` で旧 `aws_iam_role.github_actions_role` の削除差分のみが出る
- production でも同様の差分
- `monorepo` と `platform` の GitHub UI で `Settings → Actions → General → Workflow permissions` が "Read repository contents and packages permissions" になっていること
- 他リポジトリ（`deploy-actions`, `panicboat-actions`, `ansible`, `dotfiles`）の Workflow permissions に変更が無いこと
- `auto-label--deploy-trigger.yaml` の PR plan / main apply の両方が新 role で完走する
- `ci-gatekeeper.yaml` が default read 環境下で完走する
- **拒否確認**: PR ブランチで apply-role の ARN を assume する step を持つテスト workflow を一時的に作成し PR を出して動作させ、`AccessDenied` で失敗することを確認する。確認後にテスト workflow は削除する

## Rollback

各 step の rollback:

- 手順 5（GitHub default permissions）: `actions_default_permissions_read = false` に戻して apply
- 手順 4（ci-gatekeeper permissions）: 影響なし。読み取り権限の追加は default が write でも害はない
- 手順 3（旧 role 削除）: 該当 commit を revert して apply。旧 `github_actions_role` が再作成される
- 手順 2（`workflow-config.yaml`）: 旧 ARN に戻す PR をマージ。旧 role はまだ存在するため即座に旧経路に戻る
- 手順 1（新 role 作成）: 該当 commit を revert して apply。新 role が削除される

3 段階分離の利点として、旧 role が残った状態（手順 1〜2）であれば旧経路に即座に戻せる。手順 3 の旧 role 削除以降に問題が出た場合は手順 3 を revert する。
