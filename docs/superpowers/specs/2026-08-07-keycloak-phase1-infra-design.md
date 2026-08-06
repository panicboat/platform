# Keycloak Phase 1: Infrastructure Deploy

> **Goal**: dystopia (monorepo) の現行ログイン機能を将来的に Keycloak (IAM) へ移行する構想の第一歩として、**Keycloak を EKS production 上で動かし、管理者コンソールにログインできる状態にする**。対象は `platform` リポジトリのみ。dystopia アプリ側 (monorepo) の変更は Phase 2 以降で別 spec とする。

---

## 1. 背景

dystopia (monorepo) の `services/monolith` は電話番号 + パスワードによる自前認証を実装済み (bcrypt, 自前 JWT, リフレッシュトークン, SMS 認証, ログイン失敗ロックアウト)。これを Keycloak に置き換える構想があるが、導入者は Keycloak 未経験のため、まずは検証を兼ねて実物を動かすところから始める。

dystopia は未リリースのため、production 環境で直接試しても実害がない。この前提のもと、検証環境を別途作らず production クラスタ上に構築する。

---

## 2. スコープ

### Phase 1 に含む

- Keycloak を EKS production クラスタにデプロイ
- Keycloak 用 PostgreSQL backend の構築
- `https://auth.dystopia.city` での公開 (管理者コンソールへの到達性確保)

### Phase 1 に含まない (明示的スコープ外)

- dystopia 用 realm / client の作成
- monolith / frontend との認証連携 (monorepo 側の変更は一切なし)
- PostgreSQL の HA / バックアップ構成

---

## 3. 採用アーキテクチャ

### 3.1 コンポーネント構成

既存の `platform/kubernetes/components/<name>/` 配下の helmfile パターン (`loki`, `oauth2-proxy` 等) を踏襲し、2 つの独立コンポーネントとして追加する。

```
platform/kubernetes/components/
  cloudnative-pg/   … CloudNativePG operator (cluster 共有、Keycloak 専用ではない)
  keycloak/         … Keycloak 本体 + Postgres Cluster CR + Ingress + ExternalSecret
```

`cloudnative-pg` を独立コンポーネントにするのは、`cert-manager` や `external-secrets` のように operator 本体と、それを利用する側 (`keycloak` の `Cluster` CR、`oauth2-proxy` の `ExternalSecret` 相当) を分離する既存の慣習に合わせるため。

### 3.2 Chart 選定: `codecentric/keycloakx`

Keycloak プロジェクト自身は素の Helm chart を公式提供していない (公式が推すのは CRD ベースの Keycloak Operator)。community chart から選定する必要がある。

| 候補 | 採否 | 理由 |
|---|---|---|
| `bitnami/keycloak` | 不採用 | chart の最終更新が約1年前で停止しており、Keycloak 本体の最新版に追従できていない。Broadcom による2025年のライセンス変更以降、無料枠のメンテナンス継続性に懸念がある |
| Keycloak Operator (公式) | 不採用 (Phase 1 では) | CRD ベースの独自の運用モデルを新たに学ぶ必要があり、「まず動かして概念を理解する」という Phase 1 の目的に対して学習コストが過大。Keycloak の基本概念に慣れた後の移行先としては有力 |
| `codecentric/keycloakx` | **採用** | 直近まで継続更新されており (確認時点で Keycloak 26.6.4 に対応)、Bitnami 以前から実績のある community chart |

### 3.3 DB backend: CloudNativePG

Keycloak は realm / user / client / session を全て DB に永続化する設計であり、DB なしでは Pod 再起動のたびに状態が失われる。何らかの永続 DB は必須。

| 候補 | 採否 | 理由 |
|---|---|---|
| AWS RDS PostgreSQL | 不採用 | `platform` リポジトリに RDS を直接定義した前例が無い。既存の確立方針 (`docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md`) では「DB はそれを使うアプリ開発者が所有する (= monorepo 側 terragrunt で管理)」とされている。Phase 1 を `platform` リポジトリのみに絞った以上、RDS 新設はこの既存方針と今回のスコープ決定の両方に反する |
| 素の Postgres (Deployment/StatefulSet + PVC 手書き) | 不採用 | 動作はするが、このクラスタは cert-manager / external-secrets / karpenter / aws-load-balancer-controller など「operator (CRD) 経由で管理する」パターンが定着しており、これに合わない。将来 HA やバックアップを足す際に作り直しが必要になりやすい |
| **CloudNativePG (CNPG)** | **採用** | CNCF Sandbox、EDB (PostgreSQL の主要コントリビューター) が主導する信頼性の高い operator。`Cluster` CR 一つで初期ユーザー/DB作成・接続用 Secret 発行・TLS まで完結し、既存の operator パターンに合致する。将来 HA / バックアップ (S3連携) が必要になっても CR の設定変更で拡張でき、作り直しにならない |

Phase 1 の `Cluster` は単一インスタンス構成とし、HA・バックアップは組み込まない (2章のスコープ外を参照)。

### 3.4 公開経路

- host: `auth.dystopia.city`
- 既存の共有 ALB (`alb.ingress.kubernetes.io/group.name: application`) に Ingress を追加する形で相乗りする。`monolith`/`frontend` の Ingress や `oauth2-proxy` の monitoring-uis Ingress と同一パターン
- `*.dystopia.city` の wildcard ACM 証明書が ALB Controller により自動アタッチされる (explicit certificate-arn 不要)
- `external-dns` により Route53 record が自動作成される

### 3.5 Secrets の扱い

| 対象 | 方式 |
|---|---|
| Keycloak 管理者の初期パスワード | AWS Secrets Manager (`panicboat/keycloak/admin`) を ExternalSecret 経由で K8s Secret に同期する。`oauth2-proxy-google` と同一パターン。PR マージ後、`aws secretsmanager put-secret-value` による初期値投入が手動作業として発生する (`monolith-database` の初期化と同様) |
| PostgreSQL 接続情報 | CNPG が `Cluster` 作成時に自動生成する K8s Secret をそのまま参照する。RDS と異なりクラスタ内で完結するため、AWS Secrets Manager は経由しない |

---

## 4. 完了条件 (Phase 1 の Definition of Done)

- `helmfile apply` が `cloudnative-pg` / `keycloak` 両リリースで成功する
- CNPG `Cluster` が healthy 状態になる
- Keycloak Pod が Ready になる
- `https://auth.dystopia.city` でログイン画面が開き、TLS が有効な状態で表示される
- 発行した初期パスワードで管理者コンソールにログインできる

---

## 5. Phase 2 への申し送り事項

- dystopia 用 realm / client の設計
- monolith の電話番号+SMS 認証モデルと、Keycloak が前提とする email/username モデルの差分をどう吸収するか
- monolith (gRPC) / frontend (Next.js) の認証フローを Keycloak 連携にどう置き換えるか
