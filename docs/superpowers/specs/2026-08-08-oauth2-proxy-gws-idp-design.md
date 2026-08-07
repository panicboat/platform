# oauth2-proxy GWS IdP Migration

> **Goal**: monitoring UIs 4 host の認証入口を、個人 Google アカウント + email allowlist から Google Workspace `panicboat.net` のドメイン判定に切り替える。Grafana の role 分けは本 spec の範囲外。

---

## 1. Current State

### 認証経路

```
ブラウザ → ALB (host-based routing)
         → oauth2-proxy-{grafana,hubble,alertmanager,prometheus}
         → Google OAuth
         → X-Forwarded-User header
         → 各 UI
```

- oauth2-proxy は 4 release 構成 (= 1 release / backend)。cookie domain `.panicboat.net` + `cookie_secret` 共有で 4 host SSO
- `provider = "google"`、`email_domains = [ "*" ]`
- 実際の絞り込みは ConfigMap `oauth2-proxy-allowed-emails` の `authenticated_emails_file` (= `panicboat@gmail.com` 1 行のみ)
- Grafana は `auth.proxy` で `X-Forwarded-User` を信頼、`auto_sign_up: true` / `auto_assign_org_role: Admin`
- OAuth client 資格情報は AWS Secrets Manager `panicboat/oauth2-proxy/google` (= ESO 経由で K8s Secret へ sync)。secret の値は Terraform 管理外、IAM role のみ `aws/eks-secrets` が管理

### GWS 側

`aws/route53` が `panicboat.net` と `dystopia.city` の 2 zone に対して Google Workspace の MX / DKIM / site-verification record を管理している。両ドメインとも MX は `smtp.google.com`。

AWS IAM Identity Center と GWS の連携は terragrunt に存在しない (= コード化されていない)。

### 問題

認可の単位が個人 Google アカウント 1 件の allowlist であり、GWS のユーザー管理と接続していない。メンバーを追加するたびに ConfigMap を編集して rollout する必要がある。

---

## 2. Constraints

設計判断に影響する事実。すべて一次情報で確認済み。

### Google 側の設定は Terraform で管理できない

