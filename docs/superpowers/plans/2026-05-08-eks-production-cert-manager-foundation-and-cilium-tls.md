# EKS Production: cert-manager Foundation + Cilium TLS Migration (Phase 4-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) に **cert-manager (= jetstack/cert-manager v1.18.x)** と selfsigned `ClusterIssuer` を deploy し、既存 Cilium Hubble TLS を `cronJob` mode から公式 production-recommended の `certmanager` mode に migrate する。本 sub-project 完了時に panicboat cluster は **cert-manager-based webhook cert 管理基盤** を持ち、Phase 4-2 (= ESO) の admission webhook cert を自動発行できる状態になる。

**Architecture:** `jetstack/cert-manager` chart で controller / cainjector / webhook を `cert-manager` namespace に deploy。webhook を 3 replicas + `system-cluster-critical` priority class で HA 構成。selfsigned `ClusterIssuer` (= internal CA) を 1 つ作成、cluster 内 webhook + Hubble TLS の cert 発行に使用。Cilium Hubble TLS を `tls.auto.method: certmanager` に switch、上記 ClusterIssuer を参照。他 admission webhooks (= Karpenter / ALB Controller / KEDA / prometheus-operator) は既存 builtin self-signed のまま (= Phase 6+ で incremental migrate path 確保)。

**Tech Stack:** Helm + helmfile / `jetstack/cert-manager` v1.18.x / selfsigned ClusterIssuer / Cilium 1.18.6 (= 既 deploy、values 修正のみ) / kube-prometheus-stack ServiceMonitor

**Spec:** `docs/superpowers/specs/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (cert-manager component):**
```
kubernetes/components/cert-manager/
├── namespace.yaml                              # cert-manager namespace 定義 (= local + production 共通)
└── production/
    ├── helmfile.yaml                           # jetstack/cert-manager chart deploy 定義
    ├── values.yaml.gotmpl                      # HA + priority class + ServiceMonitor + CRD install
    └── kustomization/
        ├── kustomization.yaml                  # ClusterIssuer を kustomization で別途 deploy
        └── cluster-issuer.yaml                 # selfsigned ClusterIssuer manifest
```

**Kubernetes 変更:**
```
kubernetes/components/cilium/production/values.yaml.gotmpl   # Hubble TLS を cronJob → certmanager に switch
```

**Kubernetes 自動生成 (production hydrate output):**
```
kubernetes/manifests/production/cert-manager/{kustomization.yaml, manifest.yaml}   # 新規 (= chart render + ClusterIssuer)
kubernetes/manifests/production/cilium/manifest.yaml                                # 修正 (= Certificate resource 追加、CronJob 削除)
kubernetes/manifests/production/00-namespaces/namespaces.yaml                       # 修正 (= cert-manager namespace block 追加)
kubernetes/manifests/production/kustomization.yaml                                  # 修正 (= ./cert-manager resource auto-insert)
```

**変更しないファイル**: aws/* / kubernetes/components/{tempo,loki,mimir,prometheus-operator,fluent-bit,opentelemetry-collector,karpenter,keda,external-dns,aws-load-balancer-controller,gateway-api}/* / kubernetes/components/cilium/local/* / kubernetes/components/cert-manager/local/* (= 本 sub-project では作成しない)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** 4-1 開始前に cluster の現在状態と branch 状態を確認。Sub-project 4b 完了状態 (= Cilium TLS は cronJob method、cert-manager 未 deploy) を baseline として確認、4-1 で予定する変更が現状と整合することを確認。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-cert-manager-foundation-and-cilium-tls
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead
```
d68c729 docs(eks): Phase 4-1 (cert-manager + Cilium TLS migration) design
```

- [ ] **Step 2: 既存 Cilium Hubble TLS が cronJob method であることを確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Cilium values: tls.auto.method ---"
kubectl get configmap -n kube-system cilium-config -o jsonpath="{.data.hubble-tls-auto-method}" 2>&1 || echo "(Cilium config から hubble-tls-auto-method 確認、`hubble-generate-certs` CronJob で証明書 rotate 済)"
echo ""
echo "--- 既存 hubble-generate-certs CronJob ---"
kubectl get cronjob -n kube-system hubble-generate-certs 2>&1 | head -3
echo ""
echo "--- 既存 Hubble TLS secrets ---"
kubectl get secret -n kube-system 2>&1 | grep -E "hubble.*ca|hubble.*server|hubble.*relay" | head -5'
```

Expected: `hubble-generate-certs` CronJob 存在、`hubble-ca-cert` / `hubble-server-certs` / `hubble-relay-client-certs` 等の secrets 存在 (= cronJob method の生成物)

- [ ] **Step 3: cert-manager 未 deploy 状態 (= namespace 不在、CRDs 不在) 確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- cert-manager namespace 不在確認 ---"
kubectl get namespace cert-manager 2>&1 | head -3
echo ""
echo "--- cert-manager CRDs 不在確認 ---"
kubectl get crd 2>&1 | grep cert-manager.io || echo "(no cert-manager CRDs = 想定通り)"'
```

Expected: 
- `Error from server (NotFound): namespaces "cert-manager" not found`
- "no cert-manager CRDs = 想定通り"

- [ ] **Step 4: Phase 3 monitoring stack の健康確認 (= regression baseline)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n monitoring | grep -v Completed | grep -v "1/1\|2/2\|3/3" | head -5'
```

Expected: 結果なし (= 全 monitoring pod が Ready 状態)

