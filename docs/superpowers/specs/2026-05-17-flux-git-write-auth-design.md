# Flux Git Write Auth Design

## Overview

Flux ImageUpdateAutomation が monorepo の `main` branch に bump commit を push しようとして失敗している (`authentication required: No anonymous write access.`)。原因は `flux-system` namespace の `monorepo` GitRepository が `secretRef` を持たず anonymous fetch / push になっているため。

本 spec は既存の panicboat GitHub App を流用して GitRepository に write 認証を与える。AWS Secrets Manager → External Secrets Operator (ESO) → Kubernetes Secret → Flux GitRepository (`provider: github` + `secretRef`) の流れで、Flux v2.4+ の GitHub App native support を利用する。

## Background

Phase 2 monorepo の Flux 連携設計 (2026-05-17-release-driven-flux-deploy-design.md) は完成して動作している:

- release-please tag → `auto-release--trigger.yaml` で semver image build → ghcr push
- Flux ImageRepository が ghcr scan、ImagePolicy が semver tag を pickup

ところが ImageUpdateAutomation が `overlays/production/deployment.yaml` を書き換える際に main branch への push 認証で失敗。Phase 2 設計時は「Flux 基盤は既存」と前提していたため、git push 権限の有無は検証外だった (= 既存 develop 環境では Flux が動作していたように見えたが、実は push 失敗のまま digest reflection だけ動いていた可能性)。

## Goal

- `monorepo` GitRepository に write 権限のある認証を付与
- ImageUpdateAutomation が main branch に bump commit を push できる状態
- Flux ImagePolicy が semver tag を pickup → ImageUpdateAutomation が overlay deployment.yaml の image tag を書き換え → main に panicboat[bot] による commit → kubelet 新 image pull → rollout、までの完全フロー成立

## Scope

### In scope

- `kubernetes/clusters/production/repositories/monorepo.yaml` (修正): GitRepository spec に `provider: github` + `secretRef` 追加、同 file に ExternalSecret resource を追加

### Out of scope

- GitHub App 自体の管理を Terragrunt (Terraform) 化 (= App は手動 UI 管理を継続、Installation の Terraform 管理も今回は見送り)
- AWS Secrets Manager の secret container を Terragrunt 化 (= 1 回限り console / CLI で put、Terraform 管理は今回は見送り)
- 既存 App から Flux 専用 App への分離 (= ひとり運用のため blast radius 管理コストが weight、既存 App を流用)
- 他リポ (platform 自身、deploy-actions、panicboat-actions) の Flux git push auth (= 今回は monorepo の問題に集中)

## Manual Prerequisites (User Actions)

本 spec を実装する前に、以下を手動で完了する必要がある。

### 1. 既存 panicboat App の credentials 取得

- GitHub Settings → Developer settings → GitHub Apps → 既存 panicboat App
- 確認: Permissions に `Contents: Read & Write` があること (release-please で commit 作成しているので付いている見込み、念のため verify)
- Installation ID 取得: 同 App の "Install App" / "Installations" セクションから panicboat/monorepo に install されている entry の ID
- App ID: App settings ページ top に表示
- Private key: 既に保有しているものを使用、または "Generate a private key" で新 key を生成 (.pem download)

### 2. AWS Secrets Manager に secret put

AWS console / CLI で secret を作成:

- Secret name: `panicboat/github-app/panicboat`
- Secret value (JSON):
  ```json
  {
    "appID": "<App ID>",
    "installationID": "<Installation ID>",
    "privateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
  }
  ```
- Region: cluster と同じ (ap-northeast-1)
- IAM: cluster の ESO IRSA role に当該 secret への `secretsmanager:GetSecretValue` 権限が付与されていること (= 既存 ClusterSecretStore `aws-secrets-manager` で他 secret が動いているため、命名規約 `panicboat/*` 配下なら既存 IAM policy で読めるはず、念のため verify)

## Target Architecture

### Data flow

```
[1] AWS Secrets Manager
    secret: panicboat/github-app/panicboat
    keys: appID / installationID / privateKey
    │
    │ ESO fetch (1h interval)
    ▼
[2] Kubernetes Secret (flux-system namespace)
    name: panicboat-github-app
    keys: github-app-id / github-installation-id / github-private-key
    │
    │ Flux source-controller 参照
    ▼
[3] GitRepository (flux-system / monorepo)
    spec.provider: github
    spec.secretRef.name: panicboat-github-app
    → source-controller が App token を生成 + 自動 refresh
    │
    │ token 使用
    ▼
[4] GitHub: https://github.com/panicboat/monorepo.git
    fetch + push に App token を使用 (= Contents: Read & Write)
    │
    │ ImageUpdateAutomation が同 GitRepository 経由
    ▼
[5] ImageUpdateAutomation (flux-system / monolith, frontend)
    sourceRef: GitRepository monorepo
    → GitRepository の認証を継承 → push 成功
```

