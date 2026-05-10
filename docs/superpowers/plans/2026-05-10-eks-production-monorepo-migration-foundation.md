# EKS Production: Phase 6-1 Monorepo Migration Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) に **monorepo migration prerequisite** として共有 Cilium Gateway resource + Flux GitRepository monorepo + OTel Operator chart を deploy。Phase 6-2 で application services (= monolith / frontend / reverse-proxy) を deploy 可能な platform foundation を ready にする。

**Architecture:** 3 component を deploy: (a) Cilium 共有 Gateway resource を `kubernetes/components/cilium/production/kustomization/` の既存 kustomization に追加 (= GatewayClass cilium 既存利用、既コメント update); (b) OTel Operator chart を `kubernetes/components/opentelemetry/production/` 新規作成 (= local 環境設定を踏襲、cert-manager integration 有効化); (c) Flux GitRepository monorepo + cluster Kustomization (= suspend 状態) を `kubernetes/clusters/production/repositories/` 新規作成。並行で monorepo PR (= services/nginx 削除) を merge。

**Tech Stack:** Cilium 1.18.6 (= 既 deploy 済、chart values 修正なし) / Flux v2 GitRepository + Kustomization / OTel Operator chart (= local 環境 0.112.0、production version は Task 3 で latest stable 確認 + 5-1 L1 binary verify 適用) / cert-manager (= 既 deploy 済 selfsigned-cluster-issuer 利用、admission webhook server-only TLS のため SelfSigned 可) / helmfile + values.yaml.gotmpl + kustomization pattern / hydration via Makefile

**Spec:** `docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md`

---

## File Structure

### platform 新規作成 / 修正

```
kubernetes/components/cilium/production/kustomization/
├── kustomization.yaml      # 修正 (= resources に cilium-gateway.yaml 追加 + ヘッダコメント update)
└── cilium-gateway.yaml     # 新規 (= 共有 Gateway resource、namespace default、port 80 HTTP listener)

kubernetes/components/opentelemetry/production/   # 新規 directory
├── helmfile.yaml           # 新規 (= local helmfile.yaml を踏襲、production env)
└── values.yaml.gotmpl      # 新規 (= certManager.enabled: true + autoGenerateCert.enabled: false)

kubernetes/clusters/production/repositories/      # 新規 directory
├── kustomization.yaml      # 新規 (= resources に monorepo.yaml)
└── monorepo.yaml           # 新規 (= GitRepository + Kustomization (suspend))

kubernetes/clusters/production/kustomization.yaml    # 修正 (= resources に ./repositories 追加 + コメント update)
```

### platform 自動生成 (= production hydrate output)

```
kubernetes/manifests/production/cilium/manifest.yaml         # 修正 (= 共有 Gateway resource hydrate 結果)
kubernetes/manifests/production/opentelemetry/               # 新規 directory
├── kustomization.yaml                                       # 新規
└── manifest.yaml                                            # 新規 (= chart hydrate output)
kubernetes/manifests/production/kustomization.yaml           # 修正 (= ./opentelemetry auto-insert)
kubernetes/manifests/production/00-namespaces/namespaces.yaml # 修正 (= opentelemetry-operator-system 追加、chart が auto-create する場合は不要、Task 3 で確認)
```

### monorepo 削除 (= 並行 PR、別 worktree)

```
services/nginx/                                       # 削除
clusters/develop/services/nginx/                      # 削除
clusters/develop/services/kustomization.yaml          # 修正 (= resources から nginx 行削除)
```

### 変更しないファイル

