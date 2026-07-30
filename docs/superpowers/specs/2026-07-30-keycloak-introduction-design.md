# Keycloak Introduction (Phase 1: Core Infra) Design

> **Goal**: toC 向けアプリケーションの認証基盤として Keycloak を production EKS に導入する。RDS PostgreSQL + Keycloak (codecentric/keycloakx chart) を `auth.dystopia.city` で公開し、Google ソーシャルログインを Identity Provider federation で有効化する。
>
> **Phase 2 (別 spec)**: 電話番号 (SMS OTP) 認証。外部 SMS provider 連携 + custom 実装が必要なため本 Phase の scope 外。

---

## Context

- panicboat.net (非公開 monitoring UIs) は既に oauth2-proxy + Google OAuth で認証ゲート済 (= `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`)。
- dystopia.city (公開 application ドメイン) は無認証で公開中 (= `docs/superpowers/specs/2026-05-17-dystopia-city-migration-design.md`)。`*.dystopia.city` ACM wildcard cert 発行済、ALB IngressGroup `application` で 1 ALB 共有、external-dns の domainFilters に `dystopia.city` 追加済。
- toC アプリ (= application monorepo、本 repo 外) 向けの user 認証基盤が不在。Keycloak を IdP として導入し、`auth.dystopia.city` で OIDC を提供する。
- 本 repo にはこれまで RDS / Postgres の provisioning パターンが存在しない (= 新規)。VPC module (`aws/vpc/modules`) は `database_subnets` + `create_database_subnet_group = true` で DB subnet group を既に provision 済、RDS 追加の前提が揃っている。

---

## Architecture

```
                Internet
                    │ HTTPS (*.dystopia.city cert, ACM auto-discovery)
                    ▼
              AWS ALB (internet-facing, IngressGroup: application, 既存 ALB 共有)
                    │ host: auth.dystopia.city
                    ▼
            keycloak Service (ClusterIP, target-type=ip)
                    │
            keycloak StatefulSet (codecentric/keycloakx chart, replicas: 2)
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
  RDS PostgreSQL           Google Identity Provider federation
  (aws/keycloak-database)  (Realm: dystopia, IdP: google)
  private/database subnet  client id/secret は operator が
                            Google Cloud Console で手動作成
                            → AWS Secrets Manager 手動投入
```

### Request flow (Google ソーシャルログイン)

1. toC アプリ (application monorepo, 別 repo) が Keycloak の `dystopia-app` OIDC client へ authorization code flow で redirect
2. `https://auth.dystopia.city/realms/dystopia/protocol/openid-connect/auth` → Keycloak ログイン画面、"Google でログイン" ボタン表示 (= IdP federation)
3. Google 側で認証 → Keycloak `/broker/google/endpoint` へ callback → Keycloak が Google の OIDC token を検証し、Keycloak 側 session + user レコード作成 (= 初回は自動 registration)
4. Keycloak がアプリの redirect_uri へ authorization code を返す → アプリが token exchange

---

## Components & File Structure

### AWS (Terragrunt, 新規 stack)

```
aws/keycloak-database/
├── root.hcl                          # remote state (既存 stack と同一 bucket/DynamoDB)
├── Makefile
├── envs/production/{env.hcl,terragrunt.hcl}
└── modules/
    ├── terraform.tf
    ├── variables.tf
    ├── lookups.tf                    # aws/vpc/lookup + aws/eks/lookup 参照
    ├── main.tf                       # SG + aws_db_instance + Secrets Manager (db + admin creds)
    └── outputs.tf
```

- **Engine**: PostgreSQL 17.4、`db.t4g.micro`、gp3 20GB、single-AZ (= 個人運用スケール、既存 stack のコスト意識に合わせる)
- **Network**: `aws/vpc` の `database_subnet_group_name` を再利用、SG ingress は `aws/eks` の node security group からの 5432 のみ許可
- **Credentials**: `random_password` で Terraform が生成、AWS Secrets Manager `panicboat/keycloak/database` (KC_DB_URL_HOST / KC_DB_URL_PORT / KC_DB_URL_DATABASE / KC_DB_USERNAME / KC_DB_PASSWORD) + `panicboat/keycloak/admin` (KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD) に格納。ESO IAM role (`eks-production-eso`、`secret:*` read 権限保有済) が自動的に read 可能、新規 IAM 変更不要。
- **Google IdP client secret**: Terraform 管理外。operator が Google Cloud Console で OAuth Client を手動作成し、`panicboat/keycloak/google-idp` (client_id / client_secret) に手動投入 (= 既存 oauth2-proxy Google OAuth と同じ運用パターン)。

### Kubernetes (新規 component)

