# release-please Phase 2: Production Deploy Trigger Design

## Overview

Phase 1([2026-05-16-release-please-rollout-design.md](2026-05-16-release-please-rollout-design.md))で `platform` に導入した release-please を、production への deploy トリガーとして活用する。

現状、production への自動 deploy は aws (terragrunt) 側が完全に存在せず(`workflow-config.yaml` の `environments.production` が開発フェーズのコスト最適化のため意図的にコメントアウトされている)、手動デプロイに頼っている。kubernetes (Flux) 側は逆に `main` ブランチを継続的に追従しており、ゲートが一切ない。

本 spec は、release-please の `release: published` イベントを「production に対して明示的に行われた deploy 判断」の起点とし、aws・kubernetes 双方の production 反映を release 起点で揃える設計を定める。

## Scope

### In scope

- production 環境のみ
- aws (`aws/{service}`) のうち `production/` ディレクトリを持つ service を release-please manifest mode の component として管理し、release published を terragrunt apply の起点にする
- kubernetes を release-please manifest mode の component として管理し、release published を Flux の追従先切り替えの起点にする
- `workflow-config.yaml` への `production` 環境定義の追加(IAM role / region)
- 既存の自動 push トリガー pipeline(`auto-label--deploy-trigger.yaml`)が production を誤って巻き込まないための明示的な environment 固定

### Out of scope

- `develop` 環境(常時起動していないため deploy トリガーの対象にしない)
- `github/{service}`(`master` 専用で `production` ディレクトリを持たないため対象外)
- release-please PR のレビュー・マージ運用そのものの改善(auto-merge 導入など)。本設計は「レビュー速度が改善される」ことを前提にしているが、その改善策自体は別途検討する
- Renovate の `semanticCommitType` 変更、CHANGELOG の `chore` セクション可視化(検討したが採用しない、後述)

## 検討して採用しなかった案(Why not)

設計の背景として、検討済みで不採用にした案を残す。

- **GitHub Environments の Required reviewers による承認ゲート**: production 用の `environment:` を job に追加し、承認待ちにする案。しかし現状 `workflow-config.yaml` の `environments.production` がコメントアウトされているのは「開発フェーズ中は production に対して CI を極力動かしたくない」という意図的な選択であり、この案は push のたびに CI が解決処理を実行してしまうため、その意図と逆行する。release published という「稀にしか起きない、人が明示的に起こす」イベントの方が意図に合致する
- **既存の label-resolver / label-dispatcher パイプラインをそのまま production に拡張する**: `deploy-actions` の実装を確認したところ、`deploy:{service}` ラベルは `{environment}` 情報を破棄しており(`label-dispatcher/use_cases/detect_changed_services.rb` 参照)、resolver 側は呼び出し時に渡された `environments:` を(未指定ならconfig全キーに)ループしてディレクトリ存在だけで target を作る。つまりラベルの仕組みは構造的に「どの environment が実際に変更されたか」を見ていない。`production` を有効化すると、`master` だけを変更した PR でも `production` に(何も変更していないのに)apply が走りかねない。この経路には手を入れず、production は完全に独立した経路にする
- **Renovate の `semanticCommitType` を `fix` に変更する**: release-please に `chore` コミットを拾わせる目的で検討したが、実際に release-please のソース(`src/versioning-strategies/default.ts`)を確認した結果、**`feat`/breaking 以外のコミットは既定で patch bump される**ことが判明した(`chore` かどうかは version bump の判定に影響しない)。影響するのは CHANGELOG 本文への表示可否のみ(`src/util/filter-commits.ts` の `DEFAULT_CHANGELOG_SECTIONS` で `chore` は `hidden: true`)。よって `semanticCommitType` の変更は不要と判断し、Renovate 側の設定は一切変更しない
- **CHANGELOG の `chore` セクションを可視化する**(`changelog-sections` で `hidden: false` にする): 技術的には可能だが、今回は既定の非表示のままとする

## Component 構成

`release-please-config.json` を manifest mode に切り替え、以下の component を管理する。

### aws (terragrunt) — production ディレクトリを持つ service のみ

`aws/{service}/production/` が存在する service を対象にする(存在しない service は master/org 専用のため対象外)。2026-09-06 時点のスナップショット:

| component | 対象 |
|---|---|
| alb | ✅ |
| eks | ✅ |
| eks-holmesgpt | ✅ |
| eks-karpenter | ✅ |
| eks-logs | ✅ |
| eks-metrics | ✅ |
| eks-secrets | ✅ |
| eks-traces | ✅ |
| github-oidc-auth | ✅ |
| iam-service-linked-roles | ✅ |
| vpc | ✅ |
| cost-management | ❌ (master 専用、production ディレクトリなし) |
| karpenter | ❌ (production ディレクトリなし、`eks-karpenter` に統合済みの可能性) |
| route53 | ❌ (master 専用、production ディレクトリなし) |

実装時は `aws/*/production/` の実在チェックで対象を再確認し、上記スナップショットとの差分があれば実態を優先する。

**実装時の追記:** 実装時点で `aws/secrets-manager/production/` が新規に存在していた(このスナップショット作成後にマージされた PR #885 由来)。実測に合わせて `secrets-manager` を component に追加し、対象は 12 service になった。

各 component:

```json
"aws/{service}": {
  "release-type": "simple",
  "component": "{service}",
  "include-component-in-tag": true
}
```

tag は `{service}-vX.Y.Z` 形式(例: `eks-v1.2.0`)。バージョンファイルの同期先はない(Phase 1 と同じ理由、terragrunt に version.rb 相当のファイルがない)。

### kubernetes — 1 component

```json
"kubernetes": {
  "release-type": "simple",
  "component": "kubernetes",
  "include-component-in-tag": true
}
```

root は `kubernetes/` 配下全体(`kubernetes/components/`、`kubernetes/clusters/`)。Flux の `GitRepository` は cluster 全体に対して1本の ref しか持てず、per-service に分割しても deploy 粒度が上がらないため、component は1つに集約する。

### release-please-config.json (全体像)

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<導入 PR のベース main HEAD SHA>",
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
    "aws/secrets-manager": { "release-type": "simple", "component": "secrets-manager", "include-component-in-tag": true },
    "aws/vpc": { "release-type": "simple", "component": "vpc", "include-component-in-tag": true },
    "kubernetes": { "release-type": "simple", "component": "kubernetes", "include-component-in-tag": true }
  }
}
```

`.release-please-manifest.json` は各 component の現在バージョン(state)。既存の Phase 1 tag(`v0.1.0`)は non-manifest 時代のものなので、manifest 移行後の各 component は改めて `0.1.0` から開始する。

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
  "aws/secrets-manager": "0.1.0",
  "aws/vpc": "0.1.0",
  "kubernetes": "0.1.0"
}
```

### 既存 Phase 1 設定からの移行

現行の `release.yml` は non-manifest(`release-type: simple` を `with:` に直書き)。Phase 2 で manifest mode に切り替えるため、既存の `with:` 設定は `release-please-config.json` / `.release-please-manifest.json` に置き換わる。

