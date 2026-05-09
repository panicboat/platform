# EKS Production: Grafana Auth + Ingress (Phase 4-3) Design

> **Phase**: roadmap Phase 4 (Secrets & App readiness) の Sub-project 4-3 (= 最終 sub-project)
>
> **Prerequisites**: Phase 4-1 (cert-manager + selfsigned-cluster-issuer) + Phase 4-2 (ESO + ClusterSecretStore + Reloader) deploy 済
>
> **Goal**: 4 monitoring UIs (= Grafana / Hubble UI / Alertmanager / Prometheus) を internet-facing ALB + oauth2-proxy + Google OAuth で公開、Grafana adminPassword を ESO 経由で AWS Secrets Manager 化する。Phase 4 完了 = Phase 5 nginx end-to-end validation の全 prerequisite を達成する。

---

## Context

### Phase 4-2 完了後の状況 (= 4-3 brainstorming 開始時の前提)

- ✅ cert-manager v1.20.2 deploy 済、`selfsigned-cluster-issuer` ClusterIssuer 利用可能 (= Phase 4-1)
- ✅ External Secrets Operator deploy 済、`external-secrets` namespace
- ✅ Reloader deploy 済、`reloader` namespace
- ✅ ClusterSecretStore `aws-secrets-manager` Ready=True、AWS Secrets Manager backend (= ap-northeast-1) で Pod Identity 経由 auth 動作 verify 済
- ✅ AWS IAM role `eks-production-eso` + Pod Identity Association provision 済 (`secretsmanager:GetSecretValue` on `secret:*`)
- ✅ AWS Load Balancer Controller deploy 済、IRSA 認証
- ✅ external-dns deploy 済、`panicboat.net` domain filter、policy: sync
- ✅ ACM wildcard cert `*.panicboat.net` provision 済 (= `aws/alb/` stack)
- ✅ kube-prometheus-stack deploy 済、Grafana が **hardcoded `adminPassword: "panicboat-2026"`** + `// TODO: (Phase 4) ESO 経由化` 状態
- ✅ Cilium GatewayClass `cilium` 存在、production HTTPRoute / Gateway は不在 (= east-west 用に reserved)
- 🔜 Phase 4-3 で Grafana 認証ゲート + 4 monitoring UIs 公開 + adminPassword ESO 化
- 🔜 Phase 5 で nginx + Beyla + KEDA + ExternalSecret end-to-end validation

### Roadmap Phase 4 完了条件

| 条件 | 達成 sub-project |
|---|---|
| ESO が AWS Secrets Manager の値を K8s Secret に sync する | Phase 4-2 ✅ |
| Reloader が Secret / ConfigMap 変更時に annotation 付きの Deployment を rollout する | Phase 4-2 ✅ |
| cert-manager が webhook 用 cert を発行できる | Phase 4-1 ✅ |
| **Grafana が認証ゲート経由でないと開けない** | **Phase 4-3 (本 sub-project)** |

= 4-3 完了 = Phase 4 完了 = Phase 5 nginx 投入の全 prerequisite 達成。

---

## Architecture

### High-level architecture

```
                Internet (public, port 443 only)
                    │
                    │ HTTPS (= ACM wildcard *.panicboat.net)
                    ▼
              AWS ALB (internet-facing)
              IngressGroup: monitoring-uis
              [Host-based routing]
                    │
        ┌───────────┼───────────┬────────────┐
        │           │           │            │
        ▼           ▼           ▼            ▼
  grafana.    hubble.     alertmanager. prometheus.
  panicboat   panicboat   panicboat     panicboat
  .net        .net        .net          .net
        │           │           │            │
        └───────────┴───────────┴────────────┘
                    │
                    ▼
            oauth2-proxy Service
            (= cluster ClusterIP)
            [oauth2-proxy namespace]
                    │
            ┌───────┴────────┐
            │                │
            │ 認証済 cookie  │ 未認証
            │                │
            ▼                ▼
    Host header で       Google OAuth へ
    upstream 振分        redirect
            │                │
            │                ▼
            │         accounts.google.com
            │         (login)
            │                │
            │                ▼
            │         /oauth2/callback (= ALB 経由 oauth2-proxy)
            │                │
            │         email allowlist check
            │         (= ConfigMap: allowed-emails)
            │                │
            │                ▼
            │         set session cookie
            │         (= cookie domain: .panicboat.net)
            │                │
            └────────────────┘
                    │
        ┌───────────┼───────────┬────────────┐
        ▼           ▼           ▼            ▼
   Grafana    Hubble UI   Alertmanager   Prometheus
  (monitoring) (kube-system) (monitoring)  (monitoring)
   :80         :80          :9093         :9090

   ※ Grafana のみ X-Forwarded-User header で
     auth.proxy mode により auto-login (role mapping)
```