```
kubernetes/components/keycloak/
├── namespace.yaml
└── production/
    ├── helmfile.yaml                          # codecentric/keycloakx v7.2.2 (Keycloak 26.6.4)
    ├── values.yaml.gotmpl                      # postgres 接続は extraEnvFrom 経由、proxy.mode=xforwarded
    └── kustomization/
        ├── kustomization.yaml
        ├── external-secret-database.yaml       # panicboat/keycloak/database → Secret keycloak-database
        ├── external-secret-admin.yaml          # panicboat/keycloak/admin → Secret keycloak-admin
        ├── external-secret-google-idp.yaml      # panicboat/keycloak/google-idp → Secret keycloak-google-idp
        ├── ingress.yaml                        # ALB IngressGroup application, host auth.dystopia.city
        ├── realm-import-configmap.yaml         # Realm "dystopia" + Client "dystopia-app" + IdP "google" (JSON)
        └── realm-config-job.yaml               # adorsys/keycloak-config-cli Job (var-substitution で google secret 注入)
```

- DB 接続情報は Terraform が Secrets Manager に書き込んだ全 5 key を ExternalSecret で 1:1 に K8s Secret 化し、chart の `extraEnvFrom` で Keycloak コンテナに直接環境変数注入 (`KC_DB_URL_HOST` 等、chart の `database.hostname` 等の static values は使わない、= RDS endpoint は apply 時まで不定のため values.yaml に書けない)。
- Admin bootstrap は `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` も同様に `extraEnvFrom`。
- Ingress は cilium application-ingress と同じ IngressGroup `application` に相乗り (= 1 ALB 共有)、healthcheck は `/` + `success-codes: "200-499"` (= cilium ingress と同じ workaround、Keycloak root がログイン画面へ redirect するため 200 単独では通らない)。
- Realm/Client/Google IdP 設定は `keycloak-config-cli` の Job で宣言的に適用。ConfigMap の realm JSON 内で `${GOOGLE_CLIENT_ID}` / `${GOOGLE_CLIENT_SECRET}` を var-substitution 参照、Job の env に `keycloak-google-idp` Secret を渡す。

---

## Decisions

| # | Decision | 採用理由 |
|---|---|---|
| 1 | Helm chart: codecentric/keycloakx | Bitnami は 2025 の Bitnami Legacy 移行で free tag が signed/paywalled registry に移行、可用性が不安定。keycloakx は公式 `quay.io/keycloak/keycloak` image を直接使用、community 活発 |
| 2 | DB: 新規 RDS PostgreSQL (in-cluster Postgres operator は不採用) | 認証基盤という性質上、DB は EKS ライフサイクルと分離しマネージドで運用したい (= 既存 `docs/runbooks/eks-production-recreate.md` の teardown/recreate 運用と相性が良い) |
| 3 | hostname: auth.dystopia.city | 公開 toC ドメイン配下、将来複数アプリ/サブドメイン追加を見据えて `auth.` を採用 (= panicboat 指定) |
| 4 | Realm/Client/IdP: keycloak-config-cli Job で宣言的管理 | GitOps 単一 source of truth。Admin Console 手動操作は再現性がなく、cluster recreate 時の復旧が困難 |
| 5 | Google IdP client secret: Terraform 管理外・手動投入 | 既存 oauth2-proxy Google OAuth と同じ運用パターン、Google Cloud Console 操作は元々 IaC 化不可 |
| 6 | Phase 2 (電話番号認証) は別 spec | SMS provider 選定 + custom SPI/extension 開発が必要、Phase 1 (基本 IdP 疎通) を先に確立してから着手 |

---

## Manual Setup (Phase 1 完了に必要な手動操作)

1. **Google OAuth Client 作成** (Google Cloud Console): Authorized redirect URI = `https://auth.dystopia.city/realms/dystopia/broker/google/endpoint`
2. **AWS Secrets Manager**: `panicboat/keycloak/google-idp` に `{"client_id": "...", "client_secret": "..."}` を投入 (region: ap-northeast-1)
3. **terragrunt apply**: `aws/keycloak-database/envs/production` (CI の terragrunt-executor 経由、main merge で自動 apply)

---

## Known Limitations / Out of Scope

- **realm-config-job の再実行**: Job は immutable なため、realm JSON 変更時は `kubectl delete job -n keycloak keycloak-realm-config` を手動実行して Flux に再作成させる必要がある (= Reloader は Job を watch しない)。自動化は Phase 2+ で検討。
- **電話番号 (SMS OTP) 認証**: Phase 2。SMS provider 選定 (AWS SNS 想定) + custom authentication flow (SPI or community extension) が必要。
- **toC アプリ側の統合**: application monorepo (別 repo) 側での Keycloak client 利用実装は本 repo の scope 外。
- **HA / DR**: RDS は single-AZ (コスト優先)。運用実績を見て Multi-AZ 化を検討。