- `kubernetes/components/cilium/production/values.yaml.gotmpl` (= `gatewayAPI.enabled: true` 既設定済、修正不要)
- `kubernetes/components/cilium/production/helmfile.yaml` (= chart 1.18.6 のまま)
- `kubernetes/clusters/production/flux-system/gotk-sync.yaml` (= platform Flux 既存設定維持)
- 他 component (= Phase 1-5 で deploy 済、本 6-1 で touch なし)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** Phase 6-1 開始前に cluster 状態 + branch 状態を確認。Phase 5 完了状態 + 累計 fix forward 5 件 (= PR #305 / #311 / #312 / #314 / #316) merged 状態を baseline、Phase 6-1 で foundation 拡張する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 2 つ ahead

```
5d33c87 docs(eks): Phase 6-1 spec update — shared Gateway (P3) decision
772a28b docs(eks): Phase 6-1 — monorepo migration foundation spec
```

- [ ] **Step 2: Phase 1-5 完了状態 verify (= 主要 component 全部 Running + Cilium Gateway API 既達成確認)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Cilium 1.18.6 + GatewayClass cilium ---"
kubectl get ds -n kube-system cilium -o jsonpath="image={.spec.template.spec.containers[0].image}{\"\\n\"}"
kubectl get gatewayclass cilium -o jsonpath="Accepted={.status.conditions[?(@.type==\"Accepted\")].status}{\"\\n\"}"
echo ""
echo "--- ESO + Reloader + cert-manager ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
kubectl get pods -n reloader --no-headers | head -1
kubectl get pods -n cert-manager --no-headers | head -1
echo ""
echo "--- selfsigned-cluster-issuer + cilium-hubble-ca-issuer ---"
kubectl get clusterissuer selfsigned-cluster-issuer -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
kubectl get clusterissuer cilium-hubble-ca-issuer -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo ""
echo "--- Beyla + KEDA + observability stack ---"
kubectl get ds -n monitoring beyla --no-headers
kubectl get pods -n keda --no-headers | head -1
kubectl get pods -n monitoring -l app.kubernetes.io/name=mimir-distributed --no-headers | head -1
echo ""
echo "--- 既 nginx (Phase 5-2) ---"
kubectl get deploy -n default nginx --no-headers'
```

Expected:
- Cilium image `quay.io/cilium/cilium:v1.18.6@...` (= 1.18.6 確認)
- GatewayClass cilium Accepted=`True`
- ClusterSecretStore Ready=`True`
- Reloader / cert-manager Pod Running
- selfsigned-cluster-issuer / cilium-hubble-ca-issuer Ready=`True`
- Beyla DaemonSet 4/4 + KEDA Pod Running + Mimir Pod Running
- nginx Deployment Available

- [ ] **Step 3: GitHub monorepo public access 確認**

```bash
curl -sSI https://github.com/panicboat/monorepo/raw/main/README.md | head -3
curl -sSI https://github.com/panicboat/monorepo/raw/main/clusters/develop/services/kustomization.yaml | head -3
```

Expected:
- HTTP/2 200 (= public access OK)
- 2 file 共に accessible

- [ ] **Step 4: monorepo PR 用 worktree 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
mkdir -p .claude/worktrees
git worktree list
git fetch origin main
git worktree add -b chore/remove-nginx-service .claude/worktrees/chore-remove-nginx-service origin/main
ls .claude/worktrees/chore-remove-nginx-service/services/
```

Expected:
- worktree 作成成功
- services/ に `frontend / monolith / nginx / reverse-proxy` 4 ディレクトリ表示

---

## Task 1: Cilium 共有 Gateway resource 追加 + 既 kustomization update

**Files:**
- Create: `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml`
- Modify: `kubernetes/components/cilium/production/kustomization/kustomization.yaml`

**Context:** monorepo の `services/reverse-proxy/kubernetes/base/httproute.yaml` が parentRef `cilium-gateway` namespace `default` を指定するため、production 環境にも共有 Gateway resource を deploy。既存設計コメント (= "per-service 個別作成") を P3 decision (= 共有 Gateway 採用) に update。

- [ ] **Step 1: cilium-gateway.yaml 作成**

```yaml
# =============================================================================
# Cilium 共有 Gateway (= namespace default, listener HTTP port 80)
# =============================================================================
# Phase 6-1 (= monorepo migration foundation) で application 共有 Gateway として
# deploy。monorepo の services/reverse-proxy/kubernetes/base/httproute.yaml が
# parentRefs.name: cilium-gateway namespace: default を指定する設計。
#
# panicboat 個人運用 + 1 application (= monolith + frontend + reverse-proxy)
# 構成で per-service Gateway は YAGNI、共有 Gateway を採用 (= P3 decision)。
# 将来 multi-application 化時に per-service Gateway 設計を再評価。
#
# listener: HTTP port 80 のみ (= internal east-west routing 用、reverse-proxy
# Pod が upstream として cilium-gateway を呼ぶ)。HTTPS / TLS listener は 6-3
# DNS / ACM phase で必要時追加。
# =============================================================================
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

Path: `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml`

- [ ] **Step 2: kustomization.yaml update (= resources 追加 + ヘッダコメント update)**

```yaml
# =============================================================================
# Cilium Kustomization Overlay for production
# =============================================================================
# This kustomization adds production-specific resources to the Cilium Helm
# release output:
#   - GatewayClass: registers Cilium as the gateway-api controller
#   - Gateway "cilium-gateway" (= namespace default): shared east-west L7
#     routing entry point. Phase 6-1 (= monorepo migration foundation) で
#     application 共有 Gateway として deploy (= P3 decision)。
#
# Note: north-south は ALB Controller、east-west は cilium-gateway 経由。
# panicboat 個人運用 + 1 application 構成で per-service Gateway は YAGNI、
# 共有 Gateway を採用。将来 multi-application 化時に per-service Gateway
# 設計を再評価。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - gateway-class.yaml
  - cilium-gateway.yaml
```

Path: `kubernetes/components/cilium/production/kustomization/kustomization.yaml`

- [ ] **Step 3: kustomize build で diff 確認 (= local validation)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
kustomize build components/cilium/production/kustomization 2>&1 | head -60
```

Expected: GatewayClass cilium + Gateway cilium-gateway (= namespace default) 両方 build 成功、syntax error なし。

- [ ] **Step 4: commit cilium update**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git add kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml
git add kubernetes/components/cilium/production/kustomization/kustomization.yaml
git commit -s -m "feat(eks): Phase 6-1 — Cilium 共有 Gateway (= P3 decision)" -m "panicboat monorepo の reverse-proxy/httproute.yaml が parentRef
cilium-gateway namespace default を指定する設計のため、共有 Gateway
resource を kubernetes/components/cilium/production/kustomization/ に追加。

P3 decision rationale:
- 個人運用 + 1 application 構成で per-service Gateway は YAGNI
- monorepo 既存設計尊重 (= application 開発体験一貫)
- 将来 multi-application 化時に per-service Gateway 設計を再評価

既存 kustomization.yaml ヘッダコメント (= 'per-service 個別作成、共有
Gateway は production では作らない') を update (= '共有 Gateway 採用、
将来 multi-application 化時に再評価')。"
```

---

## Task 2: Hydrate cilium component → manifests/production/cilium 更新

**Files:**
- Modify: `kubernetes/manifests/production/cilium/manifest.yaml` (= hydrate 自動生成)

- [ ] **Step 1: cilium component hydrate**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
make hydrate-component COMPONENT=cilium ENV=production
```

Expected:
- `manifests/production/cilium/manifest.yaml` 更新
- exit code 0

- [ ] **Step 2: hydrate diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git diff kubernetes/manifests/production/cilium/manifest.yaml | head -50
```

Expected: Gateway resource (= cilium-gateway namespace default) が追加された diff のみ (= GatewayClass cilium は既存維持)。CA cert / TLS key 等の noise なし (= Makefile の `git diff -I '^[[:space:]]*(ca\.crt|...)'` 処理で safe)。

- [ ] **Step 3: commit hydrated manifest**

```bash
git add kubernetes/manifests/production/cilium/manifest.yaml
git commit -s -m "chore(eks): hydrate cilium production manifest (= Gateway 追加)"
```

---

## Task 3: OTel Operator production component 作成

**Files:**
- Create: `kubernetes/components/opentelemetry/production/helmfile.yaml`
- Create: `kubernetes/components/opentelemetry/production/values.yaml.gotmpl`

**Context:** OTel Operator chart を production 用に新規 component として deploy。local 環境 (= `kubernetes/components/opentelemetry/local/`) を踏襲、production differences は cert-manager integration (= admission webhook TLS は selfsigned-cluster-issuer)。

- [ ] **Step 1: chart latest stable 確認 + binary verify (= 5-1 L1)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>&1 | tail -1
helm repo update open-telemetry 2>&1 | tail -3
helm search repo open-telemetry/opentelemetry-operator --versions 2>&1 | head -5
```

Expected:
- chart latest stable version 確認 (= local の 0.112.0 と差分があるか確認、Phase 6-1 では latest stable を採用)
- helm chart fetch で binary verify (= chart sha256 検証)

- [ ] **Step 2: chart values reference 取得 (= certManager integration API 確認)**

```bash
helm show values open-telemetry/opentelemetry-operator --version <latest> 2>&1 | grep -A 30 'admissionWebhooks:'
```

Expected: `admissionWebhooks.certManager.{enabled, issuerRef.{name, kind}}` の structure 確認。chart が default で Issuer auto-create するか、existing ClusterIssuer 参照を expect するかを確定。

- [ ] **Step 3: helmfile.yaml 作成**

```yaml
# =============================================================================
# OpenTelemetry Operator Helmfile for production
# =============================================================================
# OTel Operator は OpenTelemetry SDK auto-injection (= Instrumentation CR) と
# OTel Collector CRD (= OpenTelemetryCollector) の管理を提供する。
# Phase 6-1 で deploy、Instrumentation CR は 6-2 で application namespace に追加。
#
# admission webhook TLS は cert-manager (= selfsigned-cluster-issuer) を利用。
# webhook は K8s API server ↔ webhook の server-only TLS のため、SelfSigned で OK
# (= 5-1 L3 lesson の mTLS 不可は server-only TLS には影響しない)。
# =============================================================================
environments:
  production:
---
repositories:
  - name: opentelemetry
    url: https://open-telemetry.github.io/opentelemetry-helm-charts

releases:
  - name: opentelemetry-operator
    namespace: opentelemetry-operator-system
    chart: opentelemetry/opentelemetry-operator
    version: "<latest stable from Step 1>"  # Step 1 で確認した最新 stable で固定
    values:
      - values.yaml.gotmpl
```

Path: `kubernetes/components/opentelemetry/production/helmfile.yaml`

- [ ] **Step 4: values.yaml.gotmpl 作成**

```yaml
# =============================================================================
# OpenTelemetry Operator Configuration for production
# =============================================================================
# Phase 6-1 で deploy。Instrumentation CR は 6-2 で application namespace に追加。
# =============================================================================

# =============================================================================
# Admission Webhooks (= cert-manager integration)
# =============================================================================
# webhook は K8s API server ↔ Operator webhook の server-only TLS、SelfSigned
# で十分 (= 5-1 L3 lesson の mTLS 不可は server-only TLS には影響しない)。
admissionWebhooks:
  certManager:
    enabled: true
    issuerRef:
      name: selfsigned-cluster-issuer
      kind: ClusterIssuer
  autoGenerateCert:
    enabled: false  # cert-manager 利用のため無効

# =============================================================================
# Manager Configuration
# =============================================================================
manager:
  # Default collector image (= Instrumentation CR で個別指定可能)
  collectorImage:
    repository: otel/opentelemetry-collector-contrib
    tag: 0.151.0  # 6-2 application 投入時に最新 stable に update 検討

  # Prometheus integration (= 既 deploy 済 prometheus-operator 利用)
  serviceMonitor:
    enabled: true
  prometheusRule:
    enabled: false

  # Resource limits (= local 設定踏襲、6-2 application 投入で application 数に応じて調整)
  resources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi
```

Path: `kubernetes/components/opentelemetry/production/values.yaml.gotmpl`

注: `issuerRef` の structure は Step 2 chart values 確認結果に応じて修正 (= chart が `admissionWebhooks.certManager.issuerRef` の代わりに別 keys を expect する場合)。

- [ ] **Step 5: helmfile template で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
helmfile -f components/opentelemetry/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | head -80
```

Expected:
- Deployment / Service / ServiceAccount / ClusterRole / ValidatingWebhookConfiguration / MutatingWebhookConfiguration 等 resource 出力
- syntax error なし
- `Certificate` resource (= cert-manager integration の crd 利用) と `Issuer` reference selfsigned-cluster-issuer 確認

- [ ] **Step 6: commit production component**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git add kubernetes/components/opentelemetry/production/
git commit -s -m "feat(eks): Phase 6-1 — OTel Operator production component" -m "OTel Operator chart を production 用に新規 component として deploy。
local 環境 (= components/opentelemetry/local/) を踏襲、production
differences は cert-manager integration (= admission webhook TLS は
selfsigned-cluster-issuer 利用)。

Phase 6-2 で application 投入時に Instrumentation CR を default
namespace に追加、Hanami / Next.js application code に OTel SDK init
を入れる前提。

5-1 L1 (= chart binary verify systematic step): chart latest stable で
binary verify 実施済。"
```

---

## Task 4: Hydrate opentelemetry component → manifests/production/opentelemetry 新規作成

**Files:**
- Create: `kubernetes/manifests/production/opentelemetry/{kustomization.yaml, manifest.yaml}` (= hydrate 自動生成)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (= hydrate-index で auto-insert)
- Modify: `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= hydrate-index、namespace yaml がある場合のみ追加)

- [ ] **Step 1: namespace yaml 必要性確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
helmfile -f components/opentelemetry/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | grep -B 2 -A 5 "kind: Namespace"
```

Expected:
- chart が `opentelemetry-operator-system` namespace を auto-create する場合、yaml output に Namespace resource あり
- auto-create しない場合は `kubernetes/components/opentelemetry/production/namespace.yaml` を新規作成 (= hydrate-index が拾う)

ない場合の追加 file:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: opentelemetry-operator-system
```
Path: `kubernetes/components/opentelemetry/production/namespace.yaml`

- [ ] **Step 2: opentelemetry component hydrate**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
make hydrate-component COMPONENT=opentelemetry ENV=production
```

Expected: `manifests/production/opentelemetry/{kustomization.yaml, manifest.yaml}` 新規作成。

- [ ] **Step 3: hydrate-index で manifests/production/kustomization.yaml + 00-namespaces/namespaces.yaml update**

```bash
make hydrate-index ENV=production
```

Expected:
- `manifests/production/kustomization.yaml` の resources に `./opentelemetry` 追加
- `manifests/production/00-namespaces/namespaces.yaml` に opentelemetry-operator-system namespace 追加 (= namespace.yaml 提供時のみ)

- [ ] **Step 4: hydrate diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git status kubernetes/manifests/production/
git diff kubernetes/manifests/production/kustomization.yaml
```

Expected: 新規 ./opentelemetry 行追加 + manifests/production/opentelemetry/ 新規 directory + 既存 component の manifest.yaml 変更なし

- [ ] **Step 5: commit hydrated manifests**

```bash
git add kubernetes/manifests/production/
git commit -s -m "chore(eks): hydrate opentelemetry production manifest (= 新規)"
```

---

## Task 5: Flux GitRepository monorepo + cluster Kustomization (suspend) 作成

**Files:**
- Create: `kubernetes/clusters/production/repositories/kustomization.yaml`
- Create: `kubernetes/clusters/production/repositories/monorepo.yaml`
- Modify: `kubernetes/clusters/production/kustomization.yaml`

**Context:** monorepo を platform Flux 管理対象に追加。Kustomization は `spec.suspend: true` で suspend 状態 deploy (= 6-2 で resume して各 service Flux Kustomization を有効化)。

- [ ] **Step 1: monorepo.yaml 作成**

```yaml
# =============================================================================
# Flux GitRepository + Kustomization for panicboat/monorepo
# =============================================================================
# Phase 6-1 (= monorepo migration foundation) で追加。monorepo は
# clusters/develop/ 配下に各 service ごとの Flux Kustomization を内蔵
# (= monolith / frontend / reverse-proxy)、cascading で deploy される設計。
#
# 6-1 では Kustomization を suspend 状態で deploy、6-2 で resume して
# 各 service deploy 開始。並行 monorepo PR で services/nginx を削除済。
# =============================================================================
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
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monorepo-cluster
  namespace: flux-system
spec:
  interval: 5m0s
  path: "./clusters/develop"
  prune: true
  sourceRef:
    kind: GitRepository
    name: monorepo
  suspend: true  # 6-2 で resume して各 service Kustomization 有効化
```

Path: `kubernetes/clusters/production/repositories/monorepo.yaml`

- [ ] **Step 2: repositories/kustomization.yaml 作成**

```yaml
# =============================================================================
# External Repositories Kustomization for production
# =============================================================================
# Phase 6-1 で新規作成。platform 外 repository (= panicboat monorepo) の
# Flux GitRepository + Kustomization を集約管理。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - monorepo.yaml
```

Path: `kubernetes/clusters/production/repositories/kustomization.yaml`

- [ ] **Step 3: cluster top kustomization update**

`kubernetes/clusters/production/kustomization.yaml` を以下に修正:

```yaml
# =============================================================================
# Production Cluster Kustomization
# =============================================================================
# このファイルは EKS production cluster (eks-production) で Flux が
# 同期する root kustomization。
#
# 含むリソース:
#   - manifests/production: ハイドレーション済 Kubernetes manifests
#   - repositories/: 外部 repository (= panicboat monorepo) の Flux
#     GitRepository + Kustomization (= Phase 6-1 で追加)
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../manifests/production
  - ./repositories
```

Path: `kubernetes/clusters/production/kustomization.yaml`

- [ ] **Step 4: kustomize build で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9/kubernetes
kustomize build clusters/production 2>&1 | grep -E "kind: GitRepository|kind: Kustomization|name: monorepo" | head -20
```

Expected:
- GitRepository monorepo 表示
- Kustomization monorepo-cluster 表示
- 既存 GitRepository flux-system / Kustomization flux-system も表示 (= 既存維持)

- [ ] **Step 5: commit Flux config**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git add kubernetes/clusters/production/repositories/
git add kubernetes/clusters/production/kustomization.yaml
git commit -s -m "feat(eks): Phase 6-1 — Flux GitRepository monorepo (= suspend 状態)" -m "panicboat/monorepo を platform Flux 管理対象に追加。Kustomization は
spec.suspend: true で suspend 状態 deploy、6-2 で resume して各 service
(= monolith / frontend / reverse-proxy) deploy 開始。

monorepo の clusters/develop/ 配下に各 service ごとの Flux Kustomization
を内蔵 (= cascading deploy 設計)。並行 monorepo PR で services/nginx を
削除予定。

新規 directory: kubernetes/clusters/production/repositories/
新規 files: monorepo.yaml + kustomization.yaml
修正: kubernetes/clusters/production/kustomization.yaml の resources に
./repositories 追加 + ヘッダコメント update。"
```

---

## Task 6: monorepo nginx 削除 PR (= 並行 PR、別 worktree)

**Files (= monorepo 側):**
- Delete: `services/nginx/` 全体
- Delete: `clusters/develop/services/nginx/` 全体
- Modify: `clusters/develop/services/kustomization.yaml`

**Context:** Phase 6 で nginx service は不要 (= 動作確認用、Q4 削除 decision)。monorepo を clean 化 + auto-bump (= 30m interval) コスト削減。platform PR と並行 merge (= "(b) 並行" decision)。

- [ ] **Step 1: monorepo worktree に移動 + 現状確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-remove-nginx-service
git status
ls services/
cat clusters/develop/services/kustomization.yaml
```

Expected:
- branch chore/remove-nginx-service active
- services/ に 4 ディレクトリ (= frontend / monolith / nginx / reverse-proxy)
- clusters/develop/services/kustomization.yaml に 4 services list (= monolith / nginx / frontend / reverse-proxy)

- [ ] **Step 2: nginx 関連 directory + entry 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-remove-nginx-service
rm -rf services/nginx
rm -rf clusters/develop/services/nginx
```

- [ ] **Step 3: clusters/develop/services/kustomization.yaml から nginx 行削除**

修正後 (= 期待値):
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - monolith
  - frontend
  - reverse-proxy
```

Path: `clusters/develop/services/kustomization.yaml`

- [ ] **Step 4: kustomize build で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-remove-nginx-service
kustomize build clusters/develop 2>&1 | grep "kind:" | sort -u
```

Expected:
- `kind: Kustomization` 3 件 (= monolith / frontend / reverse-proxy 用 Flux Kustomization)
- nginx の Kustomization / ImageRepository / ImagePolicy / ImageUpdateAutomation 不在

- [ ] **Step 5: commit + push + draft PR 作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-remove-nginx-service
git add -A
git status
git commit -s -m "chore: remove nginx service (= panicboat platform Phase 6-1 同期)" -m "panicboat platform Phase 6-1 (= monorepo migration foundation) と並行
で実施。nginx は動作確認用 service、Phase 6 application migration scope
から除外する decision (= Q4 + (b) 並行 merge)。

削除内容:
- services/nginx/ 全体
- clusters/develop/services/nginx/ 全体
- clusters/develop/services/kustomization.yaml から nginx 行削除

副次効果: nginx auto-bump (= ImageRepository + ImagePolicy +
ImageUpdateAutomation の 30m interval) を停止、monorepo CI の resource
削減。"
git push -u origin HEAD
gh pr create --draft --title "chore: remove nginx service (= panicboat platform Phase 6-1 同期)" --body "$(cat <<'EOF'
## Summary

panicboat platform Phase 6-1 (= monorepo migration foundation) と並行で実施。nginx は動作確認用 service、Phase 6 application migration scope から除外する decision に基づく削除。

## Context

panicboat/platform で Phase 6-1 spec / plan が決定 (= [platform PR (= TBD、本 PR と同期 merge)](https://github.com/panicboat/platform/pulls))。本 PR は platform 側 spec の Component C (= "並行 monorepo PR で services/nginx 削除") に対応。

詳細: [platform Phase 6-1 spec](https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md)

## Changes

- **削除**: \`services/nginx/\` 全体 (= deployment / service / kustomization 等の K8s manifests + Dockerfile 等)
- **削除**: \`clusters/develop/services/nginx/\` 全体 (= Flux Kustomization + ImageRepository + ImagePolicy + ImageUpdateAutomation)
- **修正**: \`clusters/develop/services/kustomization.yaml\` から nginx 行削除

## Side effects

- nginx auto-bump (= 30m interval ImageUpdateAutomation) 停止
- monorepo CI の resource 削減 (= nginx に関する build / test step が trigger されない)

## Merge synchronization

platform PR と **同日 merge** (= order constraint なし、両方 main に取り込みで Phase 6-1 完了)。
EOF
)"
```

Expected:
- commit + push success
- PR url 取得 (= 後で platform PR description に記載)

- [ ] **Step 6: monorepo PR url 記録**

monorepo PR url を **platform PR description に記載** するため記録。例: `https://github.com/panicboat/monorepo/pull/<n>`。

---

## Task 7: PR description 起草 + push platform changes

**Files:** (platform PR description の preparation)

**Context:** platform 側の全 commit が並んだ状態で、PR description を起草し、push する。並行 monorepo PR との同期 merge を明記。

- [ ] **Step 1: platform commit 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/optimistic-kowalevski-43f8e9
git log --oneline origin/main..HEAD
```

Expected: spec 2 commit + Task 1-5 の 5 commit = **計 7 commit**

```
<hash> chore(eks): hydrate opentelemetry production manifest (= 新規)
<hash> feat(eks): Phase 6-1 — Flux GitRepository monorepo (= suspend 状態)
<hash> chore(eks): hydrate cilium production manifest (= Gateway 追加)
<hash> feat(eks): Phase 6-1 — OTel Operator production component
<hash> feat(eks): Phase 6-1 — Cilium 共有 Gateway (= P3 decision)
5d33c87 docs(eks): Phase 6-1 spec update — shared Gateway (P3) decision
772a28b docs(eks): Phase 6-1 — monorepo migration foundation spec
```

(注: commit 順序は実 task 実行順、deploy / hydrate を交互に行う pattern)

- [ ] **Step 2: push platform branch**

```bash
git push origin HEAD
```

Expected: push success (= 既 upstream tracking 済、Task 0 完了時点で初回 push 済)

- [ ] **Step 3: platform draft PR 作成**

```bash
gh pr create --draft --title "feat(eks): Phase 6-1 — monorepo migration foundation" --body "$(cat <<'EOF'
## Summary

EKS production cluster (\`eks-production\`) に monorepo migration prerequisite として共有 Cilium Gateway resource + Flux GitRepository monorepo + OTel Operator chart を deploy。Phase 6-2 で application services (= monolith / frontend / reverse-proxy) を deploy 可能な platform foundation を整える。

## Spec

[docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md](https://github.com/panicboat/platform/blob/claude/optimistic-kowalevski-43f8e9/docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md)

## Plan

[docs/superpowers/plans/2026-05-10-eks-production-monorepo-migration-foundation.md](https://github.com/panicboat/platform/blob/claude/optimistic-kowalevski-43f8e9/docs/superpowers/plans/2026-05-10-eks-production-monorepo-migration-foundation.md)

## Changes (= 5 components A-E のうち deploy 必要な 3 件)

### Component A: Cilium Gateway API enable (= 既達成、validation のみ)

- platform Cilium 1.18.6 + \`gatewayAPI.enabled: true\` 既設定済
- GatewayClass cilium 既 deploy 済
- 6-1 で chart 修正なし、validation のみ実施

### Component B: Cilium 共有 Gateway resource (= P3 decision)

- panicboat 個人運用 + 1 application 構成で per-service Gateway は YAGNI、共有 Gateway を採用
- monorepo の \`reverse-proxy/httproute.yaml\` が parentRef \`cilium-gateway\` namespace \`default\` を指定する既存設計を尊重
- \`kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml\` 新規 + 既存 \`kustomization.yaml\` の resources 追加 + ヘッダコメント update
- **既存 review 前提との差分**: 既コメント (= "per-service 個別作成、共有 Gateway は production では作らない") を update (= "共有 Gateway 採用、将来 multi-application 化時に再評価")

### Component C: Flux GitRepository monorepo + cluster Kustomization

- panicboat/monorepo を platform Flux 管理対象に追加
- Kustomization は \`spec.suspend: true\` で suspend 状態 deploy、6-2 で resume
- \`kubernetes/clusters/production/repositories/\` 新規 directory + cluster top kustomization に \`./repositories\` 追加

### Component D: OTel Operator chart (= production 用 component)

- \`kubernetes/components/opentelemetry/production/\` 新規 directory (= local 環境を踏襲、production differences は cert-manager integration)
- admission webhook TLS は \`selfsigned-cluster-issuer\` (= server-only TLS のため SelfSigned で十分、5-1 L3 lesson の mTLS 不可は影響しない)
- 6-2 で application namespace に Instrumentation CR 追加予定

### Component E: Post-flight regression check (= deploy 後実施)

- Phase 1-5 既 deploy 済 component の health 確認
- 既 deploy 済 nginx (= Phase 5-2) の継続動作確認
- 6-1 追加 component health 確認
- latent issue 検出時 fix forward PR (= 5-1 L2 / 5-2 L1 pattern 4 連続 validate)

## Phase 5 lessons applied

- 5-1 L1 (= chart binary verify): OTel Operator chart latest stable で binary verify 実施
- 5-1 L2 / 5-2 L1 (= post-flight regression check): Component E で 4 連続 validate
- 5-2 L4 (= kustomization-only pattern): 共有 Gateway resource を既 cilium kustomization に追加
- 5-1 L3 (= cert-manager SelfSigned mTLS 不可): OTel Operator admission webhook が server-only TLS であることを確認、SelfSigned で十分

## 引き継ぎ事項解消

- **#13** (= Cilium Gateway API east-west 利用): 解消 (= Phase 1-5 で既 enable + 6-1 で共有 Gateway resource deploy + platform 設計コメント update)

## Parallel monorepo PR (= 並行 merge)

- [chore: remove nginx service (= panicboat platform Phase 6-1 同期)](https://github.com/panicboat/monorepo/pull/<n>)
- platform PR と **同日 merge** (= order constraint なし、両方 main に取り込みで Phase 6-1 完了)

## Out of scope

以下は 6-2 / 6-3 で対応:

- application services (= monolith / frontend / reverse-proxy) の deploy → 6-2
- AWS RDS provision (= terragrunt) → 6-2
- application code 側 OTel SDK init (= L1) → 6-2
- Instrumentation CR application namespace 配置 → 6-2
- HTTPRoute / Service (= application 側 routing) → 6-2 で monorepo 既存 manifests 利用
- DNS / ACM の application domain 公開 → 6-3
- 3-layer observability validation (= Beyla + Hubble + OTel 同 trace_id 結合) → 6-3

## Validation checklist (= deploy 後実施)

- [ ] GatewayClass \`cilium\` Accepted (= 既達成確認)
- [ ] Gateway \`cilium-gateway\` (= namespace default) Accepted + Programmed
- [ ] platform 設計コメント update 完了
- [ ] GitRepository \`monorepo\` Ready + Fetched
- [ ] Kustomization \`monorepo-cluster\` Suspended
- [ ] monorepo PR (= nginx 削除) merge 完了
- [ ] OTel Operator Pod Running + CRD installed + admission webhook cert ready
- [ ] Phase 1-5 既存 component regression なし
- [ ] 6-1 追加 component health 全 PASS
- [ ] latent issue 検出時 fix forward PR で resolve
- [ ] post-execution learnings doc 作成
EOF
)"
```

Expected:
- platform draft PR 作成成功
- PR url 取得

注: monorepo PR url の `<n>` placeholder は Task 6 Step 6 で記録した実 number に置換。

---

## Task 8: Post-execution observation phase (= cluster 上の actual deploy 動作 + fix forward)

**Files:** (status check + 必要時 fix forward PR)

**Context:** platform PR と monorepo PR を merge 後、cluster 上の actual deploy 動作を観察。Component E (= post-flight regression check) を実施し、latent issue 検出時は fix forward PR で resolve。

- [ ] **Step 1: 両 PR merge 完了確認**

```bash
gh pr view <platform-pr> --json state,mergedAt
gh pr view <monorepo-pr> --json state,mergedAt --repo panicboat/monorepo
```

Expected: 両方 `state: MERGED, mergedAt: <timestamp>`

- [ ] **Step 2: Flux reconcile + 6-1 追加 component health 確認 (= post-flight Section 3)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux reconcile source git flux-system
flux reconcile kustomization flux-system

echo "--- Cilium 共有 Gateway ---"
kubectl get gateway -n default cilium-gateway -o jsonpath="Accepted={.status.conditions[?(@.type==\"Accepted\")].status} Programmed={.status.conditions[?(@.type==\"Programmed\")].status}{\"\\n\"}"

echo "--- GitRepository monorepo + Kustomization (suspend) ---"
kubectl get gitrepository -n flux-system monorepo -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
kubectl get kustomization -n flux-system monorepo-cluster -o jsonpath="Suspended={.spec.suspend}{\"\\n\"}"

echo "--- OTel Operator ---"
kubectl get pods -n opentelemetry-operator-system --no-headers
kubectl get crd | grep opentelemetry.io | head -3
kubectl get certificate -n opentelemetry-operator-system -o jsonpath="{range .items[*]}{.metadata.name} Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}"'
```

Expected:
- Gateway cilium-gateway Accepted=True Programmed=True
- GitRepository monorepo Ready=True
- Kustomization monorepo-cluster Suspended=true
- OTel Operator Pod Running
- OTel CRD (= instrumentations + opentelemetrycollectors 等) installed
- Certificate Ready=True

- [ ] **Step 3: Phase 1-5 既存 component regression 確認 (= post-flight Section 1)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Cilium L3/L4 + GatewayClass ---"
kubectl get ds -n kube-system cilium --no-headers
kubectl get gatewayclass cilium -o jsonpath="Accepted={.status.conditions[?(@.type==\"Accepted\")].status}{\"\\n\"}"

echo "--- Hubble (= metrics + UI) ---"
kubectl get pods -n kube-system -l k8s-app=hubble-relay --no-headers | head -1
curl -s -o /dev/null -w "hubble.panicboat.net=%{http_code}\\n" https://hubble.panicboat.net/

echo "--- Monitoring stack ---"
kubectl get pods -n monitoring --no-headers | grep -E "prometheus|mimir|loki|tempo|grafana" | wc -l
echo "--- Grafana 4 UI OAuth gate ---"
for host in grafana hubble prometheus alertmanager; do
  curl -s -o /dev/null -w "$host.panicboat.net=%{http_code} (302 expected = OAuth redirect)\\n" -L --max-redirs 0 https://$host.panicboat.net/
done

echo "--- ESO + Reloader + cert-manager ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
kubectl get pods -n reloader --no-headers | head -1
kubectl get pods -n cert-manager --no-headers | head -1

echo "--- Mimir distributor reject rate ---"
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -- curl -s "http://prometheus.monitoring.svc:9090/api/v1/query?query=rate(cortex_distributor_samples_in_total{}[5m])-rate(cortex_distributor_received_samples_total{}[5m])" 2>/dev/null | head -100 | grep -oE "value.{0,30}" | head -3'
```

Expected:
- Cilium DaemonSet 4/4 + GatewayClass Accepted=True
- Hubble Pod Running + hubble.panicboat.net OAuth redirect
- Monitoring stack 全 Pod Running
- 4 UI 全部 302 (= OAuth redirect)
- ClusterSecretStore + Reloader + cert-manager all Ready
- Mimir distributor reject rate 0 (= 6-1 で application 投入なし、reject 急増は想定外)

- [ ] **Step 4: 既 deploy 済 application 継続動作 (= post-flight Section 2)**

```bash
echo "--- demo nginx (Phase 5-2) ---"
curl -s -o /dev/null -w "nginx.panicboat.net=%{http_code}\\n" https://nginx.panicboat.net/
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl exec -n default deploy/nginx -- printenv DEMO_MESSAGE 2>&1 | head -1'
```

Expected:
- nginx.panicboat.net=200
- DEMO_MESSAGE env value 維持 (= ESO 経由 secret 注入継続)

- [ ] **Step 5: latent issue 検出 (= post-flight Section 4、5-1 L2 / 5-2 L1 pattern 4 連続 validate)**

検出対象:
- 共有 Gateway resource deploy で Cilium agent 動作変化 (= L3/L4 / WireGuard / Hubble 既機能 regression)
- monorepo Flux Kustomization suspend 状態の Reconcile loop 設定不整合
- OTel Operator chart deploy で発覚する admission webhook 設定不整合 (= cert-manager integration)
- Phase 1-5 latent issue が 6-1 deploy で表面化

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Pod restart 数 baseline 比較 ---"
kubectl get pods -A -o jsonpath="{range .items[*]}{.metadata.namespace}/{.metadata.name} restarts={.status.containerStatuses[0].restartCount}{\"\\n\"}{end}" | grep -v "restarts=0$" | head -20

echo "--- Cilium agent error log (= recent 20 lines) ---"
kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -iE "error|warn" | head -5

echo "--- OTel Operator log (= recent 20 lines) ---"
kubectl logs -n opentelemetry-operator-system -l app.kubernetes.io/name=opentelemetry-operator --tail=20 2>&1 | grep -iE "error|warn" | head -5

echo "--- Flux Kustomization reconcile errors ---"
flux get kustomizations -A 2>&1 | grep -E "False|reconciliation failed" | head -5'
```

Expected:
- restart 数増加 0 (= 既 Pod の restart count 維持)
- Cilium / OTel Operator log error 0
- Flux Kustomization reconcile failure 0

検出時は fix forward PR で resolve (= 5-1 L2 / 5-2 L1 pattern)。

- [ ] **Step 6: ready PR 移行 + merge 待ち**

両方 OK の場合:

```bash
gh pr ready <platform-pr-number>
```

Expected: PR が draft → ready for review、merge 可能状態

注: monorepo PR も同様 ready 化。両方 ready で同日 merge。

- [ ] **Step 7: 6-1 完了 + post-execution learnings doc 作成 (= 別 PR)**

merge 完了後、post-execution learnings doc を作成 (= Phase 4-5 pattern):

```
docs/superpowers/plans/2026-05-10-eks-production-monorepo-migration-foundation.md
```

の末尾に "## Post-execution learnings" section を追加、別 PR (= "docs(eks): Phase 6-1 — post-execution learnings") で merge。

learnings 候補:
- Cilium 共有 Gateway resource 追加の既機能 regression 観察結果
- platform 設計コメント update pattern (= 既存設計の意図を application phase で update)
- OTel Operator admission webhook の server-only TLS で SelfSigned で十分の confirmation
- 5-1 L2 / 5-2 L1 pattern 4 連続 validate 結果 (= latent issue 検出 / 検出 0 のいずれか)

---

## 完了条件 (= spec Section 7 Validation checklist 再掲)

- [ ] GatewayClass `cilium` Accepted (= 既達成確認のみ)
- [ ] Gateway `cilium-gateway` (= namespace default) Accepted + Programmed
- [ ] platform `kubernetes/components/cilium/production/kustomization/kustomization.yaml` のヘッダコメント update 完了
- [ ] GitRepository `monorepo` Ready + Fetched
- [ ] Kustomization `monorepo-cluster` Suspended
- [ ] monorepo PR (= nginx 削除) merge 完了 + GitRepository が最新 commit を fetch
- [ ] OTel Operator Pod Running + CRD installed + admission webhook cert ready
- [ ] Phase 1-5 既存 component regression なし
- [ ] 6-1 追加 component health 全 PASS
- [ ] latent issue 検出時 fix forward PR で resolve
- [ ] post-execution learnings doc 作成 (= 別 PR、本 plan に section 追加)
