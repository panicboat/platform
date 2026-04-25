# Environment Naming Refactor (`k3d` → `local`)

## Background

CI で Kubernetes の hydrate ジョブが起動しないという事象があり、その根本原因は環境名の体系の不整合だった。

- `panicboat/deploy-actions/label-resolver` は `workflow-config.yaml` の `environments:` に宣言された環境名で `kubernetes/components/{service}/{environment}/` を解決する
- 現在 `workflow-config.yaml` は `develop` と `production` のみ宣言。Kubernetes コンポーネント側のディレクトリは `k3d` のみ
- → 一致する組み合わせが存在せず kubernetes targets が常に空、hydrate ジョブが永久にスキップされる

加えて、リポジトリ内には以下の関連する曖昧さ・不整合がある:

- `develop` の AWS リージョンが資料間でズレている（`workflow-config.yaml`／README は `us-east-1`、env.hcl は `ap-northeast-1`）
- `staging` 環境が `workflow-config.yaml` ではコメントアウトされている一方、`aws/github-oidc-auth/envs/staging/` のディレクトリと内容は実体として残存
- README が古いディレクトリ名（`aws/claude-code/`、`aws/claude-code-action/`）を参照しており、実体（`aws/ai-assistant/`）とズレている
- `kubernetes/Makefile` 等で `k3d` が「環境名／パス」と「ツール名（k3d CLI）」の双方を指す形で混在している

## Goal

CI の Kubernetes hydrate を機能させることを主目的とし、関連する環境名の曖昧さを一括で整理する。

## Non-Goals

- `panicboat/deploy-actions` リポジトリの仕様変更（環境とクラスタを別軸として扱う等の拡張）
- monorepo リポジトリの環境命名変更（platform/kubernetes 配下のみを対象とする）
- `staging` 環境の有効化（予約も含めて削除する）

## Environment Taxonomy

| 環境名 | 用途 | 修正後の状態 |
|--------|------|------------------|
| `local` | ローカル k3d クラスタ | `kubernetes/{clusters,components/*,manifests}/k3d/` を `local/` にリネームし、`workflow-config.yaml` に追加（kubernetes 専用、AWS フィールド無し） |
| `develop` | AWS 開発環境 | 維持。リージョンを `us-east-1` で全資料統一 |
| `staging` | （無し） | `workflow-config.yaml` の予約コメントを削除し、`aws/github-oidc-auth/envs/staging/` も削除 |
| `production` | 本番 | 維持 |

`local` 環境は Kubernetes 専用で AWS Terragrunt スタックを持たない。`workflow-config.yaml` 上では `aws_region` / `iam_role_*` を省略する。

## `develop` Region Alignment

| ファイル | 現状 | 修正後 |
|----------|------|--------|
| `workflow-config.yaml` | `us-east-1` | `us-east-1`（維持） |
| `README.md` / `README-ja.md` | `us-east-1` | `us-east-1`（維持） |
| `aws/github-oidc-auth/envs/develop/env.hcl` | `ap-northeast-1` | `us-east-1` |
| `aws/ai-assistant/envs/develop/env.hcl` | `ap-northeast-1` | `us-east-1` |

IAM は Global サービスのため `github-oidc-auth` の region 変更はリソース再作成を起こさない。`ai-assistant` は Bedrock 関連の IAM／ポリシーを扱うが、リージョナルリソース（CloudWatch Logs グループ等）が含まれる場合は再作成リスクがあるため、適用前に `terragrunt plan` の差分を目視確認する。

## Components

### A. ディレクトリリネーム（`k3d` → `local`）

git mv で履歴追跡可能な形で移動:

- `kubernetes/clusters/k3d/` → `kubernetes/clusters/local/`
- `kubernetes/components/{beyla,cilium,coredns,dashboard,fluent-bit,gateway-api,loki,opentelemetry,opentelemetry-collector,prometheus-operator,tempo}/k3d/` → 同 `.../local/`
- `kubernetes/manifests/k3d/` → `kubernetes/manifests/local/`

### B. ファイル内文字列置換

