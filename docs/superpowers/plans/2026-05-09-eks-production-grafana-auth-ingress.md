# EKS Production: Grafana Auth + Ingress (Phase 4-3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) で 4 monitoring UIs (= Grafana / Hubble UI / Alertmanager / Prometheus) を internet-facing ALB + oauth2-proxy + Google OAuth 認証ゲート経由で公開し、Grafana adminPassword を ESO + AWS Secrets Manager 化する。Phase 4-3 完了 = roadmap Phase 4 (Secrets & App readiness) 完了 = Phase 5 nginx end-to-end validation の全 prerequisite 達成。

**Architecture:** `oauth2-proxy/oauth2-proxy` chart を `oauth2-proxy` namespace に 1 instance shared deploy、4 ALB Ingress (= IngressGroup `monitoring-uis` で 1 ALB 共有) 全部 oauth2-proxy Service へ host-based routing、oauth2-proxy が Google OAuth gate + reverse-proxy で Host header 経由 4 backends に転送。Grafana は `auth.proxy` mode で oauth2-proxy 由来 `X-Forwarded-User` header から auto-login + Admin role assignment、adminPassword は ExternalSecret 経由 `panicboat/grafana/admin` から sync。oauth2-proxy 認証 secrets (= client_id / client_secret / cookie_secret) は ExternalSecret 経由 `panicboat/oauth2-proxy/google` から sync、email allowlist (= `panicboat@gmail.com` 1 件) は ConfigMap で管理。AWS terragrunt 新規 stack 不要 (= Phase 4-2 ESO IAM role が `secretsmanager:GetSecretValue` on `secret:*` を保有、新規 secrets も auto access)。

**Tech Stack:** Helm + helmfile / `oauth2-proxy/oauth2-proxy` v7.x (= 実装時に latest stable 確認) / `prometheus-community/kube-prometheus-stack` v84.5.0 (= 既 deploy 済 Grafana subchart 修正) / AWS Load Balancer Controller v2.x (= 既 deploy 済) / external-dns (= 既 deploy 済、`panicboat.net` domain filter) / ACM wildcard cert `*.panicboat.net` (= `aws/alb/` で provision 済、auto-discovery 利用) / External Secrets Operator (= Phase 4-2 で deploy 済) / Reloader (= Phase 4-2 で deploy 済) / cert-manager + selfsigned-cluster-issuer (= Phase 4-1 で deploy 済、本 sub-project では追加利用なし)

**Spec:** `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (oauth2-proxy):**

```
kubernetes/components/oauth2-proxy/
├── namespace.yaml                                  # oauth2-proxy namespace 定義
└── production/
    ├── helmfile.yaml                               # oauth2-proxy/oauth2-proxy chart deploy
    ├── values.yaml.gotmpl                          # multi-upstream + Google OAuth + ConfigMap allowlist
    └── kustomization/
        ├── kustomization.yaml                      # overlay roll-up
        ├── external-secret.yaml                    # ExternalSecret: panicboat/oauth2-proxy/google → K8s Secret
        ├── allowed-emails-configmap.yaml           # ConfigMap: panicboat@gmail.com 1 件
        └── ingress-monitoring-uis.yaml             # 4 Ingress (IngressGroup monitoring-uis)
```

**Kubernetes 修正 (prometheus-operator):**

```
kubernetes/components/prometheus-operator/production/
├── helmfile.yaml                                   # 変更なし
├── values.yaml.gotmpl                              # 修正: Grafana adminPassword → existingSecret + auth.proxy mode + Reloader annotation
└── kustomization/                                  # 新規 directory
    ├── kustomization.yaml
    └── grafana-admin-external-secret.yaml          # ExternalSecret: panicboat/grafana/admin → grafana-admin Secret