- 標準の OAuth 2.0 Client ID (Web application) を作成する Terraform リソースは存在しない。要望 issue [#6074](https://github.com/hashicorp/terraform-provider-google/issues/6074) / [#16452](https://github.com/hashicorp/terraform-provider-google/issues/16452) は未クローズ
- [`google_iam_oauth_client`](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_oauth_client) は Workforce Identity Federation 専用 (= Identity-Aware Proxy 限定) で用途が異なる
- GWS の custom SAML app を作成する Terraform リソースも存在しない

したがって **どの方式を採っても Google 側の初期設定は console での手動操作になる**。

### OAuth consent screen の Internal user type

[Internal](https://support.google.com/cloud/answer/15549945) に設定した OAuth client は、その Google Cloud org (= GWS テナント) のメンバーのみに認可要求を制限する。Google の審査もテストユーザー登録も不要。

### GWS テナントが 2 ドメインを持つ

`panicboat.net` と `dystopia.city` が同一 Workspace テナントの場合、Internal 制限は `dystopia.city` のユーザーも通す。Google 側の制限だけでは `panicboat.net` に絞れない。

### Amazon Cognito の料金

SAML / OIDC federation 経由のユーザーは 50 MAU まで無料、超過分は $0.015/MAU ([Amazon Cognito Pricing](https://aws.amazon.com/cognito/pricing/))。

### Grafana OSS の auth.proxy は group を role に変換できない

- oauth2-proxy が upstream に渡すのは `X-Forwarded-Groups` (= group 名のカンマ連結)
- Grafana の `[auth.proxy]` `headers` は `Role:X-WEBAUTH-ROLE` を解釈するが、ヘッダ値をそのまま role 名として読む。group 名 → role 名の変換機構がない
- `Groups` ヘッダ経由の Team Sync は Grafana Enterprise 限定
- さらに oauth2-proxy の Google group 制限 (`--google-group`) は、domain-wide delegation を持つ service account + Admin SDK scope `admin.directory.group.member.readonly` を要求する

---

## 3. Approach

### 採用: GCP プロジェクト + Internal OAuth client

`panicboat.net` の GWS に付随する Google Cloud org 配下にプロジェクトを 1 つ作り、Internal の OAuth client を発行する。oauth2-proxy は `provider = "google"` のまま client 資格情報を差し替え、許可判定を allowlist ファイルから `email_domains` に移す。

- 新規コンポーネントなし。構成要素の増減ゼロ
- コスト $0 (= プロジェクト作成・OAuth 認証とも無料、課金アカウント紐付け不要)
- terragrunt の変更ゼロ

### 却下: AWS Cognito user pool + GWS SAML federation

GWS の custom SAML app を Cognito user pool に SAML IdP として登録し、user pool app client を OIDC provider として oauth2-proxy から利用する案。

`aws/cognito` module を新設すれば user pool / SAML IdP / app client / client secret が terragrunt 管理下に入る。しかし Constraints のとおり **GWS 側の SAML app 作成は手動のまま残る**ため、「Google 側の手動作業をなくす」効果はない。terragrunt 管理下に入るのは自分で追加した中間層だけであり、採用案ではその中間層自体が存在しない。認証経路に常時稼働のコンポーネントを 1 つ増やす代償に見合わない。

### 却下: Keycloak / Dex を EKS 上で運用

SAML → OIDC bridge を自前で持つ案。PostgreSQL とアップグレード運用が発生する。現在のメンバー規模に対して運用コストが釣り合わない。

---

## 4. Design

### 認証フロー

```
ブラウザ → ALB (host-based routing)
         → oauth2-proxy-{grafana,hubble,alertmanager,prometheus}
         → Google OAuth (Internal client)     ← GWS テナントのメンバーのみ
         → email_domains チェック               ← panicboat.net のみ
         → X-Forwarded-User: <user>@panicboat.net
         → 各 UI
```

### ドメイン判定を 2 段に持つ理由

Internal client は GWS テナント境界を守り、`email_domains` は monitoring UIs の利用者境界 (= `panicboat.net` のみ) を守る。守る対象が異なるため冗長ではない。

`dystopia.city` が同一テナントの追加ドメインである場合、テナント境界は `panicboat.net` より広くなり、`email_domains` が実際の絞り込みを担う。別テナントである場合は Internal 制限だけで足りるが、その場合も `email_domains` はテナント構成の変更に対する防御として残す価値がある。どちらであるかは GWS Admin console でのみ確認でき、terragrunt からは判別できない (= DNS record は両ドメインとも Google 宛だが、テナントが同一かは示さない)。

### Google 側の手動セットアップ

1. `panicboat.net` の GWS に紐づく Google Cloud org 配下にプロジェクトを作成 (= 初回のみ Cloud 利用規約の承諾が必要)
2. Google Auth Platform を **Internal** user type で構成
3. OAuth 2.0 Client ID (Web application) を作成。Authorized redirect URIs は 4 件:
   - `https://grafana.panicboat.net/oauth2/callback`
   - `https://hubble.panicboat.net/oauth2/callback`
   - `https://alertmanager.panicboat.net/oauth2/callback`
   - `https://prometheus.panicboat.net/oauth2/callback`
4. AWS Secrets Manager `panicboat/oauth2-proxy/google` の `client_id` / `client_secret` を新しい値に更新

`cookie_secret` は更新しない。4 release が共有する SSO 用の鍵であり、client 差し替えとは独立している。

ESO が `refreshInterval: 1h` で K8s Secret を同期し、Reloader が 4 Deployment を rollout する。

### リポジトリ変更

| ファイル | 変更 |
| --- | --- |
| `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl` | `email_domains` を `[ "*" ]` → `[ "panicboat.net" ]`。`authenticated_emails_file` 行を削除。`extraVolumes` / `extraVolumeMounts` の emails mount を削除。該当コメントを現在の構成の記述に更新 |
| `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml` | 削除 |
| `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml` | `allowed-emails-configmap.yaml` の参照を削除 |
| `kubernetes/components/oauth2-proxy/production/helmfile.yaml` | ヘッダコメントの email allowlist に関する記述を更新 |

`external-secret.yaml` は secret のキー構成が変わらないため変更しない。terragrunt も変更しない。

`kubernetes/manifests/production/oauth2-proxy/manifest.yaml` は hydrate 生成物。CI (`.github/workflows/reusable--kubernetes-hydrator.yaml`) が PR ブランチに再生成結果を commit する。

---

## 5. Out of Scope

### Grafana の role 分け

`auto_assign_org_role: Admin` は変更しない。allowlist 撤廃により `panicboat.net` の全ユーザーが Grafana Admin になるが、権限境界は GWS のユーザー管理に移る。

Constraints のとおり、`auth.proxy` を維持したまま group を role に変換する手段は「GWS group を `Admin` / `Editor` / `Viewer` と命名する」以外にない。role 分けが必要になった時点で、Grafana のみ `auth.proxy` をやめて native OIDC に移行する別サブプロジェクトとして扱う。

### 既存 Grafana ユーザー

ログイン ID が `panicboat@gmail.com` → `panicboat@panicboat.net` に変わるため、Grafana 上は別ユーザーとして新規作成される。dashboard は sidecar プロビジョニングで org 単位のため影響しない。star とユーザー個人設定は引き継がれない。旧ユーザーはログイン経路を失うだけで残存する。

### 旧 OAuth client

ロールバック手段として当面残す。削除時期は本 spec の範囲外。

---

## 6. Verification

1. `bash scripts/kubernetes-hydrate/hydrate-component.sh oauth2-proxy production` の差分が意図どおり
   - `email_domains` が 4 箇所とも `[ "panicboat.net" ]`
   - `authenticated_emails_file` 行が 4 箇所とも消える
   - emails volume / volumeMount が 4 箇所とも消える
   - ConfigMap `oauth2-proxy-allowed-emails` 本体が消える
2. rollout 後、4 host すべてに `panicboat.net` アカウントでログインできる
3. `gmail.com` アカウントでログインを試み、拒否される
   - この経路で拒否するのは Google 側の Internal 制限 (= `access_denied`)。oauth2-proxy の `email_domains` には到達しない
   - `email_domains` 自体を通す検証には同一テナント内の別ドメインのアカウントが必要。用意できない場合は未検証項目として扱い、成功報告に含めない
4. Grafana にログインし、ユーザーが `@panicboat.net` で Admin として作成されている

---

## 7. Rollback

1. AWS Secrets Manager `panicboat/oauth2-proxy/google` の `client_id` / `client_secret` を旧 OAuth client の値に戻す
2. コード変更を revert し、hydrate 生成物を再生成する

旧 OAuth client を残しておく限り、Google 側の再作成なしで戻せる。