現在 open している release PR(#422, `chore(main): release 1.0.0`)は非 manifest 時代の1コンポーネント構成を前提にしており、manifest mode 切り替え後は成立しない。**実装時にこの PR は merge せず close する**(4ヶ月分の CHANGELOG が失われるが、Phase 1 の CHANGELOG.md 自体は残るため履歴は追える)。

## Deploy Flow

### aws: release published → terragrunt apply

label-resolver / label-dispatcher は経由しない。新規 workflow(例: `release-deploy.yml`、`on: release: types: [published]`)で以下を行う。

1. `github.event.release.tag_name` を `^(?<component>[a-z0-9-]+)-v\d+\.\d+\.\d+$` でパースし `component` を取得
2. `component` が aws component 一覧に含まれる場合、`workflow-config.yaml` の `production` エントリから `iam_role_apply` / `aws_region` を(`yq` 等で直接)取得
3. `reusable--terragrunt-executor.yaml` を `service-name: {component}`, `environment: production`, `action-type: apply`, `working-directory: aws/{component}/production` で呼び出す

tag 名から component を直接特定できるため、Phase 1 で検討した「release PR に `deploy:all` ラベルを付けて `jwalton/gh-find-current-pr` で辿る」という間接的な方式は不要。

### kubernetes: release published → Flux 追従先の切り替え

1. `component` が `kubernetes` の場合、GitHub App token で固定タグ(例 `kubernetes-production`)を release の対象コミットへ force-update する

```bash
git tag -f kubernetes-production ${{ github.sha }}
git push origin kubernetes-production --force
```

(`panicboat-actions` の `v0` major tag force-update と同じパターン)

2. `kubernetes/clusters/production/flux-system/gotk-sync.yaml` の `GitRepository.spec.ref` を、本設計の導入時に一度だけ `branch: main` → `tag: kubernetes-production` に変更する。以降はタグが動くだけで、このファイルへの変更は不要

3. hydrate/build(`reusable--kubernetes-hydrator.yaml` / `reusable--kubernetes-builder.yaml`)は無変更。これらは PR マージ時点で `kubernetes/manifests/production/` を確定させる工程であり、Flux が「いつ」その状態を読むかとは独立している。release tag が指すコミットの時点で、hydrate は release を待たずに既に完了している

## 既存自動パイプラインとの分離(緊急度高)

`workflow-config.yaml` の `production` は本 spec 検討中に #884(`chore(workflow-config): enable production for CI-driven deploy automation`)で**既に有効化済み**。しかし `auto-label--deploy-trigger.yaml` の Label Resolver ステップは `environments:` を指定しておらず `workflow-config.yaml` の `environments` 全キーがデフォルトになる(`label-resolver/bin/resolver` の `parse_environments(nil)` 参照)。そのため #884 以降、**既存の自動パイプライン(push トリガー・PR ラベルベース)が production も対象にしてしまっている**。

`master` と `production` を両方定義しているのは現時点で `github-oidc-auth` のみ(他 service は production か master の一方のみ定義)。`deploy:{service}` ラベルは environment を区別しないため、`aws/github-oidc-auth/master/` だけを変更した PR でも resolver は `master`・`production` 両方をターゲットに含めてしまい、**変更していない production にも terragrunt apply が実行されている可能性がある**。`github-oidc-auth` は直近6ヶ月で47コミットと変更頻度が高く、影響は無視できない。

このため `auto-label--deploy-trigger.yaml` の Label Resolver 呼び出しに `environments: master` を明示的に指定する修正は、**本設計の実装の中で最優先(他のタスクより先)に対応する**。これにより:

- 自動パイプライン(push トリガー・PR ラベルベース)は `master` のみを対象にし続ける(#884 以前の意図された挙動に戻す)
- production は本設計の release-published トリガーのみが唯一の deploy 経路になる(継続的パイプラインと release-gated パイプラインが同じ production を二重に扱う状態を解消する)

## workflow-config.yaml

`production` エントリは #884 で既に有効化済み(本設計側での追加作業は不要)。IAM role / region はこの値を新規 workflow(`release-deploy.yml`)が参照する。

```yaml
environments:
  - environment: master
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-plan-role
        iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-apply-role

  - environment: production
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-plan-role
        iam_role_apply: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-apply-role
```

(`develop` は out of scope のためコメントアウトのまま維持する。account ID / role 名は既存のコメントアウト済み記述を踏襲、実装時に実在する role であることを確認する。)

## Renovate との関係

`renovate.json` は変更しない。

- `production/** ` は既に `automerge: false` になっており、Renovate PR も人が merge するまで main に入らない(既存の deliberate gate)
- merge された commit(`chore:` 含む)は release-please の既定動作により patch bump 対象になり、release PR に積まれる。CHANGELOG 上は `chore` セクションが非表示のままなので見た目は変わらないが、release / deploy トリガーとしては機能する

## SHA Pinning / GitHub App

Phase 1 と同じ(`actions/create-github-app-token`、`googleapis/release-please-action`、既存 GitHub App)。新規追加する `release-deploy.yml` の `actions/checkout` 等も同一の SHA-pinning 方針に従う。

## Verification

- [ ] **(最優先)** `auto-label--deploy-trigger.yaml` の Label Resolver 呼び出しに `environments: master` が明示され、#884 以降の production 誤爆リスク(`github-oidc-auth` 等)が解消されている
- [ ] `release-please-config.json` / `.release-please-manifest.json` が manifest mode で追加され、対象 component(aws 12 + kubernetes 1)が定義されている
- [ ] 既存の release PR #422 が close されている(manifest mode 移行に伴い）
- [ ] `aws/{service}` の release PR をマージ・release published すると、対応する service だけ production に terragrunt apply される(他 service・他 environment に影響しない)
- [ ] `kubernetes` の release PR をマージ・release published すると、`kubernetes-production` タグが移動し、Flux が新しい manifest を反映する
- [ ] `gotk-sync.yaml` の `ref` が `tag: kubernetes-production` に切り替わっている
- [ ] master 向けの既存自動パイプラインが従来通り動作し、production に影響しない