### Why GitHub App (vs SSH Deploy Key / PAT)

- panicboat の既存 GitHub Actions auth が App ベース (release-please / auto-approve / semantic-pull-request すべて App)。Flux も同じパターンで統一感
- Token expire (~1h) を Flux source-controller v1.8.4 が自動 refresh (Flux v2.4+ で `provider: github` の native support)
- SSH Deploy Key は repo-level 永続だが、key rotation を別管理する必要 + panicboat の auth パターンから外れる
- PAT は個人紐付き、ひとり運用でも長期的に避けたい (退職想定 / accidental revoke)

## Component Design

### A. `kubernetes/clusters/production/repositories/monorepo.yaml` の修正

#### A-1. GitRepository spec への追加

```diff
 apiVersion: source.toolkit.fluxcd.io/v1
 kind: GitRepository
 metadata:
   name: monorepo
   namespace: flux-system
 spec:
   interval: 5m
   url: https://github.com/panicboat/monorepo.git
   ref:
     branch: main
+  provider: github
+  secretRef:
+    name: panicboat-github-app
```

- `provider: github` で Flux source-controller の GitHub App auth flow を有効化 (Flux v2.4+ で native support)
- `secretRef.name` で K8s Secret を参照、source-controller が App credentials を読んで token を取得 + 自動 refresh

#### A-2. ExternalSecret resource を同 file に追加

既存の GitRepository + Kustomization の後、`---` で区切って:

```yaml
---
# =============================================================================
# ExternalSecret: Sync GitHub App credentials from AWS Secrets Manager
# =============================================================================
# AWS Secrets Manager の `panicboat/github-app/panicboat` から App
# credentials (appID / installationID / privateKey) を flux-system の K8s
# Secret として sync し、GitRepository monorepo の write 認証に使う。
# AWS Secrets Manager 内の secret は user が console で 1 回手動で put した
# 既存 panicboat App の credentials (Contents: Read & Write 権限あり)。
# =============================================================================
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: panicboat-github-app
  namespace: flux-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: panicboat-github-app
    creationPolicy: Owner
  data:
    - secretKey: github-app-id
      remoteRef:
        key: panicboat/github-app/panicboat
        property: appID
    - secretKey: github-installation-id
      remoteRef:
        key: panicboat/github-app/panicboat
        property: installationID
    - secretKey: github-private-key
      remoteRef:
        key: panicboat/github-app/panicboat
        property: privateKey
```

- target K8s Secret 名 (`panicboat-github-app`) と secretKey 名 (`github-app-id` / `github-installation-id` / `github-private-key`) は **Flux source-controller の仕様で固定**: source-controller は GitRepository `secretRef` が指す secret から `github-app-id` / `github-installation-id` / `github-private-key` の key を読む。これらの命名を変えると Flux が認識しない
- AWS Secrets Manager 側の JSON property 名 (`appID` / `installationID` / `privateKey`) は user 自由 (= ExternalSecret の remoteRef.property で mapping するため、本 spec で命名統一)

### B. 既存 file の他箇所は変更なし

- `kustomization.yaml`: 同 dir で `monorepo.yaml` を resource として include 済み (= ExternalSecret が新規追加されても kustomize は同 file 内の全 resource を pick up)、変更不要
- 他 dir / resource: 変更不要

## Verification

Flux Kustomization (= `flux-system` Kustomization が platform リポを apply) の reconcile cycle (= 10m interval) が回ると、以下が順に成立する:

```bash
# Login first
eks-login production

# 1. ExternalSecret が SecretSynced True (= AWS Secrets Manager から取得成功)
kubectl get externalsecret -n flux-system panicboat-github-app

# 2. K8s Secret が作成され 3 keys が存在
kubectl get secret -n flux-system panicboat-github-app -o jsonpath='{.data}' | jq 'keys'
# 期待: ["github-app-id", "github-installation-id", "github-private-key"]

# 3. GitRepository が新 spec を反映 + READY True (= App token 生成成功)
kubectl get gitrepository -n flux-system monorepo
kubectl describe gitrepository -n flux-system monorepo  # auth エラーがないこと

# 4. ImagePolicy が semver tag を pickup (= 既存修正 PR #632 で spec 修正済、本 spec の前提)
kubectl get imagepolicy -n flux-system monolith \
  -o jsonpath='{.status.latestImage}'
# 期待: ghcr.io/panicboat/monorepo/monolith:v0.2.0 (= 最新 release tag)

# 5. ImageUpdateAutomation が auth エラーなく READY True
kubectl get imageupdateautomation -n flux-system
kubectl describe imageupdateautomation -n flux-system monolith | tail -10  # status conditions

# 6. Flux が main に bump commit を push
gh api repos/panicboat/monorepo/commits --jq '.[0:5] | .[] | "\(.sha[0:8]) \(.commit.author.name) \(.commit.message | split("\n")[0])"'
# 期待: 上位に panicboat[bot] author の "chore(monolith): bump image to ghcr.io/.../monolith:v0.2.0" 形式の commit

# 7. main の overlay deployment.yaml が semver tag に書き換わっている
bash -c 'gh api repos/panicboat/monorepo/contents/services/monolith/kubernetes/overlays/production/deployment.yaml --jq ".content" | base64 -d | grep image:'
# 期待: image: ghcr.io/panicboat/monorepo/monolith:v0.2.0

# 8. production cluster の rollout が完了
kubectl rollout status deployment/monolith
```

各 step が期待通りなら Phase 2 monorepo の end-to-end フローが完全に動作する状態。

## Risks and Mitigations

| Risk | 緩和策 |
|---|---|
| 既存 panicboat App に Contents: Write 権限がない | Manual Prerequisites 1 で事前確認 (release-please で commit 作成しているので付いている見込みだが verify) |
| App private key を AWS Secrets Manager に put する際の format ミス (改行コード, escape) | JSON で `privateKey` の値は `\n` で改行を表現、または multi-line YAML で put。AWS console で put 後 ESO がパースできるか動作確認 |
| ESO の IRSA role が `panicboat/flux/*` 配下の secret 読み取り権限を持たない | 既存 IAM policy が `panicboat/*` 配下を許可しているか事前確認、必要なら IAM policy 拡張 |
| Flux source-controller の `provider: github` が v1.8.4 では未 support | source-controller v1.8.4 (= Flux 2.4+ 相当) は GitHub App provider を native support。要確認、もし未対応なら controller upgrade or SSH Deploy Key fallback |
| App token expire (1h) で Flux が refresh を怠る | source-controller v1.8.4 で自動 refresh 仕様。controller log で `token refresh` 系の error が出ないか初回動作後にチェック |
| ImageUpdateAutomation の git push が走るたびに App token を消費する | App token は短期 (1h) + 自動 refresh、長期 quota はないので問題なし。GitHub API rate limit (= App は 5000 req/h) も実用上問題なし |

## Implementation Order

1 PR で完結:

1. `kubernetes/clusters/production/repositories/monorepo.yaml` を修正 (GitRepository spec に provider + secretRef 追加 + ExternalSecret resource 追加)
2. `feat(flux):` で commit、draft PR 作成
3. PR の CI (lint-actions / semantic-pull-request / CI Gatekeeper) が通る
4. PR を Ready & マージ
5. flux-system Kustomization の reconcile (~10m interval) を待つ
6. Verification 1-8 を順次確認

ユーザーは事前に Manual Prerequisites (1, 2) を完了している前提。

## Notes

- 本 spec はゼロから新規構築ではなく、既存 Flux 基盤の git auth 不備を補修する内容。失敗が観測されているのは monorepo GitRepository のみ (= platform リポ自身は GitRepository `flux-system` で同様に public read で動いており、もし将来 platform に対しても ImageUpdateAutomation を入れる場合は同パターンを適用する)
- 命名 `panicboat-github-app` は panicboat org の GitHub App credentials を持つ汎用名。中身は既存 panicboat App (release-please / auto-approve / semantic-pull-request 等で共有されている App) と同一。将来 Flux 以外の用途で同 K8s Secret を参照する場合も流用可能。AWS Secrets Manager key は `panicboat/<service>/<name>` の既存命名規約に倣い `panicboat/github-app/panicboat` (service=`github-app`、name=`panicboat` org)
- AWS Secrets Manager の secret value (= App private key) は Terraform 管理せず手動 put のため、`lifecycle.ignore_changes = [secret_string]` 等の Terraform リソースは作らない (= 完全に外部管理)