- [ ] **Step 5: Hubble Relay の現状動作確認 (= migration 前 baseline)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Hubble Relay pod ---"
kubectl get pods -n kube-system -l k8s-app=hubble-relay 2>&1 | head
echo ""
echo "--- Hubble Relay TLS 接続成功 (= migration 前の baseline) ---"
kubectl logs -n kube-system -l k8s-app=hubble-relay --tail=20 --since=10m 2>&1 | grep -iE "(error|tls|connect)" | tail -5'
```

Expected: hubble-relay pod が `Running 1/1`、過去 10 分以内に TLS error なし

- [ ] **Step 6: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1 | head -3'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:11aff95` (= 直近 main = Sub-project 4b PriorityClass fix PR #305 merge 済) もしくはそれ以降の commit

---

## Task 1: cert-manager component (`kubernetes/components/cert-manager/`)

**Files:**
- Create: `kubernetes/components/cert-manager/namespace.yaml`
- Create: `kubernetes/components/cert-manager/production/helmfile.yaml`
- Create: `kubernetes/components/cert-manager/production/values.yaml.gotmpl`
- Create: `kubernetes/components/cert-manager/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/cert-manager/production/kustomization/cluster-issuer.yaml`

**Context:** Phase 4-1 で deploy する cert-manager (= jetstack/cert-manager) の component 全体を新規作成。Sub-project 4a (= Tempo + OTel Collector) と同 pattern で `production/helmfile.yaml` + `production/values.yaml.gotmpl` を作成、加えて ClusterIssuer (= chart 範囲外) を `production/kustomization/cluster-issuer.yaml` で追加。

### Step 1: chart 最新 stable version を確認

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack
helm search repo jetstack/cert-manager --versions | head -5
```

Expected: 上位に `cert-manager` の latest stable version (= 例 `v1.18.0` or 最新 patch) が表示される

NOTE: spec では `v1.18.0` を仮定、実際の最新 stable patch (= 例 `v1.18.2` 等) を採用、step 3 helmfile.yaml に書き込む version は本 step で確認した値を使用。

### Step 2: ServiceMonitor key path を確認 (= Sub-project 3 L3 + 4b L1 適用)

```bash
helm show values jetstack/cert-manager --version <step1 で確認した version> | grep -A20 "^prometheus:" | head -30
```

Expected: `prometheus.servicemonitor.enabled` (or `prometheus.servicemonitor` 配下の labels / interval 等) の正確な YAML 構造が確認できる。確認結果に従って Step 4 values.yaml.gotmpl の `prometheus:` block の key 構造を決定。

NOTE: cert-manager chart v1.x 系では `prometheus.servicemonitor.enabled` (小文字 `servicemonitor`) が一般的だが、`prometheus.serviceMonitor` (キャメルケース) の場合もあり得る。Step 6 の `helm template` 出力で ServiceMonitor が render されることを最終 verify する。

### Step 3: namespace.yaml を作成

`kubernetes/components/cert-manager/namespace.yaml`:

```yaml
# =============================================================================
# cert-manager Namespace
# =============================================================================
# cert-manager controller / cainjector / webhook の専用 namespace。
# Phase 4-1 で deploy、Phase 4-2 (ESO) + Cilium Hubble TLS の cert 発行に使用。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    app.kubernetes.io/name: cert-manager
```

### Step 4: production/helmfile.yaml を作成

`kubernetes/components/cert-manager/production/helmfile.yaml`:

```yaml
# =============================================================================
# cert-manager Helmfile for production
# =============================================================================
# Phase 4-1 で deploy する cert-manager (= jetstack/cert-manager)。
# CRDs は chart 経由で install (= crds.enabled: true)、ClusterIssuer は
# kustomization で別途 deploy (= chart 範囲外)。
# =============================================================================
environments:
  production:
---
repositories:
  - name: jetstack
    url: https://charts.jetstack.io

releases:
  - name: cert-manager
    namespace: cert-manager
    chart: jetstack/cert-manager
    version: "<step 1 で確認した version、例 v1.18.0>"
    values:
      - values.yaml.gotmpl
```

### Step 5: production/values.yaml.gotmpl を作成

`kubernetes/components/cert-manager/production/values.yaml.gotmpl`:

```yaml
# cert-manager Configuration for production
# Phase 4 / 5 で必要となる admission webhook cert 自動発行基盤、selfsigned CA で
# ESO + Cilium Hubble の cert を発行する。

# =============================================================================
# CRDs (= chart 経由で install)
# =============================================================================
crds:
  enabled: true

# =============================================================================
# Global config (= 全 component に適用)
# =============================================================================
global:
  # Cluster-wide critical service、scheduling 安定性を確保 (= cert-manager 公式推奨)
  priorityClassName: system-cluster-critical
  # Leader election 用 namespace
  leaderElection:
    namespace: cert-manager

# =============================================================================
# Controller (= main reconciliation loop)
# =============================================================================
replicaCount: 1
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    memory: 128Mi

# =============================================================================
# Webhook (= 公式 production best practice = 3 replicas で HA)
# =============================================================================
# NOTE: cert-manager 公式 best practice docs 明記 — webhook 不可時は全 cert-manager
# CR 操作が fail するため HA 必須。
webhook:
  replicaCount: 3
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 64Mi

# =============================================================================
# CA Injector (= webhook caBundle 自動 inject)
# =============================================================================
cainjector:
  replicaCount: 1
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      memory: 256Mi

# =============================================================================
# ServiceMonitor (= Phase 3 pattern 踏襲、Sub-project 3 L3 適用)
# =============================================================================
# NOTE: cert-manager chart の ServiceMonitor key path は Step 2 で確認した値を使用。
# Mimir / Loki / Tempo / OTel Collector の各 chart 固有 key とは異なる patterns。
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

NOTE: Step 2 で確認した key path が `prometheus.serviceMonitor` (キャメルケース) の場合は `servicemonitor:` を `serviceMonitor:` に修正。

### Step 6: helmfile template で render verify

```bash
helmfile -f kubernetes/components/cert-manager/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -E "kind: ServiceMonitor|kind: Deployment|kind: CustomResourceDefinition" | head -20
```

Expected:
- 6 CRDs (`certificaterequests` / `certificates` / `challenges` / `clusterissuers` / `issuers` / `orders`) が render される
- 3 Deployments (`cert-manager` / `cert-manager-cainjector` / `cert-manager-webhook`) が render される
- ServiceMonitor 1 件 (`cert-manager` self-metrics) が render される

```bash
# Webhook 3 replicas 確認
helmfile -f kubernetes/components/cert-manager/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -B2 "replicas: 3" | head -5
```

Expected: `cert-manager-webhook` Deployment に `replicas: 3` が render される

```bash
# system-cluster-critical priority 確認
helmfile -f kubernetes/components/cert-manager/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -E "priorityClassName" | head -5
```

Expected: 3 Deployment 全てに `priorityClassName: system-cluster-critical` が render される

### Step 7: ClusterIssuer kustomization を作成

`kubernetes/components/cert-manager/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# cert-manager Kustomization for production
# =============================================================================
# ClusterIssuer (= chart 範囲外) を kustomization で別途 deploy。
# cert-manager CRDs install 後に Flux が ClusterIssuer を apply (= 失敗時 retry)。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cluster-issuer.yaml
```

`kubernetes/components/cert-manager/production/kustomization/cluster-issuer.yaml`:

```yaml
# =============================================================================
# Selfsigned ClusterIssuer
# =============================================================================
# cluster 内 webhook + Hubble TLS 用の internal CA (= self-signed)。
# Phase 4-2 ESO + Cilium Hubble TLS が参照。external trust 不要。
# =============================================================================
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-cluster-issuer
spec:
  selfSigned: {}
```

### Step 8: Diff 確認

```bash
git status
```

Expected: 5 files added (= namespace.yaml + helmfile.yaml + values.yaml.gotmpl + kustomization.yaml + cluster-issuer.yaml)

### Step 9: Commit

```bash
git add kubernetes/components/cert-manager/
git commit -s -m "feat(eks): cert-manager v1.18 + selfsigned ClusterIssuer (Phase 4-1)"
```

Expected: 5 files changed (= 全部新規作成)、commit subject ≤ 72 chars (= 67 chars)、`-s` (signoff) 付き、Co-Authored-By 不在

---

## Task 2: Cilium values の Hubble TLS migration (cronJob → certmanager)

**Files:**
- Modify: `kubernetes/components/cilium/production/values.yaml.gotmpl` (= 既存修正、`hubble.tls.auto` block の置換)

**Context:** Sub-project 4-1 Decision 6 適用 = Cilium 公式が production-recommended と明示する `tls.auto.method: certmanager` に switch。`certManagerIssuerRef` で Task 1 で deploy 予定の `selfsigned-cluster-issuer` を参照。Cilium chart は `Certificate` resource を生成して TLS cert を発行。

### Step 1: 現状の `hubble.tls.auto` block を確認

```bash
grep -B1 -A6 "tls:" kubernetes/components/cilium/production/values.yaml.gotmpl | head -15
```

Expected:
```yaml
  tls:
    auto:
      method: cronJob
```

### Step 2: values.yaml.gotmpl を修正

`kubernetes/components/cilium/production/values.yaml.gotmpl` の `hubble.tls.auto` block を以下に置換:

Before:
```yaml
hubble:
  enabled: true
  # TLS certs を Helm 自動生成（chart values に焼き込み）ではなく cluster 内
  # CronJob で生成・rotate する。public Git repo に Hubble の秘密鍵を出さない。
  tls:
    auto:
      method: cronJob
```

After:
```yaml
hubble:
  enabled: true
  # TLS certs は cert-manager で管理 (= Cilium 公式 production-recommended path)。
  # selfsigned-cluster-issuer (= Phase 4-1 Task 1 で deploy 済) を参照、
  # cert-manager が Certificate resource を生成して TLS cert を発行・自動 rotate する。
  tls:
    auto:
      method: certmanager
      certManagerIssuerRef:
        name: selfsigned-cluster-issuer
        kind: ClusterIssuer
        group: cert-manager.io
```

### Step 3: helmfile template で render verify

```bash
helmfile -f kubernetes/components/cilium/production/helmfile.yaml -e production template --include-crds --skip-tests --set prometheus.serviceMonitor.trustCRDsExist=true,operator.prometheus.serviceMonitor.trustCRDsExist=true,hubble.metrics.serviceMonitor.trustCRDsExist=true 2>&1 | \
  grep -E "kind: Certificate|kind: CronJob|hubble-server-certs|hubble-relay" | head -10
```

Expected:
- `kind: Certificate` resource が複数 render される (= `hubble-server-certs` / `hubble-relay-client-certs` 等)
- `kind: CronJob` の `hubble-generate-certs` block が **render されない** (= cronJob method の cleanup)
- 各 Certificate の `issuerRef.name: selfsigned-cluster-issuer` を確認

```bash
# Certificate spec 詳細確認
helmfile -f kubernetes/components/cilium/production/helmfile.yaml -e production template --include-crds --skip-tests --set prometheus.serviceMonitor.trustCRDsExist=true,operator.prometheus.serviceMonitor.trustCRDsExist=true,hubble.metrics.serviceMonitor.trustCRDsExist=true 2>&1 | \
  grep -B1 -A8 "kind: Certificate" | head -30
```

Expected: 各 Certificate の `spec.issuerRef.name: selfsigned-cluster-issuer`、`kind: ClusterIssuer`、`group: cert-manager.io` が含まれる

### Step 4: Diff 確認

```bash
git diff kubernetes/components/cilium/production/values.yaml.gotmpl
```

Expected:
- `tls.auto.method: cronJob` → `certmanager` に変更
- `certManagerIssuerRef` block 追加 (= `name: selfsigned-cluster-issuer` / `kind: ClusterIssuer` / `group: cert-manager.io`)
- comment 更新 (= "TLS certs は cert-manager で管理")

### Step 5: Commit

```bash
git add kubernetes/components/cilium/production/values.yaml.gotmpl
git commit -s -m "feat(eks): Cilium Hubble TLS to cert-manager method (Phase 4-1)"
```

Expected: 1 file changed、commit subject ≤ 72 chars (= 63 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 3: Hydrate manifests + verify

**Files:**
- Modify (auto-generated): `kubernetes/manifests/production/cert-manager/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/cilium/manifest.yaml` (= Hubble TLS Certificate 反映、CronJob 削除)
- Modify (auto-generated): `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= cert-manager namespace block 追加)
- Modify (auto-generated): `kubernetes/manifests/production/kustomization.yaml` (= ./cert-manager auto-insert)

**Context:** Task 1 + 2 で values + namespace.yaml + kustomization 修正済。Task 3 で hydrated manifests を再生成し、Flux が apply する actual YAML を更新する。

### Step 1: cert-manager manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=cert-manager ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/cert-manager/manifest.yaml` 新規作成 (= chart render + ClusterIssuer)
- `kubernetes/manifests/production/cert-manager/kustomization.yaml` 新規作成 (= `resources: [manifest.yaml]`)

### Step 2: Cilium manifest を再生成 (= TLS migration 反映)

```bash
cd kubernetes
make hydrate-component COMPONENT=cilium ENV=production
cd ..
```

Expected: `kubernetes/manifests/production/cilium/manifest.yaml` 更新 (= Certificate resources 追加、CronJob 削除)

### Step 3: production の 00-namespaces + kustomization を再生成

```bash
cd kubernetes
make hydrate-index ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` 更新 (= `cert-manager` Namespace block 追加)
- `kubernetes/manifests/production/kustomization.yaml` 更新 (= `./cert-manager` resources line 自動 insert、alphabetical order)

### Step 4: cert-manager manifest 内容確認

```bash
grep -E "kind: (Deployment|ClusterIssuer|CustomResourceDefinition|ServiceMonitor)" \
  kubernetes/manifests/production/cert-manager/manifest.yaml | head -15
```

Expected:
- 6 CRDs (cert-manager.io 系)
- 3 Deployments (cert-manager / cert-manager-cainjector / cert-manager-webhook)
- 1 ClusterIssuer (selfsigned-cluster-issuer)
- 1 ServiceMonitor (cert-manager)

### Step 5: Cilium manifest の Hubble TLS migration 反映確認

```bash
echo "--- Certificate resources (= 新生成) ---"
grep -B1 -A5 "kind: Certificate" kubernetes/manifests/production/cilium/manifest.yaml | grep -E "name:|issuerRef|kind:" | head -10
echo ""
echo "--- CronJob 削除確認 ---"
grep "kind: CronJob" kubernetes/manifests/production/cilium/manifest.yaml || echo "(no CronJob = ✅ 削除済)"
```

Expected:
- Certificate resources の `issuerRef.name: selfsigned-cluster-issuer` が確認できる
- "no CronJob = ✅ 削除済"

### Step 6: 00-namespaces.yaml に cert-manager namespace 追加確認

```bash
grep -B1 -A3 "name: cert-manager" kubernetes/manifests/production/00-namespaces/namespaces.yaml | head -10
```

Expected:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    app.kubernetes.io/name: cert-manager
```

### Step 7: production kustomization.yaml に ./cert-manager 追加確認

```bash
grep "cert-manager" kubernetes/manifests/production/kustomization.yaml
```

Expected: `  - ./cert-manager` が resources list に含まれる (= alphabetical order)

### Step 8: kustomize build で全体 manifest が valid render することを確認

```bash
kustomize build kubernetes/manifests/production 2>&1 | tail -10
```

Expected: error なし、最後に何らかの YAML resource が出力される (= kustomization build success)

### Step 9: Diff 確認

```bash
git status
git diff --stat
```

Expected:
- 新規: production/cert-manager/{kustomization.yaml, manifest.yaml}
- 修正: production/cilium/manifest.yaml (= Certificate 追加、CronJob 削除)
- 修正: production/00-namespaces/namespaces.yaml (= cert-manager 追加)
- 修正: production/kustomization.yaml (= ./cert-manager 追加)

### Step 10: Commit

```bash
git add kubernetes/manifests/
git commit -s -m "feat(eks): hydrate cert-manager + cilium (Phase 4-1)"
```

Expected: 4-5 files changed、commit subject ≤ 72 chars (= 53 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 4: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Task 1-3 完了後の commit 累計 4 件 (= spec + 3 implementation)。Sub-project 2 / 3 / 4a / 4b で確立した standard runbook (= Pre-flight check 結果を PR description に記録、Draft で push、USER GATE で Ready for review + merge)。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-cert-manager-foundation-and-cilium-tls
git log --oneline origin/main..HEAD
```

Expected: 4 commits ahead (Task 1 から Task 3 まで + spec commit)
```
<sha> feat(eks): hydrate cert-manager + cilium (Phase 4-1)
<sha> feat(eks): Cilium Hubble TLS to cert-manager method (Phase 4-1)
<sha> feat(eks): cert-manager v1.18 + selfsigned ClusterIssuer (Phase 4-1)
d68c729 docs(eks): Phase 4-1 (cert-manager + Cilium TLS migration) design
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (= 既 spec push 時に `git push -u origin HEAD` 済)、push success message

### Step 3: PR title 文字数チェック (≤ 72 chars)

```bash
echo -n "feat(eks): Phase 4-1 — cert-manager + Cilium TLS migration" | wc -m
```

Expected: 58 chars (em dash 含む、visible ≈ 56 chars、Sub-project 2 / 3 / 4a / 4b の PR title 命名 pattern と整合)

### Step 4: Draft PR を作成 (Pre-flight check 結果を含む)

PR body は以下:

```markdown
## Summary

Phase 4-1 (cert-manager foundation + Cilium TLS migration) の implementation。`jetstack/cert-manager` v1.18.x を `cert-manager` namespace に deploy + selfsigned `ClusterIssuer` を 1 つ作成。既存 Cilium Hubble TLS の `tls.auto.method: cronJob` を Cilium 公式 production-recommended の `certmanager` に switch、上記 ClusterIssuer から TLS cert を発行。本 sub-project 完了時に panicboat cluster は cert-manager-based webhook cert 管理基盤を持ち、Phase 4-2 (= ESO) の admission webhook cert を自動発行できる状態になる。

**Architecture (4-1 完了時):** cert-manager の controller / cainjector / webhook (= 3 replicas + system-cluster-critical priority) が `cert-manager` namespace に deploy。selfsigned `ClusterIssuer` で cluster 内 webhook + Hubble TLS の cert 発行。Cilium Hubble TLS は `Certificate` resource 経由で cert-manager に接続、`hubble-generate-certs` CronJob は削除。他 admission webhooks (Karpenter / ALB Controller / KEDA / prometheus-operator) は builtin self-signed のまま (= Phase 6+ で incremental migrate path)。

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls-design.md` (10 Decisions、Sub-project 1-4b learnings ~30 件のうち applicable 全項目適用)
- Plan: `docs/superpowers/plans/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls.md` (5 tasks)

## Notable Decisions

- **D1**: Chart = `jetstack/cert-manager` v1.18.x (= latest stable、de facto standard)
- **D4**: HA = webhook 3 replicas + `system-cluster-critical` priority class (= cert-manager 公式 production best practice、`cert-manager.io best practice docs` で webhook 不可時は全 cert-manager CR 操作 fail のため HA 必須と明記)
- **D5**: ClusterIssuer = `selfsigned-cluster-issuer` 1 つ (= cluster 内 webhook + Hubble TLS 用、external trust 不要、Let's Encrypt / AWS PCA は Phase 6+)
- **D6**: Cilium TLS migration を同 sub-project で実施 (= Cilium 公式 production-recommended path、`docs.cilium.io/en/v1.18/observability/hubble/configuration/tls/` で cert-manager 推奨と明示)
- **D8**: 他 admission webhooks (Karpenter / ALB Controller / KEDA / prometheus-operator) の cert-manager migration は **Phase 6+ へ postpone** (= 公式 best practice は強い推奨せず、operational consistency improvement のみが motivation)
- **D10**: 1 sub-project 構成 (= 4 task atomic merge、Sub-project 4a と同 pattern)

## Pre-flight check

- [ ] Branch state 1 commit (spec) ahead (Task 0 Step 1)
- [ ] 既存 Cilium Hubble TLS が cronJob method (= `hubble-generate-certs` CronJob 存在) (Task 0 Step 2)
- [ ] cert-manager 未 deploy 状態 (= namespace 不在、CRDs 不在) (Task 0 Step 3)
- [ ] Phase 3 monitoring stack 全 pod Running (Task 0 Step 4)
- [ ] Hubble Relay 動作 baseline 確認、過去 10 分以内 TLS error なし (Task 0 Step 5)
- [ ] Flux not suspended (Task 0 Step 6)

## Test plan (post-flight, after merge)

### 10 分以内
- [ ] cert-manager namespace + 全 5 pods Running (= controller × 1 + cainjector × 1 + webhook × 3)、restartCount 0
- [ ] webhook 3 pods 全てに `priority=system-cluster-critical` 付与
- [ ] 6 CRDs (`certificaterequests` / `certificates` / `challenges` / `clusterissuers` / `issuers` / `orders`) install 確認
- [ ] ClusterIssuer `selfsigned-cluster-issuer` `Ready=True`
- [ ] cert-manager ServiceMonitor 存在 + Prometheus targets で UP
- [ ] Cilium DaemonSet / hubble-relay Deployment rolling restart 完了

### 30 分以内
- [ ] Mimir に `certmanager_*` metrics が remote_write 保存済、Grafana で query 可能
- [ ] Cilium chart の CronJob 削除 + Certificate resource 作成 (`hubble-server-certs` / `hubble-relay-client-certs` 等が `Ready=True`)
- [ ] `cilium hubble status` で Hubble Relay: OK、過去 5 分以内 TLS handshake error なし
- [ ] `hubble observe --last 10` で flows 表示 (= TLS migration で flow stream 中断していない)
- [ ] 既存 4a path (= Tempo / OTel Collector / Loki / Mimir) regression なし
- [ ] cert-manager controller log で過去 10m persistent error なし

## Sub-project 1-4b learnings 適用

| Learning | 4-1 での適用 |
|---|---|
| **2-L1 (chart upgrade での upstream changelog 確認)** | cert-manager v1.18.x の release notes / migration guide を実装段階で確認、CRDs schema 変更 / breaking change の有無を verify |
| **3-L1 (chart 内部固定 path 問題)** | cert-manager chart の `prometheus.servicemonitor` key path、Cilium chart の `certManagerIssuerRef` block 構造を実装段階で `helm show values` で pre-validate |
| **3-L3 (chart probe / serviceMonitor key 確認)** | cert-manager chart の ServiceMonitor key 構造を Step 2 で `helm show values jetstack/cert-manager` で確認 |
| **3-L5 (Flux suspend pattern)** | Risks / Rollback section で standard runbook として明示 (= Pattern A / B / C) |
| **3-L8 (post-flight check)** | 13 項目を Test plan で明示 |
| **3-L9 (公式 docs 引用)** | D4 (= webhook 3 replicas) で cert-manager 公式 best practice docs を direct citation、D6 (= Cilium TLS certmanager) で Cilium 1.18 公式 docs を direct citation |
| **3-L10 (Phase 3 全体 12 件 runtime issue)** | 4-1 で L1-L9 + 4a L1-L8 + 4b L1-L4 適用、Phase 4 初 sub-project は 0 runtime issue 目標 |
| **4a-L1 (累積効果で initial deploy 0 issue)** | 4-1 でも 0 runtime issue 目標 |
| **4a-L2 (startup transient を persistent と決めつけない)** | post-flight verification で起動 ~60s 以内の transient error は L3 checklist で除外、特に Cilium TLS migration の swap transient + ClusterIssuer apply timing transient を認識 |
| **4a-L3 (persistent vs transient 5-step checklist)** | post-flight check section の最後に明示組み込み |
| **4a-L5 (kubectl 出力 truncate に注意)** | post-flight check で `head -N` 避け、`-o jsonpath` / `-o yaml` で完全 field 取得 |
| **4a-L7 (sub-project 分割 ROI)** | 4-1 は cert-manager + Cilium TLS switch を 1 sub-project (= D10)、依存関係明確で atomic merge が natural |
| **4b-L1 (spec 段階 chart binary verify の重要性)** | **最重要適用**: Step 1-2 で cert-manager chart latest stable version + ServiceMonitor key path を実装段階で verify、Step 6 で `helm template` 出力で render 検証 (= 4b で `loki` exporter removed を spec 段階で verify せず persistent issue 発生した教訓) |

## Rollback 手順 (想定外障害時)

```bash
# Pattern A: Standard rollback (= Flux suspend + revert)
flux suspend kustomization flux-system -n flux-system
gh pr create --title "revert: Phase 4-1 — cert-manager + Cilium TLS migration" --base main
gh pr merge <revert-pr-num> --squash
flux resume kustomization flux-system -n flux-system
kubectl get pods -n cert-manager 2>&1 || echo "(cert-manager namespace 削除確認)"

# Pattern B: Partial rollback (= Cilium TLS のみ revert)
# cert-manager は維持、Cilium values の tls.auto.method: certmanager → cronJob に戻す revert PR

# Pattern C: cert-manager のみ削除
# 4-1 全体 revert (Pattern A) で cert-manager + Cilium TLS 共に巻き戻し
```

aws/* は 4-1 では touched しないため AWS-side rollback 不要。Hubble Relay TLS rollback 中の transient は数秒、historical flows は relay buffer で保持。
```

```bash
gh pr create --draft \
  --title "feat(eks): Phase 4-1 — cert-manager + Cilium TLS migration" \
  --body "$(<上記 PR body>)"
```

Expected: PR URL 出力 (例: `https://github.com/panicboat/platform/pull/<N>`)

### Step 5: PR URL を確認

```bash
gh pr view --json title,url,isDraft --jq '.'
```

Expected:
```json
{
    "isDraft": true,
    "title": "feat(eks): Phase 4-1 — cert-manager + Cilium TLS migration",
    "url": "https://github.com/panicboat/platform/pull/<N>"
}
```

(ここで USER GATE: PR review + Ready for review + merge は user 操作)

---

## Self-review

### Spec coverage

| Spec section | 実装 task | カバレッジ |
|---|---|---|
| Architecture (mermaid 4-1 完了時) | Task 1 + 2 | ✅ cert-manager components + ClusterIssuer + Cilium TLS migration すべて |
| Scope (3 task) | Task 1 / 2 / 3 | ✅ cert-manager component / Cilium TLS / Hydrate すべて |
| Out of scope (Phase 4-2 以降 / Phase 6+) | (= deploy しないため task 不在) | ✅ |
| Decision 1 (chart `jetstack/cert-manager` v1.18.x) | Task 1 Step 1 (= version 確認) + Step 4 (helmfile.yaml) | ✅ |
| Decision 2 (namespace `cert-manager`) | Task 1 Step 3 (= namespace.yaml) + Step 4 (helmfile.yaml) | ✅ |
| Decision 3 (CRD installation = chart 経由) | Task 1 Step 5 (`crds.enabled: true`) + Step 6 (= 6 CRDs render verify) | ✅ |
| Decision 4 (HA: webhook 3 replicas + system-cluster-critical) | Task 1 Step 5 (`webhook.replicaCount: 3`、`global.priorityClassName: system-cluster-critical`) + Step 6 (= render verify) | ✅ |
| Decision 5 (ClusterIssuer `selfsigned-cluster-issuer`) | Task 1 Step 7 (cluster-issuer.yaml) | ✅ |
| Decision 6 (Cilium TLS 同 sub-project migration) | Task 2 (= Cilium values 修正) | ✅ |
| Decision 7 (ServiceMonitor enable) | Task 1 Step 5 (`prometheus.servicemonitor.enabled: true`) + Step 6 (ServiceMonitor render verify) | ✅ |
| Decision 8 (他 webhooks Phase 6+ postpone) | (= touched しないため task 不在、Out of scope に明示) | ✅ |
| Decision 9 (namespace.yaml top-level 配置) | Task 1 Step 3 (= top-level に配置) | ✅ |
| Decision 10 (1 sub-project atomic merge) | Task 4 (= 4 commits 1 PR) | ✅ |
| Risks / Rollback (Pattern A/B/C) | Task 4 Step 4 (PR body の Rollback 手順) | ✅ |
| Post-flight check (13 items) | Task 4 Step 4 (PR body の Test plan) | ✅ |

### Placeholder scan

- [x] `TBD` / `TODO` / `FIXME` / `XXX` 等の placeholder なし
- [x] `<step1 で確認した version>` placeholder は chart latest stable 確認結果を埋める意図的記述 (= Task 1 Step 1 / Step 4)
- [x] `<sha>` placeholder は git commit hash placeholder として意図的 (= Task 4 Step 1)
- [x] `<N>` placeholder は PR 番号として意図的 (= Task 4 Step 4 / Step 5)
- [x] `<上記 PR body>` は heredoc-style PR body insertion を意図 (= Task 4 Step 4)、code block 内に PR body 全文記述済

### Type / Property name consistency

- [x] `cert-manager` namespace (Task 1 namespace.yaml + production helmfile.yaml + values.yaml.gotmpl): 全て同一
- [x] `selfsigned-cluster-issuer` ClusterIssuer name (Task 1 cluster-issuer.yaml + Task 2 Cilium values `certManagerIssuerRef.name`): 全て同一
- [x] `system-cluster-critical` priority class (Task 1 values.yaml.gotmpl `global.priorityClassName`): 全 cert-manager component に適用
- [x] `release: kube-prometheus-stack` ServiceMonitor label (Task 1 values.yaml.gotmpl `prometheus.servicemonitor.labels`): Sub-project 1-4b の ServiceMonitor pattern と整合
- [x] `certManagerIssuerRef.{name, kind, group}` (Task 2 Cilium values): `name: selfsigned-cluster-issuer` / `kind: ClusterIssuer` / `group: cert-manager.io` 一貫
- [x] commit subject prefix: `feat(eks):` (= 3 commits)、Sub-project 4a / 4b と整合

---

## Lessons Learned (post-execution)

PR #306 (本 sub-project の merge) で deploy した直後の post-flight verification は **actual runtime issue 0 件** で完了。Sub-project 4b の **3 件 runtime issue + 2 fix forward PR** から大幅改善し、Sub-project 4a (= 0 issue) と同等の clean implementation を再現。Phase 4 初 sub-project として 4b learnings (特に L1 = chart binary verify) の systematic application が有効に機能した。次 sub-project (= Phase 4-2 ESO + Reloader) 設計時の参考として、また Phase 4 全体 pattern の confirmation として記録する。

### Phase 3 全体 + Phase 4-1 runtime issue 数 update

| Sub-project | initial deploy | runtime fix | 計 |
|---|---|---|---|
| Sub-project 1 (AWS infra) | 0 | 0 | 0 |
| Sub-project 2 (Mimir) | 5 | 0 | 5 |
| Sub-project 3 (Loki + Fluent Bit) | 4 | 0 | 4 |
| Sub-project 4a (Tempo + OTel Collector) | 0 | 0 | 0 |
| Sub-project 4b (logs path completion) | 3 | 0 | 3 |
| **Phase 4-1 (cert-manager + Cilium TLS)** | **0** | 0 | **0** |
| **Phase 3-4 累計** | | | **12** |

= **4-1 で 0 件達成**、4b の "3 件" から大幅改善、Phase 3 全体累計 12 件を維持 (= Phase 4 で増加なし)。

### L1: Sub-project 4b L1 (= spec 段階 chart binary verify) の systematic application が有効に機能

4b で発覚した root cause: spec 段階で chart binary に含まれる component (`loki` exporter) を verify せず、deploy 後に persistent issue 発生。これを 4-1 で **systematic に適用**:

**Plan Task 1 で明示的 step として組み込み**:

- Step 1: `helm search repo jetstack/cert-manager --versions` で latest stable version 確認
- Step 2: `helm show values jetstack/cert-manager` で ServiceMonitor key path 確認
- Step 6: `helm template` 出力で 6 CRDs + 3 Deployments + 1 ServiceMonitor が render されることを verify

**結果**:

- spec 仮定 v1.18.x → 実装時に actual latest stable v1.20.2 を採用 (= chart upgrade gap の解消)
- ServiceMonitor key path = `prometheus.servicemonitor.enabled` (小文字) を事前確認、values.yaml.gotmpl で正しい key を使用 = post-flight で ServiceMonitor が正しく render
- 6 CRDs / 3 Deployments / 1 ServiceMonitor の render を事前 verify、実 deploy で同等動作を確認

= **4b L1 が effective**、persistent issue を未然防止。Phase 4-2 / 4-3 でも同 systematic step を組み込む方針継続。

**How to apply (= future sub-projects)**:

1. plan に **必ず "chart binary verify" step を明示**: chart latest version 確認 + key path 確認 + render verify の 3 step
2. spec の chart version は placeholder で OK、plan で "実装時に最新 stable 確認" と instruct
3. chart 固有 key (= ServiceMonitor / probe path / resource keys) を `helm show values` で事前確認

### L2: cert-manager startup transient pattern の認識

Post-flight 直後 (= deploy 後 ~30s) に cert-manager controller log で 2 種の error 発生:

```
"failed calling webhook \"webhook.cert-manager.io\": failed to call webhook: 
 ... no endpoints available for service \"cert-manager-webhook\""

"Operation cannot be fulfilled on certificates.cert-manager.io \"hubble-relay-client-certs\": 
 the object has been modified; please apply your changes to the latest version and try again"
```

**両者ともに startup transient** (= L3 checklist で除外):

- "no endpoints available" = webhook pods が ready になる前の transient (= ~30s 以内 resolve)
- "optimistic locking" = 並行 reconcile での K8s standard race condition (= retry で resolve)

**Why (= 重要 pattern)**:

cert-manager の起動 sequence は **chicken-and-egg** 問題を含む:
1. cert-manager controller 起動 → Certificate resources reconcile 試行
2. しかし webhook pods (= 同 chart で deploy) がまだ ready でない
3. validation webhook が応答せず → controller の reconcile が fail
4. webhook ready 後に retry → 成功

= **cert-manager 起動直後は webhook readiness gap で transient errors が必ず出る**。Sub-project 4a L3 checklist (= ~60s 以内 transient は除外) を適用し、persistent と決めつけない。

**How to apply**:

1. cert-manager 関連 sub-project の post-flight check では **起動 ~30-60s 以内の "no endpoints available" / "optimistic locking" は normal と認識**
2. この transient pattern を Phase 4-2 ESO deploy 時にも適用 (= ESO admission webhook も同 chicken-and-egg 問題を含む可能性)
3. post-flight check で error log 確認時、**`kubectl logs --since=2m` で recent state を見る** (= 起動直後の transient を区別)

### L3: Cilium TLS migration の clean swap pattern

Sub-project 4-1 Decision 6 で Cilium 公式 production-recommended path に migrate (= cronJob → certmanager)。Migration の transient は **数秒以内、production への顕著な影響なし**:

**観察された動作**:

```
# Hubble Relay log (post-merge ~3 分後)
time=2026-05-08T07:43:32Z level=info msg="Certificate authority updated" subsys=hubble-relay
time=2026-05-08T07:43:32Z level=info msg="Keypair updated" subsys=hubble-relay keyPairSN=92f1deefcb09bf...
```

= cert-manager 由来の新 cert に **clean swap 完了**、Hubble Relay の TLS handshake 中断は数秒以内、historical flows は relay buffer で保持。

**Why (= chart の transition path が良質)**:

Cilium chart は `tls.auto.method: certmanager` 設定時に:
1. 旧 cronJob 由来の secret (= `hubble-server-certs` 等) を **同名で cert-manager 由来に置換**
2. Hubble Relay は secret reload を auto detect (= mounted volume 経由)、新 cert で再 handshake
3. CronJob `hubble-generate-certs` は rendered manifest から消えて Flux で削除

= **chart の transition design が clean**、production 影響軽微。

**How to apply**:

1. 他 components の cert-manager migration (= Phase 6+ Karpenter / ALB / KEDA / prometheus-operator) でも同 pattern を期待可能、ただし各 chart の `tls.auto.method` 相当 key と migration 動作を **個別に verify** (= L1 適用)
2. Cilium 公式 docs ([docs.cilium.io/en/v1.18/observability/hubble/configuration/tls/](https://docs.cilium.io/en/v1.18/observability/hubble/configuration/tls/)) のような **公式 production-recommended path 表記** を chart docs で確認

### L4: subagent-driven development pattern の cadence improvement (= 4b 比)

| 観点 | Sub-project 4b | Sub-project 4-1 |
|---|---|---|
| Initial implementation tasks | 5 (Cilium / Fluent Bit / OTel / README / hydrate) | 3 (cert-manager / Cilium TLS / hydrate) |
| Implementer DONE 1 回で pass | 1/5 (Task 4 README) | 2/3 (Task 2 Cilium TLS、Task 3 hydrate) |
| 1 fix amend 必要 | 4/5 | 1/3 (Task 1 cert-manager の CLAUDE.md violation) |
| Re-review iterations | 5 (= multiple stale comment fixes) | 1 (= CLAUDE.md violation 1 round) |
| Combined review (= spec + code 同時 dispatch) | 3 stages separately | Task 2 / 3 で combined 採用 = 効率改善 |
| **Initial deploy runtime issues** | **3** | **0** |
| **Total subagent dispatches** | ~20 | ~6 |

= **subagent-driven development pattern の learning curve effect**、4b で多発した CLAUDE.md violation / chart binary verify ミスが 4-1 で大幅減少。

**Why**:

- Plan に 4b learnings (特に L1 chart binary verify) を **明示的 step として組み込み**、implementer が miss しにくい
- Combined spec + code review (= 1 reviewer subagent) で iteration cost 削減
- CLAUDE.md naming rule violation pattern が認識可能 (= "Phase X で deploy" "Sub-project Y 適用" 等)、implementer が事前回避

**How to apply**:

1. Phase 4-2 / 4-3 でも **plan に "chart binary verify" を明示 step として組み込み** (= L1 systematic application)
2. **Combined spec + code reviewer** を Task 2-3 で活用、3 stages を 1 stage に圧縮
3. CLAUDE.md naming rule violation pattern を implementer prompt で **explicit に flag**

### L5: spec の chart version placeholder pattern が established

4-1 で spec の `v1.18.x` (= placeholder) と plan の "実装時に最新 stable 確認" 指示の組合せで、実装者が **v1.20.2 (= actual latest stable)** を採用、spec compliance reviewer も "spec の真意 = latest stable と整合" と approve。

**Why (= practical reasons)**:

- spec 作成時 (= brainstorming 時) と implementation 時 (= subagent 実行時) で chart version が変動する可能性
- spec を毎回 amend するのは impractical
- 「version は plan で `latest stable 確認` と instruct + spec は placeholder」 で柔軟性確保

**Pattern (= future sub-projects 向け)**:

- spec: chart version は **brainstorming 時の latest stable を placeholder として記述** (= "v1.18.x" 等)
- plan: Step 1 で **`helm search repo --versions` で actual latest 確認**、helmfile.yaml に書き込む version は本 step 結果を採用
- spec reviewer: "spec の chart version が違う" を flag せず、"latest stable 意図と integral" として approve

### L6: Phase 4 全体 pattern の confirmation

Sub-project 4-1 完了で Phase 4 sub-project 構造 (= 4-1 / 4-2 / 4-3) の **第 1 弾が validate**:

- 4-1 (cert-manager + Cilium TLS): 0 issue で完了 ✅
- 4-2 (ESO + Reloader): 4-1 の cert-manager + ClusterIssuer を前提として deploy
- 4-3 (Grafana auth + Ingress): 4-1 + 4-2 を前提として、Grafana 外部公開 + 認証ゲート

= **Phase 4 sub-project 間の依存関係が clean** (= 4-1 → 4-2 → 4-3 が順序通り)、Phase 5 (= nginx) までの roadmap が articulate。

**Phase 4 引き継ぎ事項 update (= 4-1 完了時)**:

| 項目 | 状態 |
|---|---|
| 1. gp3 StorageClass の Layer 2 documented exception 化 | Phase 6+ 引き継ぎ |
| 2. bucket-per-env への migration 検討 | Phase 6+ 引き継ぎ |
| 3. multi-tenant 化 + 詳細 retention rules | Phase 6+ 引き継ぎ |
| 4. OTel Operator deploy 検討 | **Phase 5 nginx 投入時に評価** |
| 5. post-flight check の自動化 | Phase 6+ 引き継ぎ |
| 6. Beyla deploy + OTel Collector metrics pipeline 拡張 | **Phase 5 nginx 投入時に同時 deploy** |
| 7. Hubble flow logs → Loki path 評価 | Phase 6+ 引き継ぎ |
| 8. local Fluent Bit OTLP gRPC 統一 | Phase 6+ 引き継ぎ |
| 9. Pod CPU requests audit + rightsizing | **Phase 5 nginx + 観測 burst 後に実施** |
| 10. OTel Collector exporter type alias check 自動化 | Phase 6+ 引き継ぎ |

= 4-1 完了で **明示的に解消した引き継ぎ事項なし** (= cert-manager deploy は roadmap Phase 4 の primary goal、引き継ぎ事項とは別カテゴリ)、ただし 引き継ぎ #4 / #6 / #9 が Phase 5 で同時解消される予定で **Phase 4-2 / 4-3 完了時の re-evaluation** を推奨。

### 次 sub-project (= Phase 4-2 ESO + Reloader) への適用

1. **L1**: ESO + Reloader chart の latest stable + 各 chart 固有 key を Plan Step 1-2 で systematic verify
2. **L2**: ESO admission webhook の startup transient pattern を post-flight で認識
3. **L4**: Combined spec + code reviewer を全 Task で採用、subagent 数を minimize
4. **L5**: spec で chart version は placeholder OK pattern 継続