| ファイル | 内容 |
|----------|------|
| `workflow-config.yaml` | `environments:` に `local` 環境を追加（AWS フィールド省略）。`staging` 予約コメントブロックを削除 |
| `kubernetes/Makefile` | `ENV ?= k3d` → `ENV ?= local`、ハードコードされた `manifests/k3d`、`components/.../k3d`、`clusters/k3d` のパスを置換。help／コメント文言も更新 |
| `kubernetes/clusters/local/flux-system/gotk-sync.yaml` | `path: ./kubernetes/clusters/k3d` → `./kubernetes/clusters/local`、TODO コメント文言を更新 |
| `.github/workflows/reusable--kubernetes-hydrator.yaml` | `description: '... (e.g., k3d)'` → `'... (e.g., local)'` |
| `.github/workflows/reusable--kubernetes-builder.yaml` | 同上 |
| `kubernetes/README.md` | `k3d` 参照を `local` に更新 |
| `README.md` / `README-ja.md` | 環境表に `local` 行を追加。`aws/claude-code/`／`aws/claude-code-action/` を `aws/ai-assistant/` に修正 |
| `kubernetes/helmfile.yaml.gotmpl`、各 helmfile / values | パス／環境名としての `k3d` を置換（ツール名としての `k3d` は維持） |

### C. AWS env.hcl の region 修正

- `aws/github-oidc-auth/envs/develop/env.hcl`: `aws_region = "ap-northeast-1"` → `"us-east-1"`
- `aws/ai-assistant/envs/develop/env.hcl`: `aws_region = "ap-northeast-1"` → `"us-east-1"`

### D. `staging` 残骸の削除

- `aws/github-oidc-auth/envs/staging/` ディレクトリごと削除
- `workflow-config.yaml` の `staging` 予約コメントブロックを削除

### E. リネーム対象 **外** の `k3d` 文字列

ツール名としての `k3d` を指すものは変更しない:

- `kubernetes/Makefile` の `k3d cluster create/delete/list` などの CLI コマンド
- `kubernetes/Makefile` の `CLUSTER_NAME ?= k8s-local`（k3d クラスタ名）
- `.github/renovate.json` の Cilium 説明文（k3d serverlb の挙動について）
- helmfile/values 等の中で「k3d 上での動作に関する技術的記述」を指す箇所

機械的に grep して洗い出した上で、「パス／環境名としての k3d」と「ツール名としての k3d」を一件ずつ判別する。

## Data Flow

### 修正後のフロー

```
PR 作成
  ↓
auto-label--label-dispatcher
  ↓ workflow-config.yaml の environments=[local, develop, production] を読む
  ↓ kubernetes/components/{service}/local/ を発見（kubernetes stack）
  ↓ aws/{service}/envs/{develop|production}/ を発見（terragrunt stack）
  ↓
PR にラベル付与
  ↓
auto-label--deploy-trigger
  ↓ kubernetes-targets-group: [{environment: local, services: [...]}]
  ↓
deploy-kubernetes-hydrate (matrix: env=local)
  ↓ make -C kubernetes hydrate-component COMPONENT=<svc> ENV=local
  ↓ make -C kubernetes hydrate-index ENV=local
  ↓ kubernetes/manifests/local/ を生成
  ↓ git auto-commit で kubernetes/manifests/local/ をプッシュ
  ↓
auto-commit が synchronize イベントを誘発 → label-dispatcher が再走
  ↓
deploy-kubernetes (matrix: target ごとに builder) で diff コメント
```

### `workflow-config.yaml` の `local` 環境定義

`label-resolver` の挙動に応じて 2 案を用意する:

**案 a（推奨）**: AWS フィールドを省略

```yaml
environments:
  - environment: local
    # local environment is kubernetes-only; no AWS fields

  - environment: develop
    aws_region: us-east-1
    iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role
    iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role

  - environment: production
    aws_region: ap-northeast-1
    iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-role
    iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-role
```

**案 b（フォールバック）**: `label-resolver` が必須なら空文字を入れる

```yaml
  - environment: local
    aws_region: ""
    iam_role_plan: ""
    iam_role_apply: ""
```

実装の Step 1 で `panicboat/deploy-actions/label-resolver` のソースを確認して案 a／案 b を決定する。

## Risks & Mitigations

### リスク 1: 稼働中の k3d クラスタへの影響