### Request flow (= 認証済 user)

1. user → `https://grafana.panicboat.net` (= browser)
2. external-dns 由来 Route53 record → ALB DNS
3. ALB → host header `grafana.panicboat.net` で IngressGroup の rule match → oauth2-proxy Service
4. oauth2-proxy: session cookie 確認 → 認証済 → `--upstream` config から Host header で grafana service 解決 → forward
5. Grafana: `auth.proxy.enabled: true` で `X-Forwarded-User` header 検証 → user auto-create / update / role mapping → response
6. response → oauth2-proxy → ALB → user

### Request flow (= 未認証 user の初回 login)

1. user → `https://grafana.panicboat.net` (no session cookie)
2. ALB → oauth2-proxy
3. oauth2-proxy: cookie なし → Google OAuth へ 302 redirect (= `accounts.google.com/o/oauth2/auth?client_id=...&redirect_uri=https://grafana.panicboat.net/oauth2/callback`)
4. user → Google で login → consent 画面で allow
5. Google → `https://grafana.panicboat.net/oauth2/callback?code=...` へ redirect
6. ALB → oauth2-proxy `/oauth2/callback` path → oauth2-proxy が code を Google で token exchange → email 取得 → ConfigMap allowlist と照合
7. allowlist match (= panicboat@gmail.com) → session cookie set (= `.panicboat.net` domain) → 元 URL へ redirect
8. 以降は **認証済 flow**、**他 3 host (= hubble / alertmanager / prometheus) も同 cookie で SSO 通過**

### SSO experience

- 4 UI 全部 **cookie domain `.panicboat.net`** で session 共有
- 1 回 Google login → 4 UI 全部に access 可
- session 切れ → 任意の UI で再 login 後、他 UI も自動 access 可

---

## Components & File Structure

### Component matrix

| Component | New / Modified | namespace | 役割 |
|---|---|---|---|
| **oauth2-proxy** chart | 新規 component | `oauth2-proxy` | Google OAuth gate + reverse-proxy (= 1 instance shared) |
| **prometheus-operator** chart values | **modified** | (chart) | Grafana adminPassword 化 (= existingSecret 参照) + `auth.proxy` mode enable + Reloader annotation 追加 |
| **ExternalSecret resources** | 新規 (2 つ) | `oauth2-proxy` + `monitoring` | AWS Secrets Manager → K8s Secret sync (= Phase 4-2 ESO の actual use case) |
| **Ingress resources (× 4)** | 新規 (kustomization 配下) | `oauth2-proxy` | IngressGroup `monitoring-uis` で 1 ALB 共有、4 host routing |
| **ConfigMap (allowed-emails)** | 新規 (kustomization 配下) | `oauth2-proxy` | panicboat@gmail.com allowlist |
| **AWS terragrunt stack** | **不要** | — | Phase 4-2 で provision 済 IAM role が `secretsmanager:GetSecretValue` on `secret:*` を保有、新規 secrets も自動 access 可 |

### File structure (= 新規作成 / 変更)

**新規 (= K8s component `oauth2-proxy`)**:

```
kubernetes/components/oauth2-proxy/
├── namespace.yaml                                  # oauth2-proxy namespace
└── production/
    ├── helmfile.yaml                               # oauth2-proxy/oauth2-proxy chart
    ├── values.yaml.gotmpl                          # multi-upstream + Google OAuth + ConfigMap allowlist
    └── kustomization/
        ├── kustomization.yaml                       # overlay roll-up
        ├── external-secret.yaml                     # ExternalSecret: panicboat/oauth2-proxy/google → K8s Secret
        ├── allowed-emails-configmap.yaml            # ConfigMap: panicboat@gmail.com 1 件
        └── ingress-monitoring-uis.yaml              # 4 Ingresses (IngressGroup monitoring-uis)
```