```

**Kubernetes 自動生成 (production hydrate output):**

```
kubernetes/manifests/production/oauth2-proxy/{kustomization.yaml, manifest.yaml}    # 新規
kubernetes/manifests/production/prometheus-operator/manifest.yaml                    # 修正 (= ExternalSecret 追加 + Grafana values 反映)
kubernetes/manifests/production/00-namespaces/namespaces.yaml                        # 修正 (= oauth2-proxy namespace block 追加)
kubernetes/manifests/production/kustomization.yaml                                   # 修正 (= ./oauth2-proxy 追加)
```

**変更しないファイル**: `aws/*` (= 全 terragrunt stack、Phase 4-2 で provision 済 IAM role 流用) / `kubernetes/components/cilium/*` (= Hubble UI Service `hubble-ui.kube-system` は既存のまま) / `kubernetes/components/aws-load-balancer-controller/*` (= IngressGroup support 既設定) / `kubernetes/components/external-dns/*` (= `panicboat.net` filter + ingress source 既設定) / `kubernetes/components/external-secrets/*` (= 4-2 で deploy 済) / `kubernetes/components/reloader/*` (= 4-2 で deploy 済) / `kubernetes/components/oauth2-proxy/local/*` (= 本 sub-project では作成しない、production 専用) / `kubernetes/helmfile.yaml.gotmpl` (= cluster.values は既 keys で十分、ACM cert は auto-discovery 利用)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** 4-3 開始前に cluster 状態 + branch 状態 + manual setup (= Google OAuth Client + AWS Secrets Manager) を確認。Phase 4-2 完了状態 (= ESO + ClusterSecretStore + Reloader deploy 済) を baseline、4-3 で oauth2-proxy + Grafana auth.proxy で利用する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-grafana-auth-ingress
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead

```
d5d055f docs(eks): Phase 4-3 (Grafana auth + Ingress) design
```

- [ ] **Step 2: Phase 4-2 ESO + ClusterSecretStore 動作確認 (= 4-2 で deploy 済の前提を verify)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- external-secrets pods ---"
kubectl get pods -n external-secrets
echo ""
echo "--- ClusterSecretStore aws-secrets-manager Ready ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo ""
echo "--- Capabilities ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="{.status.capabilities}{\"\\n\"}"'
```

Expected:
- external-secrets pods 全 Running (= controller × 1 + webhook × 3)
- ClusterSecretStore Ready=`True`
- Capabilities=`ReadWrite`

- [ ] **Step 3: Phase 4-2 Reloader 動作確認 (= 4-2 で deploy 済の前提を verify)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n reloader
kubectl get pod -n reloader -l app.kubernetes.io/instance=reloader -o jsonpath="{.items[0].spec.priorityClassName}{\"\\n\"}"'
```

Expected:
- reloader pod Running
- priorityClassName=`system-cluster-critical`

- [ ] **Step 4: oauth2-proxy namespace 不在確認 (= 想定通り)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get namespace oauth2-proxy 2>&1 | head -3'
```

Expected: `Error from server (NotFound): namespaces "oauth2-proxy" not found`

- [ ] **Step 5: 既 deploy 済 4 backend Service 存在確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Grafana ---"
kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.spec.ports[0].port}{\"\\n\"}"
echo "--- Alertmanager ---"
kubectl get svc -n monitoring kube-prometheus-stack-alertmanager -o jsonpath="{.spec.ports[0].port}{\"\\n\"}"
echo "--- Prometheus ---"
kubectl get svc -n monitoring kube-prometheus-stack-prometheus -o jsonpath="{.spec.ports[0].port}{\"\\n\"}"
echo "--- Hubble UI ---"
kubectl get svc -n kube-system hubble-ui -o jsonpath="{.spec.ports[0].port}{\"\\n\"}"'
```

Expected:
- Grafana port = `80`
- Alertmanager port = `9093`
- Prometheus port = `9090`
- Hubble UI port = `80`

- [ ] **Step 6: ALB Controller + external-dns Pod 動作確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- ALB Controller ---"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""
echo "--- external-dns ---"
kubectl get pods -n external-dns'
```

Expected: 両 controller の Pod 全 Running

- [ ] **Step 7: ACM wildcard cert `*.panicboat.net` 状態確認**

```bash
zsh -ic 'aws acm list-certificates --region ap-northeast-1 --query "CertificateSummaryList[?DomainName==\`*.panicboat.net\`].[CertificateArn,Status]" --output text'
```

Expected: 1 行で ARN + `ISSUED` (= cert active、ALB auto-discovery で利用可)

- [ ] **Step 8: Manual setup 確認 (= panicboat による事前作業) — Google OAuth Client**

panicboat の Google Cloud project に OAuth 2.0 Client が以下要件を満たして作成済か確認:

| Section | 設定値 |
|---|---|
| ブランディング | アプリ名 `panicboat.net` / サポート / 連絡先 / 承認済みドメイン `panicboat.net` |
| 対象 | Testing status / External / **テストユーザー `panicboat@gmail.com`** |
| クライアント | Web application / 4 JavaScript origins (`https://{grafana,hubble,alertmanager,prometheus}.panicboat.net`) / 4 redirect URIs (`/oauth2/callback`) |
| データアクセス | scopes: `openid` + `.../auth/userinfo.email` + `.../auth/userinfo.profile` |

panicboat は `client_id` + `client_secret` を取得済 (= AWS Secrets Manager 投入で使用)。

確認方法は Google Cloud Console でログインし `Google Auth Platform` の各 section を visual に確認。本 step は **panicboat の手動完了 confirmation** であり、自動化されない。未完了の場合は brainstorming spec の "Manual Setup" section を参照して完了させる。

Expected: 上記 4 section 全部 complete、`client_id` + `client_secret` を panicboat の手元に保有

- [ ] **Step 9: Manual setup 確認 (= panicboat による事前作業) — AWS Secrets Manager**

panicboat が AWS Console (= eks-admin role) で 2 secrets を Secrets Manager に作成済か確認:

```bash
zsh -ic 'aws secretsmanager list-secrets --region ap-northeast-1 --query "SecretList[?Name==\`panicboat/oauth2-proxy/google\` || Name==\`panicboat/grafana/admin\`].Name" --output table'
```

Expected:

```
-------------------------------------
|             ListSecrets            |
+------------------------------------+
|  panicboat/grafana/admin           |
|  panicboat/oauth2-proxy/google     |
-------------------------------------
```

`panicboat/oauth2-proxy/google` の expected JSON 構造:

```json
{
  "client_id": "<Google から取得>",
  "client_secret": "<Google から取得>",
  "cookie_secret": "<openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' で生成>"
}
```

`panicboat/grafana/admin` の expected JSON 構造:

```json
{
  "admin-user": "admin",
  "admin-password": "<panicboat が任意で選択した強い password>"
}
```

未完了の場合は brainstorming spec の "Manual Setup" section を参照して完了させる。

- [ ] **Step 10: Phase 3 monitoring stack の健康確認 (= regression baseline)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n monitoring | grep -v Completed | grep -v "1/1\|2/2\|3/3" | head -5 || echo "(全 monitoring pod Ready)"'
```

Expected: 結果なし (= 全 monitoring pod が Ready 状態)

- [ ] **Step 11: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1 | head -3'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:02cdee0` (= Phase 4-2 learnings PR #309 merge 済) もしくはそれ以降の commit

---

## Task 1: oauth2-proxy deploy

**Files:**

- Create: `kubernetes/components/oauth2-proxy/namespace.yaml`
- Create: `kubernetes/components/oauth2-proxy/production/helmfile.yaml`
- Create: `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl`
- Create: `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/oauth2-proxy/production/kustomization/external-secret.yaml`
- Create: `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml`
- Create: `kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml`

**Context:** Phase 4-3 で deploy する oauth2-proxy chart の component 全体を新規作成。Phase 4-2 (= ESO) と同 pattern で `production/helmfile.yaml` + `production/values.yaml.gotmpl` を作成、ExternalSecret + ConfigMap + 4 Ingresses (= chart 範囲外) を `production/kustomization/` で別途 deploy。Sub-project 4-2 L1 (= chart binary verify systematic step) を Step 1-2 で適用、L2 (= chart-fixed value detection) を Step 2 で確認、L3 (= helmfile hydration の Capabilities gate) を Step 6 で render verify。

### Step 1: chart 最新 stable version 確認 (= Sub-project 4b L1 / 4-1 L1 / 4-2 L1 systematic application)

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests --force-update
helm repo update oauth2-proxy
helm search repo oauth2-proxy/oauth2-proxy --versions | head -5
```

Expected: 上位に latest stable version (= `v7.x` or それ以降) が表示。spec では `v7.x` を仮定したが、実際の最新 stable patch を採用。本 step で確認した version を Step 4 helmfile.yaml の `version:` に記入。

### Step 2: chart values の key path 確認 (= 4b L1 + 4-1 L1 + 4-2 L1 適用、特に注意 keys)

```bash
helm show values oauth2-proxy/oauth2-proxy --version <step1 で確認した version> | head -200
```

確認すべき keys (= L2 chart-fixed value detection 含む):

- `config.configFile` (= multi-line config file string、upstreams 等を直接記述)
- `extraArgs` (= command-line flags、`--reverse-proxy` / `--whitelist-domain` / `--cookie-domain` 等)
- `extraEnv` (= environment variables、Secret 由来 client_id / client_secret / cookie_secret 注入用)
- `extraVolumes` + `extraVolumeMounts` (= ConfigMap allowlist mount 用)
- `serviceMonitor` の key path (= `enabled` / `additionalLabels` / `extraLabels` / `labels` のどれか、4-2 Reloader L2 で判明した chart-fixed value pattern を要確認)
- `priorityClassName` の配置 (= top-level vs `deployment.priorityClassName`)
- `replicaCount` vs `replicas` の chart-specific value
- `image.tag` の chart-default version
- `provider` 設定 (= `google` 指定)

NOTE: chart 固有 key path に従って Step 5 values.yaml.gotmpl を調整。chart-fixed value (= override 不能 key) があれば **values での指定を省略する** (= 4-2 L2 pattern)。

### Step 3: namespace.yaml を作成

`kubernetes/components/oauth2-proxy/namespace.yaml`:

```yaml
# =============================================================================
# oauth2-proxy Namespace
# =============================================================================
# oauth2-proxy (= Google OAuth gate + reverse-proxy) の専用 namespace。
# 4 monitoring UIs (= Grafana / Hubble UI / Alertmanager / Prometheus) を
# 共通認証ゲート経由で外部公開する。ALB Ingress (IngressGroup monitoring-uis)
# も本 namespace に配置 (= Ingress.spec.backend は同 namespace の Service のみ
# 参照可能なため)。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: oauth2-proxy
  labels:
    app.kubernetes.io/name: oauth2-proxy
```

### Step 4: production/helmfile.yaml を作成

`kubernetes/components/oauth2-proxy/production/helmfile.yaml`:

```yaml
# =============================================================================
# oauth2-proxy Helmfile for production
# =============================================================================
# oauth2-proxy/oauth2-proxy chart を 1 instance shared mode で deploy。
# multi-upstream config で 4 backends (= grafana / hubble-ui / alertmanager /
# prometheus) に Host header 経由 routing。Google OAuth gate + email
# allowlist (= ConfigMap allowed-emails) で panicboat@gmail.com のみ通過。
# =============================================================================
environments:
  production:
---
repositories:
  - name: oauth2-proxy
    url: https://oauth2-proxy.github.io/manifests

releases:
  - name: oauth2-proxy
    namespace: oauth2-proxy
    chart: oauth2-proxy/oauth2-proxy
    version: "<step 1 で確認した latest stable、例 v7.x>"
    values:
      - values.yaml.gotmpl
```

### Step 5: production/values.yaml.gotmpl を作成

`kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl`:

```yaml
# oauth2-proxy Configuration for production
# Google OAuth で 4 monitoring UIs を gate、Host header 経由 4 backends に reverse-proxy。

# =============================================================================
# Replicas (HA = 2)
# =============================================================================
# 1 instance shared topology のため、SPOF 回避目的で 2 replicas に設定。
# ALB target group で 2 endpoints HA。
replicaCount: 2

# =============================================================================
# Priority Class
# =============================================================================
# 認証ゲートは 4 monitoring UIs の access 前提条件、Phase 4-2 ESO / Reloader と
# 同 priority に揃え、CPU 逼迫 node でも preempt 動作で確実に schedule する。
priorityClassName: system-cluster-critical

# =============================================================================
# Resources
# =============================================================================
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi

# =============================================================================
# Provider: Google OAuth
# =============================================================================
config:
  # client_id / client_secret / cookie_secret は extraEnv から ExternalSecret 由来
  # K8s Secret を参照、values 内には記述しない (= secret 漏洩防止)
  configFile: |-
    provider = "google"
    email_domains = [ "*" ]
    upstreams = [
      "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80",
      "http://hubble-ui.kube-system.svc.cluster.local:80",
      "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093",
      "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
    ]
    cookie_domains = [ ".panicboat.net" ]
    whitelist_domains = [ ".panicboat.net" ]
    cookie_secure = true
    cookie_httponly = true
    cookie_samesite = "lax"
    pass_authorization_header = true
    pass_access_token = true
    set_authorization_header = true
    set_xauthrequest = true
    skip_provider_button = true
    reverse_proxy = true
    authenticated_emails_file = "/etc/oauth2-proxy/emails/allowed"

# =============================================================================
# Extra Environment Variables (= Secret 由来 credentials)
# =============================================================================
# ExternalSecret (= panicboat/oauth2-proxy/google) が sync する K8s Secret
# `oauth2-proxy-google` から client-id / client-secret / cookie-secret を注入。
extraEnv:
  - name: OAUTH2_PROXY_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: oauth2-proxy-google
        key: client-id
  - name: OAUTH2_PROXY_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: oauth2-proxy-google
        key: client-secret
  - name: OAUTH2_PROXY_COOKIE_SECRET
    valueFrom:
      secretKeyRef:
        name: oauth2-proxy-google
        key: cookie-secret

# =============================================================================
# Extra Volumes & Volume Mounts (= ConfigMap allowlist)
# =============================================================================
# ConfigMap `oauth2-proxy-allowed-emails` (= kustomization で deploy) を mount、
# config.configFile の `authenticated_emails_file` で参照。ConfigMap 変更時は
# Reloader が auto-rollout (= deploymentAnnotations 参照)。
extraVolumes:
  - name: emails
    configMap:
      name: oauth2-proxy-allowed-emails
extraVolumeMounts:
  - name: emails
    mountPath: /etc/oauth2-proxy/emails
    readOnly: true

# =============================================================================
# Deployment Annotations (= Reloader watch)
# =============================================================================
# ESO 由来 Secret `oauth2-proxy-google` 変更時 + ConfigMap `oauth2-proxy-allowed-emails`
# 変更時に Reloader が自動 rollout する。
deploymentAnnotations:
  reloader.stakater.com/auto: "true"

# =============================================================================
# Service (= ClusterIP、ALB Ingress backend として利用)
# =============================================================================
service:
  type: ClusterIP
  portNumber: 80

# =============================================================================
# ServiceMonitor (= kube-prometheus-stack の serviceMonitorSelector に乗る)
# =============================================================================
# NOTE: chart の ServiceMonitor key path は Step 2 で確認した値を使用。
# 4-2 Reloader L2 (= chart-fixed value pattern) があれば labels 省略で対応、
# panicboat の `serviceMonitorSelector: {}` (= permissive) で全 SM が match する。
serviceMonitor:
  enabled: true
  # labels block は Step 2 確認結果に応じて記述 / 省略を判断
```

NOTE: 上記 values.yaml.gotmpl の `serviceMonitor` block 中の `labels` は **Step 2 で chart 構造を確認後に最終調整**:

- `labels` が override 可能 → `release: kube-prometheus-stack` を明示指定 (= 1-4-2 ServiceMonitor pattern と統一)
- `labels` が chart-fixed (= 例: 値固定) → block 省略 (= 4-2 L2 pattern、`serviceMonitorSelector: {}` の permissive 設定で対応)

### Step 6: helmfile template で render verify (= 4-2 L1 / L2 / L3 適用)

```bash
cd kubernetes
helmfile -e production -f components/oauth2-proxy/production/helmfile.yaml template 2>&1 | tail -40
cd ..
```

Expected:
- helmfile template execution success、no error
- 出力に以下 resource が含まれる:
  - `kind: Deployment` (= oauth2-proxy)
  - `kind: Service` (= oauth2-proxy)
  - `kind: ServiceAccount`
  - `kind: ServiceMonitor` (= 4-2 L3 適用、render されない場合は `helmDefaults.args: ["--api-versions=monitoring.coreos.com/v1"]` を helmfile.yaml に追加して再実行)
  - `kind: Secret` (= chart が config.configFile を Secret 化、values で記述した plain config を含む)

```bash
helmfile -e production -f kubernetes/components/oauth2-proxy/production/helmfile.yaml template 2>&1 | grep -E "kind: |^# Source: " | head -20
```

Expected: 上記 4-5 resource 種類が並ぶ。

### Step 7: ExternalSecret kustomization を作成

`kubernetes/components/oauth2-proxy/production/kustomization/external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: oauth2-proxy Google OAuth credentials
# =============================================================================
# AWS Secrets Manager の panicboat/oauth2-proxy/google を K8s Secret
# oauth2-proxy-google (= 3 keys) に sync。Reloader が Secret 変更を検知して
# oauth2-proxy Deployment auto-rollout (= 強制 logout 全 user 等の rotation 対応)。
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: oauth2-proxy-google
  namespace: oauth2-proxy
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: oauth2-proxy-google
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

### Step 8: ConfigMap (allowed emails) kustomization を作成

`kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml`:

```yaml
# =============================================================================
# ConfigMap: oauth2-proxy email allowlist
# =============================================================================
# oauth2-proxy の authenticated_emails_file が参照する allowlist。1 行 1 email、
# panicboat@gmail.com のみ。Workspace 契約後は config.configFile の
# email_domains に切替予定 (= Phase 6+ 引き継ぎ #11)。
# Reloader が ConfigMap 変更を検知して oauth2-proxy auto-rollout
# (= deploymentAnnotations の reloader.stakater.com/auto: "true")。
# =============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: oauth2-proxy-allowed-emails
  namespace: oauth2-proxy
data:
  allowed: |
    panicboat@gmail.com
```

### Step 9: Ingress (= IngressGroup monitoring-uis) kustomization を作成

`kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml`:

```yaml
# =============================================================================
# Ingress: monitoring-uis IngressGroup
# =============================================================================
# 4 Ingresses (= grafana / hubble / alertmanager / prometheus) が同一 ALB を
# IngressGroup `monitoring-uis` で共有。各 Ingress の backend は同 namespace の
# oauth2-proxy Service。oauth2-proxy が Host header から upstream を選択。
#
# ACM cert auto-discovery: ALB Controller は wildcard cert *.panicboat.net を
# 自動的に attach する (= Ingress.host が SAN にマッチ)。explicit
# certificate-arn annotation は不要。
#
# external-dns annotation: hostname を Route53 record として自動作成
# (= aws-load-balancer-controller / external-dns 連携)。
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-uis-grafana
  namespace: oauth2-proxy
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /ping
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: grafana.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: grafana.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-uis-hubble
  namespace: oauth2-proxy
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /ping
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: hubble.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: hubble.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-uis-alertmanager
  namespace: oauth2-proxy
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /ping
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: alertmanager.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: alertmanager.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-uis-prometheus
  namespace: oauth2-proxy
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /ping
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: prometheus.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: prometheus.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 80
```

### Step 10: kustomization.yaml を作成

`kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# oauth2-proxy production kustomization
# =============================================================================
# chart 範囲外 resource (= ExternalSecret + ConfigMap + 4 Ingresses) を
# helmfile output に上乗せする overlay。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - allowed-emails-configmap.yaml
  - ingress-monitoring-uis.yaml
```

### Step 11: Diff 確認

```bash
git status
git diff --stat
```

Expected: 7 新規ファイル
- `kubernetes/components/oauth2-proxy/namespace.yaml`
- `kubernetes/components/oauth2-proxy/production/helmfile.yaml`
- `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl`
- `kubernetes/components/oauth2-proxy/production/kustomization/kustomization.yaml`
- `kubernetes/components/oauth2-proxy/production/kustomization/external-secret.yaml`
- `kubernetes/components/oauth2-proxy/production/kustomization/allowed-emails-configmap.yaml`
- `kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml`

### Step 12: Commit

```bash
git add kubernetes/components/oauth2-proxy/
git commit -s -m "feat(eks): oauth2-proxy auth gate for monitoring UIs (Phase 4-3)"
```

Expected: 7 files changed、commit subject ≤ 72 chars (= 65 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 2: prometheus-operator Grafana modifications

**Files:**

- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`
- Create: `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/prometheus-operator/production/kustomization/grafana-admin-external-secret.yaml`

**Context:** 既 deploy 済の kube-prometheus-stack chart values の Grafana subchart 部分を修正、adminPassword の hardcode (= `panicboat-2026`) を `existingSecret` 参照に置換、`auth.proxy` mode を有効化、Reloader annotation を追加。Grafana admin secret を ExternalSecret で `panicboat/grafana/admin` から sync する kustomization を新規追加 (= ESO 既存 ClusterSecretStore 経由)。

### Step 1: 既存 values.yaml.gotmpl の Grafana 部分を確認

```bash
sed -n '1,60p' kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
```

Expected: 1-99 行に Grafana subchart 関連設定が存在 (= `grafana.enabled: true` / `grafana.adminPassword: "panicboat-2026"` / sidecar / datasources 等)。

### Step 2: values.yaml.gotmpl の Grafana 部分を修正

修正対象は **adminPassword の置換** + **auth.proxy mode 追加** + **Reloader annotation 追加**。既存 datasources / persistence / sidecar / resources / deploymentStrategy はそのまま維持。

修正後の Grafana section (= line 1-50 周辺の前半部分):

```yaml
# =============================================================================
# Grafana Configuration
# =============================================================================
grafana:
  enabled: true
  testFramework:
    enabled: false

  # admin password は ESO + AWS Secrets Manager 経由 (= ExternalSecret
  # grafana-admin-external-secret.yaml で K8s Secret grafana-admin に sync)。
  # adminPassword hardcode は廃止、existingSecret で Secret 参照。
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password

  # Reloader watch annotation (= Phase 4-2 deploy 済)。
  # Secret grafana-admin (= ExternalSecret 由来) の変更を検知して auto-rollout、
  # AWS Secrets Manager 側の admin-password rotation で Grafana を再起動する。
  deploymentAnnotations:
    reloader.stakater.com/auto: "true"

  # -------------------------------------------------------------------------
  # Authentication: auth.proxy mode (= oauth2-proxy 連携)
  # -------------------------------------------------------------------------
  # oauth2-proxy が X-Forwarded-User header に email を inject、Grafana が
  # 同 header から user を auto-create + role mapping する。direct admin login
  # (= existingSecret password) は緊急時の fallback として並走。
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User
      header_property: username
      auto_sign_up: true
      sync_ttl: 60
    users:
      auto_assign_org: true
      auto_assign_org_role: Admin

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

  persistence:
    enabled: true
    size: 5Gi
    storageClassName: gp3

  # ReadWriteOnce な EBS PVC を使うため、RollingUpdate (= 古い Pod 保持中に新 Pod 起動)
  # だと Multi-Attach error で新 Pod が PVC を取れない。Recreate (= 古い Pod 停止 →
  # 新 Pod 起動) でダウンタイム数十秒を許容しつつ rollout を確実にする。
  deploymentStrategy:
    type: Recreate

  # -------------------------------------------------------------------------
  # (以下既存セクション = sidecar / datasources を変更なしで維持)
  # -------------------------------------------------------------------------
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL
    datasources:
      defaultDatasourceEnabled: false

  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Mimir
          uid: mimir
          type: prometheus
          url: http://mimir-distributed-gateway.monitoring.svc.cluster.local/prometheus
          access: proxy
          isDefault: true
          jsonData:
            httpMethod: POST
            timeInterval: 30s
        - name: Prometheus (local)
          uid: prometheus-local
          type: prometheus
          url: http://prometheus-operated.monitoring.svc.cluster.local:9090
          access: proxy
          isDefault: false
          jsonData:
            httpMethod: POST
            timeInterval: 30s
        - name: Loki
          uid: loki
          type: loki
          url: http://loki-gateway.monitoring.svc.cluster.local
          access: proxy
          isDefault: false
          jsonData:
            httpHeaderName1: X-Scope-OrgID
          secureJsonData:
            httpHeaderValue1: anonymous
        - name: Tempo
          uid: tempo
          type: tempo
          url: http://tempo.monitoring.svc.cluster.local:3200
          access: proxy
          isDefault: false
          jsonData:
            httpMethod: GET
            tracesToLogsV2:
              datasourceUid: loki
            tracesToMetrics:
              datasourceUid: mimir
```

実装時は **既存 file の Grafana section を上記 block と置換**、prometheus / alertmanager / 他 subchart settings は変更しない。

修正コマンド (= Edit tool 利用想定):
- `old_string`: 既存の `grafana:` block 全体 (= line 1-100 周辺、`# =====` で区切られた次 section の前まで)
- `new_string`: 上記 修正後 Grafana section

### Step 3: kustomization/grafana-admin-external-secret.yaml を作成

`kubernetes/components/prometheus-operator/production/kustomization/grafana-admin-external-secret.yaml`:

```yaml
# =============================================================================
# ExternalSecret: Grafana admin password
# =============================================================================
# AWS Secrets Manager の panicboat/grafana/admin を K8s Secret grafana-admin
# (= 2 keys: admin-user / admin-password) に sync、kube-prometheus-stack chart の
# grafana.admin.existingSecret から参照される。Reloader が Secret 変更を検知して
# Grafana Deployment auto-rollout (= deploymentAnnotations 参照)。
# =============================================================================
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

### Step 4: kustomization/kustomization.yaml を作成

`kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# prometheus-operator production kustomization
# =============================================================================
# chart 範囲外 resource (= Grafana admin ExternalSecret) を helmfile output に
# 上乗せする overlay。既存 chart-deployed Grafana Deployment が本 ExternalSecret
# 由来の Secret grafana-admin を grafana.admin.existingSecret 経由で参照する。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana-admin-external-secret.yaml
```

### Step 5: helmfile template で render verify

```bash
cd kubernetes
helmfile -e production -f components/prometheus-operator/production/helmfile.yaml template 2>&1 | grep -B2 -A5 "kind: Deployment$" | grep -A 5 "kube-prometheus-stack-grafana"
cd ..
```

Expected: Grafana Deployment の env / volumes に **adminUser / adminPassword の hardcoded value がない** こと、Secret reference (= existingSecret) で挿入される構造。

```bash
cd kubernetes
helmfile -e production -f components/prometheus-operator/production/helmfile.yaml template 2>&1 | grep -A 10 "auth.proxy" | head -15
cd ..
```

Expected: render 出力 (= ConfigMap or grafana.ini) に `[auth.proxy]` block と `enabled = true` が含まれる。

### Step 6: Diff 確認

```bash
git status
git diff --stat
```

Expected:
- 修正: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` (= Grafana section 修正)
- 新規: `kubernetes/components/prometheus-operator/production/kustomization/kustomization.yaml`
- 新規: `kubernetes/components/prometheus-operator/production/kustomization/grafana-admin-external-secret.yaml`

### Step 7: Commit

```bash
git add kubernetes/components/prometheus-operator/
git commit -s -m "feat(eks): Grafana auth.proxy + ESO admin password (Phase 4-3)"
```

Expected: 3 files changed、commit subject ≤ 72 chars (= 64 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 3: Hydrate manifests + verify

**Files:**

- Modify (auto-generated): `kubernetes/manifests/production/oauth2-proxy/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/prometheus-operator/manifest.yaml` (= ExternalSecret + Grafana values 反映)
- Modify (auto-generated): `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= oauth2-proxy namespace block 追加)
- Modify (auto-generated): `kubernetes/manifests/production/kustomization.yaml` (= ./oauth2-proxy auto-insert)

**Context:** Task 1 + 2 で K8s component values + namespace.yaml + kustomization 修正済。Task 3 で hydrated manifests を再生成し、Flux が apply する actual YAML を更新する。

### Step 1: oauth2-proxy manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=oauth2-proxy ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/oauth2-proxy/manifest.yaml` 新規作成 (= chart render + ExternalSecret + ConfigMap + 4 Ingresses)
- `kubernetes/manifests/production/oauth2-proxy/kustomization.yaml` 新規作成 (= `resources: [manifest.yaml]`)

### Step 2: prometheus-operator manifest を再生成 (= Grafana values + ExternalSecret 反映)

```bash
cd kubernetes
make hydrate-component COMPONENT=prometheus-operator ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/prometheus-operator/manifest.yaml` 修正 (= Grafana Deployment env が existingSecret 参照に変更、auth.proxy 関連 ini 設定が grafana ConfigMap に反映、ExternalSecret 1 件追加)

### Step 3: production の 00-namespaces + kustomization を再生成

```bash
cd kubernetes
make hydrate-index ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` 更新 (= `oauth2-proxy` Namespace block 追加、alphabetical order 自動 insert)
- `kubernetes/manifests/production/kustomization.yaml` 更新 (= `./oauth2-proxy` resources line 自動 insert)

### Step 4: oauth2-proxy manifest 内容確認

```bash
grep -E "^kind: (Deployment|Service|ServiceMonitor|Ingress|ExternalSecret|ConfigMap)$" \
  kubernetes/manifests/production/oauth2-proxy/manifest.yaml | sort | uniq -c
```

Expected:
- 1 Deployment (= oauth2-proxy)
- 1 Service (= oauth2-proxy ClusterIP)
- 1 ServiceMonitor
- 4 Ingress (= grafana / hubble / alertmanager / prometheus)
- 1 ExternalSecret (= oauth2-proxy-google)
- 1 ConfigMap (= oauth2-proxy-allowed-emails)

### Step 5: 4 Ingress の host + IngressGroup name 確認

```bash
grep -B1 -A20 "name: monitoring-uis-" kubernetes/manifests/production/oauth2-proxy/manifest.yaml | grep -E "^  name:|alb.ingress.kubernetes.io/group.name|host:"
```

Expected (= 12 行、各 Ingress で 3 line ずつ):

```
  name: monitoring-uis-grafana
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    - host: grafana.panicboat.net
  name: monitoring-uis-hubble
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    - host: hubble.panicboat.net
  name: monitoring-uis-alertmanager
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    - host: alertmanager.panicboat.net
  name: monitoring-uis-prometheus
    alb.ingress.kubernetes.io/group.name: monitoring-uis
    - host: prometheus.panicboat.net
```

### Step 6: oauth2-proxy upstreams config 確認

```bash
grep -A 6 "upstreams" kubernetes/manifests/production/oauth2-proxy/manifest.yaml | head -10
```

Expected: `upstreams = [` line に続いて 4 backend URLs (= grafana / hubble-ui / alertmanager / prometheus) が含まれる。

### Step 7: oauth2-proxy ExternalSecret + ConfigMap 内容確認

```bash
echo "--- ExternalSecret ---"
grep -B1 -A15 "name: oauth2-proxy-google$" kubernetes/manifests/production/oauth2-proxy/manifest.yaml | head -20
echo ""
echo "--- ConfigMap ---"
grep -B1 -A5 "name: oauth2-proxy-allowed-emails$" kubernetes/manifests/production/oauth2-proxy/manifest.yaml | head -10
```

Expected:
- ExternalSecret に 3 keys (= client-id / client-secret / cookie-secret) + remoteRef.key=`panicboat/oauth2-proxy/google`
- ConfigMap data.allowed に `panicboat@gmail.com` のみ

### Step 8: prometheus-operator Grafana 修正反映確認

```bash
echo "--- Grafana adminPassword hardcode が消えたこと (panicboat-2026 不在) ---"
grep "panicboat-2026" kubernetes/manifests/production/prometheus-operator/manifest.yaml || echo "OK: hardcode removed"
echo ""
echo "--- existingSecret 参照あり ---"
grep -B1 -A3 "existingSecret" kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -10
echo ""
echo "--- grafana-admin ExternalSecret 追加あり ---"
grep -B1 -A10 "name: grafana-admin$" kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -15
echo ""
echo "--- auth.proxy mode 追加あり ---"
grep -A 4 "auth.proxy" kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -10
echo ""
echo "--- Reloader annotation 追加あり ---"
grep -B1 -A1 "reloader.stakater.com/auto" kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -10
```

Expected:
- "OK: hardcode removed" 表示 (= panicboat-2026 文字列が manifest 内に存在しない)
- existingSecret: `grafana-admin` の reference 表示
- ExternalSecret `grafana-admin` resource block 表示
- `[auth.proxy]` block + `enabled = true` 表示
- Grafana Deployment annotations に `reloader.stakater.com/auto: "true"` 表示

### Step 9: 00-namespaces.yaml に oauth2-proxy namespace 追加確認

```bash
grep -B1 -A3 "name: oauth2-proxy" kubernetes/manifests/production/00-namespaces/namespaces.yaml | head -10
```

Expected: oauth2-proxy namespace block が表示される。

### Step 10: production kustomization.yaml に ./oauth2-proxy 追加確認

```bash
grep "oauth2-proxy" kubernetes/manifests/production/kustomization.yaml
```

Expected: `  - ./oauth2-proxy` が resources list に含まれる (= alphabetical order)。

### Step 11: kustomize build で全体 manifest が valid render することを確認

```bash
kustomize build kubernetes/manifests/production 2>&1 | tail -10
```

Expected: error なし、最後に何らかの YAML resource が出力される (= kustomization build success)。

### Step 12: Diff 確認

```bash
git status
git diff --stat
```

Expected:
- 新規: `production/oauth2-proxy/{kustomization.yaml, manifest.yaml}`
- 修正: `production/prometheus-operator/manifest.yaml` (= Grafana / ExternalSecret 反映)
- 修正: `production/00-namespaces/namespaces.yaml` (= oauth2-proxy 追加)
- 修正: `production/kustomization.yaml` (= ./oauth2-proxy 追加)

### Step 13: Commit

```bash
git add kubernetes/manifests/
git commit -s -m "feat(eks): hydrate oauth2-proxy + Grafana auth.proxy (Phase 4-3)"
```

Expected: 4-5 files changed、commit subject ≤ 72 chars (= 65 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 4: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Task 1-3 完了後の commit 累計 4 件 (= spec + 3 implementation)。AWS-side terragrunt apply は **本 sub-project では不要** (= Phase 4-2 で provision 済 IAM role を流用)。K8s-side は PR merge 後に Flux reconcile で auto apply、AWS / Google manual setup (= Task 0 Step 8 / 9 で確認) は merge 前に panicboat により完了済。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-grafana-auth-ingress
git log --oneline origin/main..HEAD
```

Expected: 4 commits ahead (Task 1-3 の 3 commits + spec commit)

```
<sha> feat(eks): hydrate oauth2-proxy + Grafana auth.proxy (Phase 4-3)
<sha> feat(eks): Grafana auth.proxy + ESO admin password (Phase 4-3)
<sha> feat(eks): oauth2-proxy auth gate for monitoring UIs (Phase 4-3)
d5d055f docs(eks): Phase 4-3 (Grafana auth + Ingress) design
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (= 既 spec push 時に push 済)、push success message。track 未設定の場合は `git push -u origin HEAD`。

### Step 3: PR title 文字数チェック (≤ 72 chars)

```bash
echo -n "feat(eks): Phase 4-3 — Grafana auth + monitoring UIs Ingress" | wc -m
```

Expected: 60 chars (em dash 含む、Sub-project 4-1 / 4-2 の PR title 命名 pattern と整合)

### Step 4: Draft PR を作成 (Pre-flight check 結果を含む)

PR body は以下:

````markdown
## Summary

Phase 4-3 (Grafana auth + Ingress) の implementation。`oauth2-proxy/oauth2-proxy` v7.x を `oauth2-proxy` namespace に 1 instance shared mode で deploy、4 ALB Ingress (= IngressGroup `monitoring-uis` で 1 ALB 共有) で 4 monitoring UIs (= Grafana / Hubble UI / Alertmanager / Prometheus) を internet-facing 公開。Grafana adminPassword を ESO + AWS Secrets Manager 経由 (= `panicboat/grafana/admin`) に置換、`auth.proxy` mode で oauth2-proxy 由来 SSO 連携。Phase 4-2 で deploy 済の ESO + ClusterSecretStore + Reloader を全面活用 (= 新規 AWS terragrunt stack 不要)。

本 sub-project 完了 = roadmap **Phase 4 (Secrets & App readiness) 完了** = Phase 5 nginx end-to-end validation の全 prerequisite 達成。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`
- plan: `docs/superpowers/plans/2026-05-09-eks-production-grafana-auth-ingress.md`

## Notable Decisions

- 公開対象 4 UIs = `Grafana / Hubble UI / Alertmanager / Prometheus` 一括 (= 共通認証ゲート設計)
- 認証 provider = Google OAuth (= panicboat@gmail.com)、認証 mechanism = oauth2-proxy + Grafana auth.proxy mode (= true SSO)
- Ingress = ALB (= ACM wildcard cert auto-discovery)、ALB scheme = internet-facing、ALB sharing = 1 ALB shared via IngressGroup `monitoring-uis`
- oauth2-proxy topology = 1 instance shared (= multi-upstream)、replicas: 2 で HA
- email allowlist 粒度 = `panicboat@gmail.com` のみ ConfigMap 管理 (= Workspace 契約後に domain allowlist 化可)
- secrets 管理 = 全 secret (= 4 種類: Grafana admin / oauth2-proxy 3 keys) を ESO + AWS Secrets Manager 経由

## Pre-flight check (executed pre-merge)

- [x] Branch state 確認 (= spec + 3 implementation commits ahead)
- [x] Phase 4-2 ESO + ClusterSecretStore Ready=True、Capabilities=ReadWrite
- [x] Phase 4-2 Reloader Pod Running with system-cluster-critical priority
- [x] oauth2-proxy namespace 不在 (= 想定通り)
- [x] 4 backend Service (= grafana / hubble-ui / alertmanager / prometheus) 存在 + port 確認
- [x] ALB Controller + external-dns Pod 動作確認
- [x] ACM wildcard cert `*.panicboat.net` ISSUED 確認
- [x] Manual setup: Google OAuth Client 4 sections (= ブランディング / 対象 / クライアント / データアクセス) 完了
- [x] Manual setup: AWS Secrets Manager `panicboat/oauth2-proxy/google` + `panicboat/grafana/admin` 投入完了
- [x] Phase 3 monitoring stack の健康確認
- [x] Flux state suspended でない確認

## Test plan (post-flight, after merge)

### 5 分以内

- [ ] Flux が main の latest commit を Applied
- [ ] oauth2-proxy namespace が created
- [ ] oauth2-proxy Pod 2 replicas Running、`/ping` health check 200
- [ ] ExternalSecret `oauth2-proxy/oauth2-proxy-google` Status=Ready、K8s Secret created
- [ ] ConfigMap `oauth2-proxy/oauth2-proxy-allowed-emails` created with panicboat@gmail.com
- [ ] ExternalSecret `monitoring/grafana-admin` Status=Ready、K8s Secret created
- [ ] Grafana Pod が Recreate strategy で rollout、Ready
- [ ] 4 Ingress resources が Ready、Status.LoadBalancer.Ingress[0].Hostname に ALB DNS 反映
- [ ] ALB が 1 台 provision (= IngressGroup `monitoring-uis`)、internet-facing scheme

### 30 分以内

- [ ] Route53 record 4 件が external-dns で created (= `{grafana,hubble,alertmanager,prometheus}.panicboat.net`)
- [ ] DNS 解決 → ALB DNS 名で resolve 可能
- [ ] `https://grafana.panicboat.net` browser access → Google OAuth へ redirect → panicboat@gmail.com で login → Grafana に auto-login で Admin role 反映
- [ ] 同 browser session で `https://hubble.panicboat.net` / `https://alertmanager.panicboat.net` / `https://prometheus.panicboat.net` access → 再 login なしで通過 (= SSO 動作確認)
- [ ] 別アカウント (= panicboat@gmail.com 以外) で login 試行 → ConfigMap allowlist で reject、backend に到達しない

### 60 分以内 (= Reloader integration)

- [ ] AWS Secrets Manager で `panicboat/grafana/admin.admin-password` を任意の値に変更 → 1h refresh wait or `kubectl annotate externalsecret -n monitoring grafana-admin force-sync=now` で manual force-sync → K8s Secret update → Reloader が Grafana Pod rollout 検知 → 新 Pod 起動で direct admin login が新 password で成功

### Sub-project 4a L3 + 4-1 L2 + 4-2 L2 / L3 適用 (= persistent vs transient checklist)

- 起動 ~60s 以内の "no endpoints available" / "optimistic locking" 系 error は normal (= startup transient)、`kubectl logs --since=2m` で recent state を見る
- ServiceMonitor が hydrate 出力に存在しない場合、helmfile.yaml に `helmDefaults.args: ["--api-versions=monitoring.coreos.com/v1"]` を追加して再 hydrate (= 4-2 L3 適用)
- chart values の `serviceMonitor.labels` が反映されない場合、chart-fixed value (= 4-2 L2) で labels block 省略を確認、panicboat の `serviceMonitorSelector: {}` で全 SM が match することを確認

## Sub-project 1-4-2 learnings 適用

- L1 (= chart binary verify systematic step): oauth2-proxy chart の latest stable version + ServiceMonitor key path / extraEnv structure / multi-upstream config を Step 1-2 で確認、render verify を Step 6 で実施
- L2 (= chart-fixed value conflict pattern): oauth2-proxy chart の `serviceMonitor.labels` 等を `helm template` 出力で事前確認、override 不能なら labels block 省略
- L3 (= helmfile hydration Capabilities gate workaround): ServiceMonitor が render されない場合、`helmDefaults.args: ["--api-versions=monitoring.coreos.com/v1"]` で declarative override
- L4 (= 急進化 chart の design assumption gap): oauth2-proxy chart の apiVersion / values 構造は brainstorming 時 snapshot、実装時に再 verify 前提
- L5 (= AWS direct verify AccessDenied → application-level indirect proof): post-flight check で AWS direct verify が blocked された場合、K8s API + chart status (= ExternalSecret Ready=True / ALB Ingress Status.Hostname / Grafana login success) を primary signal に
- L6 (= subagent-driven development cadence): Plan Task 数を chart A / chart B / hydrate の 3 layer split で踏襲 (= AWS terragrunt 不要、`oauth2-proxy / prometheus-operator modify / hydrate` の 3 task)
- 4-1 L5 (= chart version placeholder pattern): spec の chart version は placeholder OK、Step 1 で latest stable 確認

## Rollback 手順 (想定外障害時)

```bash
# Pattern A: Standard rollback (= Flux suspend + revert)
flux suspend kustomization flux-system -n flux-system
gh pr create --base main --head revert-phase-4-3 --title "revert: Phase 4-3 (Grafana auth + Ingress)" --draft
gh pr merge <pr-number>
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

# Pattern B: Partial rollback (= ALB Ingress のみ削除、認証本体は維持)
# 4 Ingress resources のみ削除する PR、ALB Controller が ALB cleanup、external-dns が record 削除
# oauth2-proxy + Grafana auth.proxy 設定は維持

# Pattern C: Auth gate bypass (= 緊急対応、oauth2-proxy 障害時の Grafana access)
# kubernetes/components/prometheus-operator/production/values.yaml.gotmpl で:
#   auth.anonymous.enabled: true
#   auth.proxy.enabled: false
# に temporary 切替、port-forward で operator が緊急 admin login (= adminPassword 経由)、
# revert で元に戻す (= Pattern A 類似)
```
````

Push command:

```bash
gh pr create --draft \
  --base main \
  --head docs/eks-production-grafana-auth-ingress \
  --title "feat(eks): Phase 4-3 — Grafana auth + monitoring UIs Ingress" \
  --body-file /tmp/pr-body-4-3.md
```

(= PR body を `/tmp/pr-body-4-3.md` に書き出してから `--body-file` で参照)

Expected: Draft PR created、PR URL 表示

---

## Summary

本 sub-project は **Phase 4 (Secrets & App readiness) の最終 sub-project**、完了 = roadmap Phase 4 全完了 = Phase 5 nginx 投入の全 prerequisite 達成。Grafana adminPassword を ESO 経由化、4 monitoring UIs を internet-facing ALB + oauth2-proxy 共通認証ゲートで公開、Google OAuth + email allowlist で panicboat 個人運用にスケーリング。Phase 4-2 で deploy 済の ESO + Reloader を **actual end-to-end use case** として活用、新規 AWS terragrunt stack 不要 (= IAM role 流用) で operational footprint 最小化。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`
- plan: `docs/superpowers/plans/2026-05-09-eks-production-grafana-auth-ingress.md`

## Notable Decisions

| Decision | 採用 |
|---|---|
| 公開 UI scope | Grafana + Hubble UI + Alertmanager + Prometheus (= 4 UIs) |
| 認証 provider | Google OAuth (= panicboat@gmail.com) |
| 認証 mechanism | oauth2-proxy + Grafana auth.proxy mode (= true SSO) |
| Ingress | ALB Ingress (= ACM wildcard cert auto-discovery) |
| ALB scheme | internet-facing |
| ALB sharing | 1 ALB shared via IngressGroup `monitoring-uis` |
| Email allowlist | panicboat@gmail.com のみ ConfigMap 管理 |
| Secrets 管理 | 全 secret を ESO + AWS Secrets Manager (= 4 keys total) |
| oauth2-proxy topology | 1 instance shared (= multi-upstream)、replicas: 2 で HA |
| OAuth Client | External + Testing status (= 100 user 永続運用) |
| AWS terragrunt | 不要 (= Phase 4-2 ESO IAM role 流用) |

## Implementation 補記

- ALB cert は **auto-discovery** (= explicit `certificate-arn` annotation 不要、wildcard `*.panicboat.net` が 4 host に SAN match)
- IngressGroup の `group.order` annotation は不要 (= 4 Ingress が host で完全分離、conflict なし)。将来 `panicboat.net` 直下 (= apex) に Ingress 追加時は order 設計が必要
- oauth2-proxy の SPOF 回避: replicas: 2 (= chart values で明示)、ALB target group で 2 endpoints HA
- Grafana auth.proxy + adminPassword 並走: adminPassword は emergency 用 fallback (= auth.proxy 障害時の port-forward + admin login)、normal use case では auth.proxy のみ
- ConfigMap allowlist の Reloader watch: oauth2-proxy Deployment annotation `reloader.stakater.com/auto: "true"` で ConfigMap + Secret 両方の変更が auto-rollout trigger
- cookie domain `.panicboat.net` で 4 host SSO: 1 回 login → 4 UI 全部に access、cookie_secret rotation で全 user 強制 logout 可能

## Pre-flight check (executed pre-merge)

(= 上記 PR body の Pre-flight check と同内容)

## Test plan (post-flight, after merge)

(= 上記 PR body の Test plan と同内容)

## Sub-project 1-4-2 learnings 適用

(= 上記 PR body の learnings 適用と同内容)

## Rollback 手順 (想定外障害時)

(= 上記 PR body の Rollback 手順と同内容)

## Self-review

### Spec coverage check

| Spec section | Plan task |
|---|---|
| Architecture (= request flow) | Task 1 (= oauth2-proxy values で実現)、Task 2 (= Grafana auth.proxy で実現) |
| Components & File Structure | File Structure section + Task 1 / Task 2 / Task 3 |
| Manual Setup (= Google + AWS) | Task 0 Step 8 / Step 9 で confirm |
| Decisions (= 11 件) | "Notable Decisions" section に同 11 件 |
| Post-flight Check (= 15 項目) | "Test plan (post-flight)" section に時系列分類で同等 15+ 項目 |
| Rollback Patterns (= 3 patterns) | "Rollback 手順" section に同 3 patterns |
| Risks & Mitigations | "Implementation 補記" + "Test plan" の transient checklist |
| Out of Scope | spec-only (= plan には記述しない、scope 確認のみ) |
| Phase 4 引き継ぎ事項 update | spec-only (= post-execution learnings PR で update する pattern) |
| Phase 4 完了状態 | Summary + PR body Summary に記載 |
| Sub-project 1-4-2 learnings 適用 | "Sub-project 1-4-2 learnings 適用" section |

### Type / Property name consistency

- [x] `oauth2-proxy` namespace name (Task 1 namespace.yaml + production helmfile.yaml + values.yaml.gotmpl + ExternalSecret + ConfigMap + Ingress): 全て同一
- [x] `oauth2-proxy-google` Secret name (Task 1 ExternalSecret target + values.yaml.gotmpl extraEnv secretKeyRef): 全て同一
- [x] `oauth2-proxy-allowed-emails` ConfigMap name (Task 1 ConfigMap + values.yaml.gotmpl extraVolumes): 全て同一
- [x] `monitoring-uis` IngressGroup name (Task 1 4 Ingresses の `alb.ingress.kubernetes.io/group.name` annotation): 全て同一
- [x] `aws-secrets-manager` ClusterSecretStore name (Task 1 + Task 2 ExternalSecret): 4-2 で deploy 済の ClusterSecretStore name と一致
- [x] `panicboat/oauth2-proxy/google` AWS Secret name (Task 0 Step 9 + Task 1 ExternalSecret remoteRef.key): 全て同一
- [x] `panicboat/grafana/admin` AWS Secret name (Task 0 Step 9 + Task 2 ExternalSecret remoteRef.key): 全て同一
- [x] `grafana-admin` K8s Secret name (Task 2 ExternalSecret target + prometheus-operator values existingSecret): 全て同一
- [x] `system-cluster-critical` priority class (Task 1 oauth2-proxy values priorityClassName): Phase 4-2 ESO / Reloader と同 priority
- [x] `release: kube-prometheus-stack` ServiceMonitor label (Task 1 oauth2-proxy values + Task 2 prometheus-operator values): Sub-project 1-4-2 ServiceMonitor pattern と整合
- [x] 4 host names (= `{grafana,hubble,alertmanager,prometheus}.panicboat.net`): Task 0 Step 8 (Google OAuth redirect URIs) + Task 1 Ingress + values.yaml.gotmpl upstreams + post-flight test 全箇所で同一
- [x] 4 backend Service FQDNs (= `kube-prometheus-stack-grafana.monitoring`, `hubble-ui.kube-system`, `kube-prometheus-stack-alertmanager.monitoring`, `kube-prometheus-stack-prometheus.monitoring`): Task 0 Step 5 verify + Task 1 values upstreams で一致
- [x] commit subject prefix: `feat(eks):` (= 3 commits)、Sub-project 4a / 4b / 4-1 / 4-2 と整合