**該当無し。** 現時点で稼働中の k3d クラスタは存在しない。次回ローカルブートストラップ時に新パス（`kubernetes/clusters/local`）でセットアップされる。

### リスク 2: `panicboat/deploy-actions/label-resolver` が `local` の AWS フィールド欠落で落ちる

外部リポジトリ依存。実装の Step 1 で `panicboat/deploy-actions/label-resolver` のソースを確認し、必須なら案 b（空文字フィールド）にフォールバックする。

### リスク 3: `aws/ai-assistant/envs/develop` の region 変更でリージョナルリソースが再作成される

`ai-assistant` スタックが Bedrock 関連の CloudWatch Logs グループ等を含む場合、region 変更で `replace` 操作が発生する可能性がある。

**対策:**

1. `cd aws/ai-assistant/envs/develop && terragrunt plan` を実行
2. Plan 出力を目視確認: `destroy/replace` 操作が発生していないか
3. `replace` が出たら適用前に user 確認を仰ぐ
4. 同様に `aws/github-oidc-auth/envs/develop` でも plan 確認（IAM のみなので影響は小さい想定）

### リスク 4: `staging` ディレクトリ削除前の state 残存

`aws/github-oidc-auth/envs/staging/` の Terragrunt が過去に apply されていた場合、S3 backend (`terragrunt-state-559744160976`) に state が残り、対応する IAM ロールが AWS 上に残存する可能性がある。

**対策:**

1. 削除前に `cd aws/github-oidc-auth/envs/staging && terragrunt plan` で state 存在を確認
2. もし state があり実リソースが残っていれば、`terragrunt destroy` で先にクリーンアップ
3. その後ディレクトリ削除

## Verification Checklist

- [ ] `git grep -nE 'k3d' -- kubernetes/ workflow-config.yaml .github/workflows/ README*.md` の結果がツール名 `k3d` の参照のみ
- [ ] `make -C kubernetes hydrate ENV=local` がローカルで成功（クラスタ稼働は不要、テンプレート生成のみ）
- [ ] PR を作ったとき、`auto-label--label-dispatcher` が `kubernetes` ラベルを付与する
- [ ] `auto-label--deploy-trigger` の `deploy-kubernetes-hydrate` ジョブが起動し、`kubernetes/manifests/local/` への差分コミットが PR に追加される
- [ ] `auto-label--deploy-trigger` の `deploy-kubernetes` ジョブが diff コメントを投稿する
- [ ] `terragrunt plan` が `aws/github-oidc-auth/envs/develop`、`aws/ai-assistant/envs/develop` で意図通りの差分（region 関連のみ）

## Execution Order

各ステップを独立したコミットにする。

### Step 1: 事前確認（コード変更なし）

- `panicboat/deploy-actions/label-resolver` のソース確認 → `local` 環境で AWS フィールド欠落が許されるか判定
- `aws/github-oidc-auth/envs/staging/` の state 確認（`terragrunt plan`）。実リソースが残っていれば `terragrunt destroy` 先行
- 結果を実装プランに記録

### Step 2 + 3: ディレクトリリネームとファイル内文字列置換（1 コミット）

- 全 `git mv` を実行（中間状態を作らないため Step 3 と一緒にコミット）
- `kubernetes/Makefile`、`gotk-sync.yaml`、ワークフロー YAML、README、helmfile 等の参照を `local` に置換

### Step 4: `workflow-config.yaml` 更新（1 コミット）

- `local` 環境を追加（Step 1 結果に応じて案 a／案 b）
- `staging` 予約コメントブロック削除

### Step 5: AWS env.hcl の region 修正（1 コミット）

- `aws/github-oidc-auth/envs/develop/env.hcl`: `ap-northeast-1` → `us-east-1`
- `aws/ai-assistant/envs/develop/env.hcl`: `ap-northeast-1` → `us-east-1`
- 各ディレクトリで `terragrunt plan` を実行し、想定外の差分が無いことを確認した上でコミット

### Step 6: `staging` 残骸削除（1 コミット）

- `aws/github-oidc-auth/envs/staging/` ディレクトリ削除

### Step 7: PR 作成と CI 検証

- Draft PR で `gh pr create --draft`
- 上記の Verification Checklist を順に確認
- Hydrate コミットが追加されることを確認
- すべて緑になってからレビュー依頼