**修正 (= K8s component `prometheus-operator`)**:

```
kubernetes/components/prometheus-operator/production/
├── helmfile.yaml                                   # 変更なし
├── values.yaml.gotmpl                              # 修正:
│                                                   #   - grafana.adminPassword 削除
│                                                   #   - grafana.admin.existingSecret: grafana-admin 追加
│                                                   #   - grafana.grafana.ini.auth.proxy.* 追加
│                                                   #   - grafana.deploymentAnnotations: reloader.stakater.com/auto: "true" 追加
└── kustomization/                                  # 新規 directory
    ├── kustomization.yaml
    └── grafana-admin-external-secret.yaml          # ExternalSecret: panicboat/grafana/admin → grafana-admin Secret
```

**自動生成 (= production hydrate output)**:

```
kubernetes/manifests/production/oauth2-proxy/{kustomization.yaml, manifest.yaml}      # 新規
kubernetes/manifests/production/prometheus-operator/manifest.yaml                      # 修正 (= ExternalSecret + 新 values 由来 ConfigMap / Deployment)
kubernetes/manifests/production/00-namespaces/namespaces.yaml                          # 修正 (= oauth2-proxy namespace 追加)
kubernetes/manifests/production/kustomization.yaml                                     # 修正 (= ./oauth2-proxy 追加)
```

**変更しないファイル**:

- `kubernetes/components/cilium/*` (= Hubble UI Service は既存のまま、cross-namespace FQDN で oauth2-proxy が呼出)
- `kubernetes/components/aws-load-balancer-controller/*` (= ALB Controller 既存設定で IngressGroup support 済)
- `kubernetes/components/external-dns/*` (= 既存設定で `panicboat.net` domain filter + ingress source ready)
- `aws/*` (= 全 AWS terragrunt stack、Phase 4-2 で eks-secrets stack 既存)

### Cross-namespace service access (= oauth2-proxy → backends)

```yaml
# oauth2-proxy values.yaml.gotmpl の upstream config (= 概略)
config:
  configFile: |-
    upstreams = [
      "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80",
      "http://hubble-ui.kube-system.svc.cluster.local:80",
      "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093",
      "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
    ]
```

K8s の cluster DNS (= CoreDNS) が `*.svc.cluster.local` を解決、oauth2-proxy は `Host` header に基づき適切な upstream を選択 (= chart の reverse-proxy mode + Host-based routing config)。

### Grafana auth.proxy mode (= chart values 修正)

```yaml
# kubernetes/components/prometheus-operator/production/values.yaml.gotmpl の Grafana 部分 (= 概略)
grafana:
  enabled: true
  # 削除: adminPassword: "panicboat-2026"
  admin:
    existingSecret: grafana-admin                # ExternalSecret 由来
    userKey: admin-user
    passwordKey: admin-password
  deploymentAnnotations:
    reloader.stakater.com/auto: "true"           # Reloader watch (= secret 変更で auto-rollout)
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User              # oauth2-proxy 由来 header
      header_property: username                  # email を Grafana username にする
      auto_sign_up: true                         # 初回 login で user auto-create
      sync_ttl: 60
    users:
      auto_assign_org: true
      auto_assign_org_role: Admin                # email allowlist 通過 = Admin (= panicboat 1 人運用)
```

Grafana の adminPassword (= existingSecret 経由) は **auth.proxy 並走** で残す (= 緊急時の direct admin login 用、auth.proxy 障害時の fallback)。

---

## Manual Setup (= AWS + Google Cloud)

GitOps + Flux で完結しない 2 種の panicboat による手動 setup が事前に必要 (= 4-2 で AWS 直接 IAM 確認が AccessDenied だった経験から、admin-side の AWS / Google 操作は手動と明示)。

### Google OAuth Client setup (= Google Auth Platform)

panicboat の Google Cloud project に OAuth 2.0 Client を作成し、各 section で以下を設定:

| Section | 設定内容 |
|---|---|
| **ブランディング** | アプリ名: `panicboat.net` (= 任意の identifying name) / ユーザーサポートメール: `panicboat@gmail.com` / 承認済みドメイン: `panicboat.net` / デベロッパー連絡先: `panicboat@gmail.com` |
| **対象** | 公開ステータス: Testing (= External + Testing で 100 user 制限内永続運用、Workspace 契約後 Internal 化可) / User type: External / **テストユーザー: `panicboat@gmail.com` を追加** |
| **クライアント** | Application type: Web application / Authorized JavaScript origins: `https://{grafana,hubble,alertmanager,prometheus}.panicboat.net` (= 4 件) / Authorized redirect URIs: `https://{grafana,hubble,alertmanager,prometheus}.panicboat.net/oauth2/callback` (= 4 件) |
| **データアクセス** | Scopes: `openid` + `.../auth/userinfo.email` + `.../auth/userinfo.profile` (= 3 件) |

**取得物**: Client ID + Client Secret (= AWS Secrets Manager の `panicboat/oauth2-proxy/google` secret に投入)

**参照 docs**: Google Cloud 公式 [Setting up OAuth 2.0](https://support.google.com/cloud/answer/6158849)

**実装時 friction の許容**: Google Cloud Console UI 変更により実 navigation は spec と異なる場合あり、要件を満たす設定に到達すれば手順は不問。

### AWS Secrets Manager に secrets を投入

panicboat が AWS Console (= eks-admin role) で Secrets Manager 操作:

1. **`cookie_secret` を panicboat の local terminal で生成**:

   ```bash
   openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
   ```

   → 32 bytes URL-safe random string を copy

2. **AWS Secrets Manager** で 2 secrets を作成 (= region: ap-northeast-1):

   **Secret 1: `panicboat/oauth2-proxy/google`**

   ```json
   {
     "client_id": "<Google から取得した client_id>",
     "client_secret": "<Google から取得した client_secret>",
     "cookie_secret": "<step 1 で生成した値>"
   }
   ```

   **Secret 2: `panicboat/grafana/admin`**

   ```json
   {
     "admin-user": "admin",
     "admin-password": "<panicboat が任意で選択した強い password>"
   }
   ```

   - `admin-password` 推奨生成: `openssl rand -base64 24`
   - panicboat の 1Password 等に控える (= GitOps 後は Grafana UI / Secrets Manager のみが source of truth)

3. **読取権限の確認**: ESO IAM role (= Phase 4-2 で provision 済 `eks-production-eso`) は `secretsmanager:GetSecretValue` を `arn:aws:secretsmanager:*:*:secret:*` に対して保有、新規 secret も自動的に access 可

### ExternalSecret resources (= GitOps deploy)

**`kubernetes/components/oauth2-proxy/production/kustomization/external-secret.yaml`**:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: oauth2-proxy-google
  namespace: oauth2-proxy
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h                              # 1 時間に 1 回 AWS poll
  target:
    name: oauth2-proxy-google                      # K8s Secret name
    creationPolicy: Owner
  data:
    - secretKey: client-id
      remoteRef:
        key: panicboat/oauth2-proxy/google
        property: client_id
    - secretKey: client-secret
      remoteRef:
        key: panicboat/oauth2-proxy/google
        property: client_secret
    - secretKey: cookie-secret
      remoteRef:
        key: panicboat/oauth2-proxy/google
        property: cookie_secret
```

**`kubernetes/components/prometheus-operator/production/kustomization/grafana-admin-external-secret.yaml`**:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
    - secretKey: admin-user
      remoteRef:
        key: panicboat/grafana/admin
        property: admin-user
    - secretKey: admin-password
      remoteRef:
        key: panicboat/grafana/admin
        property: admin-password
```

### Secret rotation の挙動

| secret | rotation 想定 | rotation 起点 | 自動 rollout |
|---|---|---|---|
| `oauth2-proxy/google.client_secret` | Google Cloud 側で再生成時 | panicboat が AWS Secrets Manager 更新 | ESO 1h poll → K8s Secret update → Reloader が oauth2-proxy rollout |
| `oauth2-proxy/google.cookie_secret` | 強制 logout 全 user 時 | panicboat が `openssl rand` 再生成 + AWS 更新 | 同上 (= 全 active session が invalidate、再 login 強制) |
| `grafana/admin.admin-password` | password 変更時 | panicboat が AWS Secrets Manager 更新 | ESO 1h poll → K8s Secret update → Reloader が Grafana rollout (= auth.proxy 経由 user は影響なし、direct admin login のみ新 password) |

**rotation cycle**: roadmap で明示 schedule なし、Phase 6+ で AWS Secrets Manager Automatic Rotation Lambda を評価 (= 引き継ぎ事項として記録)。

---

## Decisions

11 件、brainstorming で確定:

| # | Decision | 採用 | 採用理由 |
|---|---|---|---|
| 1 | 公開対象 UI scope | Grafana + Hubble UI + Alertmanager + Prometheus (= 4 UIs 一括) | 共通認証ゲートを 1 度に設計、Phase 4 完了条件 "Grafana 認証ゲート" を満たしつつ ops UIs 一括公開 |
| 2 | 認証 provider | Google OAuth (= panicboat@gmail.com) | OIDC 完全準拠、Cognito の operational overhead 不要、Workspace 契約後 domain allowlist に切替可能 |
| 3 | 認証 mechanism | oauth2-proxy + Grafana auth.proxy mode | true SSO (= 1 click で 4 UI)、Grafana role mapping 活用、ALB OIDC の double-login 問題回避 |
| 4 | Ingress mechanism | ALB Ingress (= AWS Load Balancer Controller) | 既存 stack 全面活用 (= ACM wildcard + external-dns + ALB Controller)、Cilium Gateway API は east-west 用に reserved (= use case 顕在化時に separate spec) |
| 5 | ALB scheme | internet-facing | panicboat 個人運用 + VPN 不在、Google OAuth allowlist が十分な認証層 |
| 6 | ALB sharing strategy | 1 ALB shared via IngressGroup `monitoring-uis` | cost optimal (= 1 ALB ~$20/month vs 4 ALB ~$80/month)、ALB AZ 跨ぎ HA で実質 SPOF 回避 |
| 7 | Email allowlist 粒度 | panicboat@gmail.com のみ ConfigMap 管理 | gmail.com domain allow は実質認証 bypass、Workspace 契約後に domain allowlist に切替可 |
| 8 | Secrets 管理 | 全 secret を ESO + AWS Secrets Manager (= Grafana adminPassword + oauth2-proxy 3 secrets) | Phase 4-2 ESO の actual end-to-end use case、Grafana TODO 解消、Phase 5 nginx 前の validation |
| 9 | oauth2-proxy deployment topology | 1 instance shared (= multi-upstream config) | resource 最適 (= 1 Pod)、secret 1 set、SSO experience cleanest |
| 10 | OAuth Client User type | External + Testing status (= 100 user 制限内永続運用) | individual Google account の制約、Workspace 契約後 Internal 化可、Production verification は YAGNI |
| 11 | AWS terragrunt 新規 stack | **不要** | Phase 4-2 で provision 済 ESO IAM role が `secretsmanager:GetSecretValue` on `secret:*` を保有、新規 secrets も自動 access 可 |

---

## Post-flight Check

deploy 後 verify、~15 項目:

### A. Infrastructure layer

1. ALB が 1 台 provision (= IngressGroup `monitoring-uis`)、internet-facing scheme、ACM wildcard cert bind
2. Route53 record 4 件 (= `{grafana,hubble,alertmanager,prometheus}.panicboat.net` → ALB DNS) が external-dns で自動作成
3. Ingress 4 件全て `Status.LoadBalancer.Ingress[0].Hostname` に ALB DNS が反映

### B. ESO layer (= Phase 4-2 の actual use case validation)

4. ExternalSecret `oauth2-proxy/oauth2-proxy-google` Status=Ready
5. ExternalSecret `monitoring/grafana-admin` Status=Ready
6. K8s Secret `oauth2-proxy/oauth2-proxy-google` 存在 (= 3 keys: client-id / client-secret / cookie-secret)
7. K8s Secret `monitoring/grafana-admin` 存在 (= 2 keys: admin-user / admin-password)

### C. Auth gate layer

8. oauth2-proxy Pod Running、`/ping` health check 200
9. ConfigMap `oauth2-proxy/allowed-emails` に `panicboat@gmail.com` が含まれる
10. Grafana Pod Running、`grafana.ini` の `auth.proxy.enabled = true` 反映

### D. End-to-end browser test

11. `https://grafana.panicboat.net` browser access → Google OAuth へ redirect → panicboat@gmail.com で login → Grafana に **auto-login** で Admin role が反映
12. 同 browser session で `https://hubble.panicboat.net` / `https://alertmanager.panicboat.net` / `https://prometheus.panicboat.net` access → 再 login なしで通過 (= SSO 動作確認)
13. 別アカウント (= panicboat@gmail.com 以外) で login 試行 → ConfigMap allowlist で 403 reject、Grafana 等 backend に到達しない

### E. Reloader integration

14. Grafana Deployment に `reloader.stakater.com/auto: "true"` annotation
15. AWS Secrets Manager で `panicboat/grafana/admin.admin-password` を任意の値に変更 → ESO refresh (= 1h 以内 or `kubectl annotate externalsecret grafana-admin force-sync=now`) → K8s Secret update → Reloader が Grafana Pod rollout 検知 → 新 Pod 起動で direct admin login が新 password で成功

---

## Rollback Patterns

想定外障害時の rollback 手順:

| Pattern | 適用条件 | 操作 |
|---|---|---|
| **A. Standard rollback** | Phase 4-3 全体を巻き戻したい | Flux suspend → 4-3 merge commit を revert PR → resume |
| **B. Partial rollback (= ALB Ingress のみ)** | Ingress / DNS の問題のみ、認証本体は OK | Ingress resources のみ削除 PR、ALB は ALB Controller が cleanup、external-dns が record も削除 |
| **C. Auth gate bypass (= 緊急対応)** | oauth2-proxy / Google OAuth が長時間障害、Grafana 直接 access が必要 | Grafana の `auth.anonymous.enabled: true` + `auth.proxy.enabled: false` に temporary 切替 (= revert で元に戻す)、port-forward で operator が緊急 admin login (= adminPassword 経由) |

---

## Risks & Mitigations

| Risk | mitigation |
|---|---|
| **Google OAuth Testing status の "未認証アプリ" warning** が初回 login の user 体験に friction | 初回のみ "Continue" で advance、以降 cookie で skip。Phase 6+ Workspace 契約で Internal 化により resolve |
| **cookie domain `.panicboat.net` で session 共有** = 1 cookie compromise が 4 UI 影響 | cookie_secret rotation を AWS Secrets Manager 更新 → ESO refresh + Reloader rollout で全 active session invalidate (= 強制 re-login)、~5 分以内で全 user logout 強制可能 |
| **oauth2-proxy 1 Pod = SPOF** | values で `replicas: 2` 指定 (= chart default かつ recommended)、ALB target group で 2 endpoints HA |
| **ALB IngressGroup の order priority 衝突** | 4 Ingress が host で完全分離、明示 `group.order` annotation 不要。将来 `panicboat.net` 直下に Ingress 追加時 (= 例: Phase 5 nginx) は order 設計が必要 |
| **Grafana auth.proxy + adminPassword 並走の security boundary** | adminPassword は emergency 用 fallback (= auth.proxy 障害時の port-forward + admin login)、normal use case では auth.proxy のみ。adminPassword は ESO 経由で AWS Secrets Manager に rotation 可、direct exposure なし |
| **Internet 公開 = 0-day vulnerability の attack surface** | oauth2-proxy 後段で 4 UI を内部 expose、Internet 直接到達は oauth2-proxy のみ。oauth2-proxy chart は active maintenance (= CNCF Sandbox)、CVE 発覚時は chart upgrade で対応可 |

---

## Out of Scope (= Phase 5 / Phase 6+ へ postpone)

### Phase 5 (= nginx end-to-end validation) で扱う

| 項目 | Phase 5 で扱う理由 |
|---|---|
| **nginx + Beyla + KEDA ScaledObject + Ingress + ExternalSecret** | roadmap Phase 5 完了条件、application code 投入の最終 validation |
| **AWS Secrets Manager に nginx 用 actual secret 投入** | Phase 5 implementation 開始時に panicboat が手動投入、Phase 4-3 で監視基盤の secret pattern が確立済 |
| **OTel Operator deploy 検討 (= 引き継ぎ #4)** | nginx 投入時に instrumentation pattern 評価 |
| **Pod CPU requests audit + rightsizing (= 引き継ぎ #9)** | application traffic 不在で再 audit 必須、Phase 5 nginx + 観測 burst 後に実施 |

### Phase 6+ で扱う

| 項目 | Phase 6+ で扱う理由 |
|---|---|
| **Google Workspace 契約 + OAuth Internal 化 + email_domain allowlist 移行** | Workspace 加入のタイミングで切替、values 数行差分で完結 |
| **AWS Secrets Manager Automatic Rotation (= Lambda 統合)** | rotation cycle が要件として顕在化した時点で評価、現運用は manual rotation で十分 |
| **Cilium Gateway API east-west 利用 (= service mesh routing)** | Phase 5 nginx の internal routing 要件 or multi-service architecture 顕在化時に separate spec |
| **monitoring UIs 公開範囲拡張 (= Tempo UI / Mimir UI 等)** | 現 4 UIs で operator の主要な需要 (= dashboard / topology / alerts / metrics) 充足、追加要件発生時に IngressGroup に Ingress 追加で incremental 対応 |
| **multi-team / multiple emails allowlist** | team 拡張のタイミングで ConfigMap entries 追加 + Reloader auto-rollout で対応、Workspace 化なら domain allowlist で auto |
| **gp3 StorageClass Layer 2 documented exception 化 (= 引き継ぎ #1)** | "cluster bootstrap layer は Flux 外" の architecture decision を docs に明記 |
| **bucket-per-env migration (= 引き継ぎ #2)** | 現 monorepo bucket で十分 |
| **multi-tenant 化 + 詳細 retention rules (= 引き継ぎ #3)** | 1 tenant 運用で十分 |
| **post-flight check 自動化 (= 引き継ぎ #5)** | 4-2 L5 で design 指針追加済、Phase 6+ で実装 |
| **Hubble flow logs → Loki (= 引き継ぎ #7)** | 現 Hubble metrics + UI で十分 |
| **local Fluent Bit OTLP gRPC 統一 (= 引き継ぎ #8)** | local 環境の独立性、production 動作に影響なし |
| **OTel Collector exporter alias check 自動化 (= 引き継ぎ #10)** | 4b L1 で systematic step として established |
| **他 admission webhooks の cert-manager migration** | Karpenter / ALB Controller / KEDA / prometheus-operator は builtin self-signed のまま、Phase 6+ で incremental migrate path |

---

## Phase 4 引き継ぎ事項 update (= 4-3 完了時)

| 項目 | 4-3 完了時の状態 |
|---|---|
| 1. gp3 StorageClass Layer 2 documented exception 化 | Phase 6+ 引き継ぎ (= 不変) |
| 2. bucket-per-env migration | Phase 6+ 引き継ぎ (= 不変) |
| 3. multi-tenant 化 + retention rules | Phase 6+ 引き継ぎ (= 不変) |
| 4. OTel Operator deploy 検討 | Phase 5 |
| 5. post-flight check 自動化 | Phase 6+ 引き継ぎ (= 4-2 L5 で design 指針追加済、4-3 で再 evaluation なし) |
| 6. Beyla + OTel Collector metrics pipeline | Phase 5 |
| 7. Hubble flow logs → Loki | Phase 6+ 引き継ぎ (= 不変) |
| 8. local Fluent Bit OTLP gRPC 統一 | Phase 6+ 引き継ぎ (= 不変) |
| 9. Pod CPU requests audit + rightsizing | Phase 5 |
| 10. OTel Collector exporter alias check 自動化 | Phase 6+ 引き継ぎ (= 不変) |
| **11. Google Workspace 契約後の OAuth Internal 化 + email_domain allowlist 移行 (= 4-3 で新規追加)** | Phase 6+ 引き継ぎ |
| **12. AWS Secrets Manager Automatic Rotation (= 4-3 で新規追加)** | Phase 6+ 引き継ぎ |
| **13. Cilium Gateway API east-west 利用 (= 4-3 で新規追加)** | Phase 6+ 引き継ぎ |
| **14. monitoring UIs 公開範囲拡張 (= Tempo UI / Mimir UI 等、4-3 で新規追加)** | Phase 6+ 引き継ぎ (= on-demand) |

= 4-3 完了で **明示的に解消した引き継ぎ事項なし** (= Grafana auth + Ingress は roadmap Phase 4 の primary goal、引き継ぎ事項とは別カテゴリ)、ただし新規 4 項目 (= #11-14) を Phase 6+ の追跡 list に追加。

---

## Phase 4 完了状態 (= 4-3 完了時)

- ✅ Phase 4-1: cert-manager + selfsigned-cluster-issuer + Cilium TLS migration
- ✅ Phase 4-2: ESO + ClusterSecretStore `aws-secrets-manager` + Reloader
- ✅ Phase 4-3: Grafana 認証ゲート + 4 monitoring UIs 公開 + adminPassword ESO 化 + oauth2-proxy 共通 gate
- 🔜 Phase 5: nginx + Beyla + KEDA + ExternalSecret end-to-end validation (= Phase 4 全 component の actual application 投入で final validation)

= **Phase 4 (= Secrets & App readiness) の完了**、Phase 5 nginx 投入の全 prerequisite 達成:

| Phase 5 nginx 要件 | Phase 4 で provision 済の dependency |
|---|---|
| ExternalSecret で env から secret 注入 | ✅ Phase 4-2 ESO + ClusterSecretStore |
| Reloader で secret 変更時 auto-rollout | ✅ Phase 4-2 Reloader |
| TLS cert (= ingress-tls or service-to-service) | ✅ Phase 4-1 cert-manager + selfsigned-cluster-issuer |
| 監視結果を Grafana で参照 | ✅ Phase 4-3 Grafana 認証ゲート + 公開 |

---

## Sub-project 1-4-2 learnings 適用

Phase 3 + Phase 4-1 + Phase 4-2 の累計 learnings (= 各 sub-project の post-execution learnings PR で蓄積) を本 sub-project 設計時に適用:

- **L1 (= chart binary verify systematic step)**: oauth2-proxy chart + kube-prometheus-stack の Grafana subchart の latest stable version + key path verify を Plan の Task 1-2 step として組み込む
- **L2 (= chart-fixed value conflict pattern, 4-2 L2)**: `helm template` 出力で oauth2-proxy / Grafana の values 設定が反映されているか事前確認 (= override 不能 key の発見)
- **L3 (= helmfile hydration Capabilities gate workaround, 4-2 L3)**: oauth2-proxy / Grafana に `.Capabilities.APIVersions.Has` gate がある場合、`helmDefaults.args: ["--api-versions=..."]` で declarative override
- **L4 (= 急進化 chart の design assumption gap calibration, 4-2 L4)**: spec の chart version / apiVersion / values 構造は brainstorming 時 snapshot、実装時に再 verify 前提
- **L5 (= AWS direct verify AccessDenied → application-level indirect proof, 4-2 L5)**: post-flight check で AWS direct verify が blocked された場合、K8s API + chart status (= ExternalSecret Ready=True / ALB Ingress Status / Grafana login success) を primary signal に
- **L6 (= subagent-driven development cadence の stable maintain, 4-2 L6)**: Plan Task 数を AWS / chart A / chart B / hydrate の 4 layer split で踏襲 (= 本 sub-project は AWS terragrunt 不要のため 3 layer split が natural、後述 plan で確定)
- **4-1 L5 (= chart version placeholder pattern)**: spec の chart version は placeholder OK、plan で latest stable 確認

---

## References

- Phase 4-1 spec: `docs/superpowers/specs/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls-design.md`
- Phase 4-1 plan: `docs/superpowers/plans/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls.md`
- Phase 4-2 spec: `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md`
- Phase 4-2 plan: `docs/superpowers/plans/2026-05-08-eks-production-eso-reloader-foundation.md`
- platform roadmap: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- foundation-addons-beta (= ALB / external-dns 既存設定): `docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md`
- oauth2-proxy 公式 docs: <https://oauth2-proxy.github.io/oauth2-proxy/>
- AWS Load Balancer Controller IngressGroup docs: <https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.13/guide/ingress/annotations/#ingressgroup>
- Grafana auth.proxy docs: <https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/auth-proxy/>
- Google Cloud Identity Platform - Setting up OAuth 2.0: <https://support.google.com/cloud/answer/6158849>
