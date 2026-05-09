# EKS Production: Beyla Foundation (Phase 5-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) で `grafana/beyla` chart を `monitoring` namespace に DaemonSet deploy、`default` namespace の application Pod を eBPF auto-instrumentation で観測する基盤を確立。Phase 5-2 nginx 投入時に Beyla が即時に nginx HTTP request span を Tempo に送る + RED metrics を Prometheus → Mimir に流す状態を作る。引き継ぎ事項 #6 part 1 解消、Phase 4-3 L6 (= Tempo empty) の prerequisite 解消。

**Architecture:** Beyla DaemonSet (= 1 Pod per node、~5-7 Pods) を `monitoring` namespace に deploy、`hostPID: true` + `privileged: true` で eBPF probes を host kernel に attach。`default` namespace の Pod を discover (= K8s API watch)、`open_ports` 省略で全 listening port auto-discover。Traces は OTel Collector (= `monitoring` namespace の既存 Collector) へ OTLP gRPC :4317、Metrics は `/metrics` :9090 で Prometheus exposition format expose、ServiceMonitor (= kube-prometheus-stack) 経由で Prometheus が scrape → remote_write → Mimir。AWS access 不要 (= no Pod Identity、no S3、no IAM)、kustomization overlay 不要 (= chart 範囲外 resource なし)。

**Tech Stack:** Helm + helmfile / `grafana/beyla` v1.16.x (= 実装時に latest stable 確認、local 1.16.6 を baseline) / OpenTelemetry Collector v0.151.0 (= Phase 4-3 で deploy 済) / kube-prometheus-stack ServiceMonitor (= Phase 3 既存) / Mimir (= PR #312 RF=1 + PR #314 limits 500K + apiserver bucket drop) / cert-manager + ESO + Reloader + oauth2-proxy (= Phase 4 で deploy 済、Phase 5-1 では touch なし)

**Spec:** `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (beyla production)**:

```
kubernetes/components/beyla/production/
├── helmfile.yaml                  # grafana/beyla chart deploy
└── values.yaml.gotmpl             # production-specific config
                                   #   - preset: application
                                   #   - discovery.services: default namespace のみ、open_ports 省略
                                   #   - otel_traces_export → opentelemetry-collector.monitoring:4317
                                   #   - prometheus_export :9090 + serviceMonitor enable
                                   #   - filter.network: kube* / *prometheus* / *grafana* 等 exclude
                                   #   - resources: small DaemonSet sizing
                                   #   - priorityClassName: system-cluster-critical
```

**Kubernetes 自動生成 (= production hydrate output)**:

```
kubernetes/manifests/production/beyla/{kustomization.yaml, manifest.yaml}    # 新規
kubernetes/manifests/production/kustomization.yaml                           # 修正 (= ./beyla auto-insert、alphabetical order)
```

**変更しないファイル**: `kubernetes/components/beyla/local/*` (= local 既存 deploy、Phase 5-1 で touch なし) / `kubernetes/components/beyla/namespace.yaml` (= **新規作成不要、`monitoring` namespace 既存活用**) / `aws/*` (= 全 terragrunt stack、AWS access 不要) / `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= namespace 新規作成なし) / 他 K8s components / `kubernetes/components/{external-secrets,reloader,cert-manager,oauth2-proxy,prometheus-operator,opentelemetry-collector,mimir,loki,tempo}/*` (= Phase 4 で deploy 済、Phase 5-1 で touch なし)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** Phase 5-1 開始前に cluster 状態 + branch 状態を確認。Phase 4 完了状態 + Mimir cardinality fix (= PR #314) merged 状態を baseline、Phase 5-1 で Beyla deploy する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-beyla-foundation
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead

```
106c680 docs(eks): Phase 5-1 (Beyla foundation) design
```

- [ ] **Step 2: Phase 4 完了状態 verify (= cert-manager + ESO + Reloader + oauth2-proxy)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- cert-manager ---"
kubectl get pods -n cert-manager 2>&1 | head -5
echo ""
echo "--- ESO + ClusterSecretStore ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo ""
echo "--- Reloader ---"
kubectl get pods -n reloader
echo ""
echo "--- oauth2-proxy 4 instances ---"
kubectl get deploy -n oauth2-proxy | grep -v NAME | wc -l'
```

Expected:
- cert-manager pods 全 Running
- ClusterSecretStore Ready=`True`
- Reloader pod Running
- oauth2-proxy: 4 deployments (= grafana / hubble / alertmanager / prometheus)

- [ ] **Step 3: Mimir cardinality fix (= PR #314) 反映確認**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- max_global_series_per_user 設定 ---"
kubectl get cm -n monitoring mimir-distributed-config -o jsonpath="{.data.mimir\.yaml}" | grep "max_global_series_per_user"
echo ""
echo "--- distributor 直近 1 分の reject 件数 ---"
kubectl logs -n monitoring deployment/mimir-distributed-distributor --since=1m 2>&1 | grep -c "max-series-per-user" || echo "0"'
```

Expected:
- `max_global_series_per_user: 500000` (= PR #314 反映)
- reject 件数 0 (= Mimir cardinality fix で停止済)

- [ ] **Step 4: OpenTelemetry Collector 既存動作確認 (= Beyla traces 送信先)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- OTel Collector pods + Service ---"
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
echo ""
kubectl get svc -n monitoring opentelemetry-collector
echo ""
echo "--- Service ports (= 4317 OTLP gRPC、4318 OTLP HTTP) ---"
kubectl get svc -n monitoring opentelemetry-collector -o jsonpath="{.spec.ports[*].port}{\"\\n\"}"'
```

Expected:
- opentelemetry-collector Pod Running
- Service `opentelemetry-collector.monitoring.svc.cluster.local` 存在
- Service ports に `4317` (= OTLP gRPC) 含まれる

- [ ] **Step 5: 既存 Beyla production 不在確認 (= 新規 deploy 想定)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get ds -n monitoring beyla-beyla 2>&1 | head -3
echo ""
ls kubernetes/components/beyla/production/ 2>&1 | head -5'
```

Expected:
- `Error from server (NotFound): daemonsets.apps "beyla-beyla" not found`
- `kubernetes/components/beyla/production/` directory 不在 (= Phase 5-1 Task 1 で新規作成)

- [ ] **Step 6: monitoring namespace の既存 Pod 健康確認 (= regression baseline)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n monitoring | grep -v "1/1\|2/2\|3/3" | grep -v Completed | head -5 || echo "(全 monitoring pod Ready)"'
```

Expected: 結果なし or `(全 monitoring pod Ready)` (= 全 monitoring pod が Ready 状態)

- [ ] **Step 7: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1 | head -3'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:d28ed2bd...` (= PR #314 merge 済) もしくはそれ以降の commit

- [ ] **Step 8: EKS node の kernel version 確認 (= eBPF probe attach 前提条件)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{\"\\t\"}{.status.nodeInfo.kernelVersion}{\"\\n\"}{end}"'
```

Expected: 全 node の kernel version が **5.10+** (= Beyla supported 範囲、EKS AL2023 default は 5.10+ で OK)

---

## Task 1: Beyla deploy

**Files:**

- Create: `kubernetes/components/beyla/production/helmfile.yaml`
- Create: `kubernetes/components/beyla/production/values.yaml.gotmpl`

**Context:** Phase 5-1 で deploy する Beyla chart の component を新規作成。local の既存 component を baseline として production 向けに調整 (= namespace `monitoring` 既存活用、AWS access 不要、kustomization overlay 不要)。Sub-project 4b L1 / 4-1 L1 / 4-2 L1 / 4-3 L1 (= chart binary verify systematic step) を Step 1-2 で適用、4-3 L2 (= chart-fixed value detection) + 4-3 L4 (= 急進化 chart の design assumption gap calibration) を Step 3 で適用。

### Step 1: chart 最新 stable version 確認 (= L1 systematic application)

```bash
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana
helm search repo grafana/beyla --versions | head -5
```

Expected: 上位に latest stable version (= `1.16.x` or それ以降) が表示。spec では `1.16.x` を仮定したが、実際の最新 stable patch を採用 (= local の 1.16.6 と同等 or 上位)。本 step で確認した version を Step 4 helmfile.yaml の `version:` に記入。

### Step 2: chart values の key path 確認 (= L1 + L2 適用、特に注意 keys)

```bash
helm show values grafana/beyla --version <step1 で確認した version> | head -150
```

確認すべき keys (= L2 chart-fixed value detection 含む):

- `preset` (= `application` / `network` 等の選択肢確認)
- `config.data.otel_traces_export.endpoint` の正確な YAML path
- `config.data.discovery.services` の YAML path + `k8s_namespace` / `open_ports` 等の subkey
- `config.data.filter.network.k8s_dst_owner_name` / `k8s_src_owner_name` の YAML path
- `serviceMonitor` の key path (= `enabled` / `additionalLabels` / `extraLabels` / `labels` のどれか、4-3 L2 chart-fixed value pattern を要確認)
- `service` の key path (= ServiceMonitor scrape target 用)
- `priorityClassName` の配置 (= top-level vs `daemonset.priorityClassName`)
- `resources` の key path
- DaemonSet の `hostPID` / `privileged` / `securityContext` の chart 設定方法 (= preset 自動 set or 明示 override)

NOTE: chart 固有 key path に従って Step 4 values.yaml.gotmpl を調整。chart-fixed value (= override 不能 key) があれば values での指定を省略する (= 4-2 / 4-3 L2 pattern)。

### Step 3: production/helmfile.yaml を作成

`kubernetes/components/beyla/production/helmfile.yaml`:

```yaml
# =============================================================================
# Beyla Helmfile for production
# =============================================================================
# Beyla eBPF auto-instrumentation を monitoring namespace に DaemonSet deploy。
# default namespace の application Pod を観測、traces を OTel Collector 経由
# Tempo に、metrics を /metrics + ServiceMonitor 経由 Prometheus → Mimir に送る。
# Phase 5-2 で nginx 投入時に即時 instrumentation 開始する基盤。
# =============================================================================
environments:
  production:
---
repositories:
  - name: grafana
    url: https://grafana.github.io/helm-charts

releases:
  - name: beyla
    namespace: monitoring
    chart: grafana/beyla
    version: "<step 1 で確認した latest stable、例 1.16.6>"
    values:
      - values.yaml.gotmpl
```

### Step 4: production/values.yaml.gotmpl を作成

`kubernetes/components/beyla/production/values.yaml.gotmpl`:

```yaml
# Beyla eBPF Auto-Instrumentation Configuration for production
# default namespace の application Pod を eBPF auto-instrumentation で観測、
# traces を OTel Collector 経由 Tempo に、metrics を /metrics + ServiceMonitor
# 経由 Prometheus → Mimir に送る。

# =============================================================================
# Preset Configuration
# =============================================================================
# "application" preset: application-level metrics + traces focus
# (= chart が DaemonSet + hostPID + privileged + 標準 RBAC を自動 set)
preset: application

# =============================================================================
# Beyla Configuration
# =============================================================================
config:
  data:
    # -------------------------------------------------------------------------
    # OTEL Traces Export → Phase 4-3 で deploy 済 OpenTelemetry Collector 経由 Tempo
    # -------------------------------------------------------------------------
    otel_traces_export:
      endpoint: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
      protocol: grpc
      interval: 5s
      max_export_batch_size: 512

    # -------------------------------------------------------------------------
    # Prometheus Export (= /metrics endpoint、ServiceMonitor で Prometheus が scrape)
    # -------------------------------------------------------------------------
    # NOTE: otel_metrics_export は意図的に未設定。Phase 4-3 で OTel Collector の
    # metrics pipeline は debug exporter (= Mimir 接続未設定) のため、
    # Beyla metrics は Prometheus exposition format で expose し ServiceMonitor
    # 経由で Prometheus → remote_write → Mimir のルートを採用。
    prometheus_export:
      port: 9090
      path: /metrics

    # -------------------------------------------------------------------------
    # Service Discovery (= default namespace の application Pod、open_ports 省略で全 listening port auto-discover)
    # -------------------------------------------------------------------------
    # NOTE: open_ports は明示的に省略。default namespace は application 専用想定
    # (= infra Pod 不在)、全 listening port auto-discover で運用 friction 最小。
    # microservice 追加時に Beyla config 更新不要 (= 新 service の任意 port が自動 trace 対象)。
    discovery:
      services:
        - k8s_namespace: "default"

    # -------------------------------------------------------------------------
    # Route Configuration (= heuristic で URL path から route name 自動推論)
    # -------------------------------------------------------------------------
    routes:
      unmatched: heuristic

    # -------------------------------------------------------------------------
    # Kubernetes Attributes (= service name resolution に K8s metadata を使用)
    # -------------------------------------------------------------------------
    attributes:
      kubernetes:
        enable: true

    # -------------------------------------------------------------------------
    # Network Filter (= infra Pod の trace を exclude、observation noise 削減)
    # -------------------------------------------------------------------------
    filter:
      network:
        k8s_dst_owner_name:
          not_match: "{kube*,*prometheus*,*grafana*,*mimir*,*loki*,*tempo*}"
        k8s_src_owner_name:
          not_match: "{kube*,*prometheus*,*grafana*,*mimir*,*loki*,*tempo*}"

# =============================================================================
# Resources (= small DaemonSet、~5-7 Pods total per cluster)
# =============================================================================
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 384Mi

# =============================================================================
# Priority Class (= Phase 4-2 ESO / Reloader / 4-3 oauth2-proxy と同 priority)
# =============================================================================
# 観測基盤は Phase 5-2 application 投入時の前提条件、cluster 系 component と
# 同 priority に揃えて CPU 逼迫 node でも preempt 動作で確実に schedule する。
priorityClassName: system-cluster-critical

# =============================================================================
# Service (= ServiceMonitor scrape target、/metrics :9090 expose)
# =============================================================================
service:
  enabled: true

# =============================================================================
# ServiceMonitor (= kube-prometheus-stack の serviceMonitorSelector に乗る)
# =============================================================================
# NOTE: chart の ServiceMonitor key path は Step 2 で確認した値を使用。
# 4-3 L2 (= chart-fixed value pattern) があれば labels 省略で対応、
# panicboat の serviceMonitorSelector: {} (= permissive) で全 SM が match する。
serviceMonitor:
  enabled: true
  # labels block は Step 2 確認結果に応じて記述 / 省略を判断
```

NOTE: 上記 values.yaml.gotmpl の `serviceMonitor` block 中の `labels` は **Step 2 で chart 構造を確認後に最終調整**:

- `labels` が override 可能 → `release: kube-prometheus-stack` を明示指定 (= 1-4-3 ServiceMonitor pattern と統一)
- `labels` が chart-fixed (= 例: 値固定) → block 省略 (= 4-3 L2 pattern、`serviceMonitorSelector: {}` の permissive 設定で対応)

### Step 5: helmfile template で render verify (= L1 / L2 / L3 適用)

```bash
cd kubernetes
helmfile -e production -f components/beyla/production/helmfile.yaml template 2>&1 | grep -E "kind: |^# Source: " | head -20
cd ..
```

Expected:
- helmfile template execution success、no error
- 出力に以下 resource が含まれる:
  - `kind: DaemonSet` (= beyla)
  - `kind: Service` (= beyla)
  - `kind: ServiceAccount`
  - `kind: ClusterRole` + `kind: ClusterRoleBinding`
  - `kind: ServiceMonitor` (= 4-3 L3 適用、render されない場合は `helmDefaults.args: ["--api-versions=monitoring.coreos.com/v1"]` を helmfile.yaml に追加して再実行)
  - `kind: ConfigMap` (= beyla config)

```bash
helmfile -e production -f kubernetes/components/beyla/production/helmfile.yaml template 2>&1 | awk '/^kind: DaemonSet$/,/^---$/' | grep -E "hostPID|privileged|priorityClassName" | head -10
```

Expected: `hostPID: true` + `privileged: true` (= preset application で chart 自動 set)、`priorityClassName: system-cluster-critical`

### Step 6: Diff 確認

```bash
git status
git diff --stat
```

Expected: 2 新規ファイル
- `kubernetes/components/beyla/production/helmfile.yaml`
- `kubernetes/components/beyla/production/values.yaml.gotmpl`

### Step 7: Commit

```bash
git add kubernetes/components/beyla/production/
git commit -s -m "feat(eks): Beyla eBPF auto-instrumentation deploy (Phase 5-1)"
```

Expected: 2 files changed、commit subject ≤ 72 chars (= 56 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 2: Hydrate manifests + verify

**Files:**

- Modify (auto-generated): `kubernetes/manifests/production/beyla/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/kustomization.yaml` (= ./beyla auto-insert)

**Context:** Task 1 で K8s component values 作成済。Task 2 で hydrated manifests を再生成し、Flux が apply する actual YAML を更新する。

### Step 1: beyla manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=beyla ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/beyla/manifest.yaml` 新規作成 (= chart render の DaemonSet + Service + ServiceAccount + ClusterRole/Binding + ServiceMonitor + ConfigMap)
- `kubernetes/manifests/production/beyla/kustomization.yaml` 新規作成 (= `resources: [manifest.yaml]`)

### Step 2: production の kustomization を再生成 (= ./beyla auto-insert)

```bash
cd kubernetes
make hydrate-index ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/kustomization.yaml` 更新 (= `./beyla` resources line auto-insert、alphabetical order)
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` 変更なし (= namespace 新規作成なし、`monitoring` namespace 既存活用)

### Step 3: beyla manifest 内容確認

```bash
grep -E "^kind: " kubernetes/manifests/production/beyla/manifest.yaml | sort | uniq -c
```

Expected:
- 1 DaemonSet (= beyla)
- 1 Service (= beyla)
- 1 ServiceAccount
- 1 ClusterRole + 1 ClusterRoleBinding
- 1 ServiceMonitor
- 1 ConfigMap

### Step 4: DaemonSet の eBPF capability + priority 確認

```bash
awk '/^kind: DaemonSet$/,/^---$/' kubernetes/manifests/production/beyla/manifest.yaml | grep -E "hostPID|privileged|priorityClassName|serviceAccountName" | head -10
```

Expected:
- `hostPID: true` (= eBPF 必要)
- `privileged: true` (= chart preset application 由来)
- `priorityClassName: system-cluster-critical`
- `serviceAccountName: beyla-beyla` or 同等

### Step 5: ConfigMap の Beyla config 確認

```bash
awk '/^kind: ConfigMap$/,/^---$/' kubernetes/manifests/production/beyla/manifest.yaml | grep -A 30 "data:" | head -40
```

Expected:
- `otel_traces_export.endpoint` に `opentelemetry-collector.monitoring.svc.cluster.local:4317`
- `prometheus_export.port: 9090`
- `discovery.services` に `k8s_namespace: default` (= open_ports 省略)
- `filter.network` に kube* / prometheus* / grafana* / mimir* / loki* / tempo* exclude

### Step 6: ServiceMonitor 確認

```bash
awk '/^kind: ServiceMonitor$/,/^---$/' kubernetes/manifests/production/beyla/manifest.yaml | head -20
```

Expected:
- `metadata.name: beyla` or 同等
- `spec.endpoints[0].port: <metrics or 9090>`
- `metadata.labels.release: kube-prometheus-stack` (= Step 2 で labels が override 可だった場合) or labels block なし (= chart-fixed の場合)

### Step 7: production kustomization.yaml に ./beyla 追加確認

```bash
grep "beyla" kubernetes/manifests/production/kustomization.yaml
```

Expected: `  - ./beyla` が resources list に含まれる (= alphabetical order)

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
- 新規: `kubernetes/manifests/production/beyla/{kustomization.yaml, manifest.yaml}`
- 修正: `kubernetes/manifests/production/kustomization.yaml` (= ./beyla 追加)

### Step 10: Commit

```bash
git add kubernetes/manifests/
git commit -s -m "feat(eks): hydrate beyla DaemonSet (Phase 5-1)"
```

Expected: 3 files changed、commit subject ≤ 72 chars (= 41 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 3: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Task 1-2 完了後の commit 累計 3 件 (= spec + 2 implementation)。AWS-side terragrunt apply は **本 sub-project では不要** (= AWS access なし、Phase 4-2 ESO IAM role 流用すらしない)。K8s-side は PR merge 後に Flux reconcile で auto apply。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-beyla-foundation
git log --oneline origin/main..HEAD
```

Expected: 3 commits ahead

```
<sha> feat(eks): hydrate beyla DaemonSet (Phase 5-1)
<sha> feat(eks): Beyla eBPF auto-instrumentation deploy (Phase 5-1)
106c680 docs(eks): Phase 5-1 (Beyla foundation) design
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (= 既 spec push 時に push 済)、push success message。track 未設定の場合は `git push -u origin HEAD`。

### Step 3: PR title 文字数チェック (≤ 72 chars)

```bash
echo -n "feat(eks): Phase 5-1 — Beyla eBPF auto-instrumentation foundation" | wc -m
```

Expected: 65 chars (em dash 含む、Sub-project 4-1 / 4-2 / 4-3 の PR title 命名 pattern と整合)

### Step 4: Draft PR を作成 (Pre-flight check 結果を含む)

PR body は以下:

````markdown
## Summary

Phase 5-1 (Beyla foundation) の implementation。`grafana/beyla` v1.16.x を `monitoring` namespace に DaemonSet (= 1 Pod per node、~5-7 Pods total) で deploy、`default` namespace の application Pod を eBPF auto-instrumentation で観測する基盤を確立。Phase 5-2 nginx 投入時に Beyla が即時に nginx HTTP request span を Tempo + RED metrics を Prometheus → Mimir に送る状態を作る。引き継ぎ事項 #6 part 1 (= Beyla deploy) を解消、Phase 4-3 L6 (= Tempo empty) の prerequisite 解消。

AWS terragrunt 新規 stack 不要 (= Beyla AWS access 不要)、kustomization overlay 不要 (= chart 範囲外 resource なし) で **完全に K8s component 1 chart deploy** で完結。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- plan: `docs/superpowers/plans/2026-05-09-eks-production-beyla-foundation.md`

## Notable Decisions

- Phase 5 全体 = 3 sub-projects decompose (= 5-1 Beyla → 5-2 nginx → 5-3 rightsizing)
- OTel Operator 不採用 (= 引き継ぎ #4 evaluation 結果 = Phase 6+ monorepo migration 時)
- Beyla discovery scope = `default` namespace のみ
- Beyla discovery `open_ports` = 省略 (= 全 listening port auto-discover、microservice 追加時 config 更新不要)
- Traces export = OTel Collector 経由 (= OTLP gRPC :4317) → Tempo
- Metrics export = Prometheus /metrics endpoint :9090 + ServiceMonitor → Prometheus → remote_write → Mimir
- AWS terragrunt 新規 stack 不要

## Pre-flight check (executed pre-merge)

- [x] Branch state 確認 (= spec + 2 implementation commits ahead)
- [x] Phase 4 完了状態 verify (= cert-manager / ESO + ClusterSecretStore Ready=True / Reloader / oauth2-proxy 4 instances)
- [x] Mimir cardinality fix (= PR #314) 反映確認 (= max_global_series_per_user: 500000、distributor reject 0 件)
- [x] OpenTelemetry Collector 既存動作確認 (= Pod Running、Service `:4317` OTLP gRPC)
- [x] 既存 Beyla production 不在 (= 想定通り)
- [x] monitoring namespace の既存 Pod 健康確認
- [x] Flux state suspended でない確認
- [x] EKS node の kernel version 5.10+ (= eBPF supported 範囲)

## Test plan (post-flight, after merge)

### 5 分以内

- [ ] Flux が main の latest commit を Applied
- [ ] Beyla DaemonSet `DESIRED == READY` (= 全 node に 1 Pod、~5-7 Pods total)
- [ ] Beyla Pod 全 Running、`/internal/status` health check 200
- [ ] Beyla Pod に `hostPID: true` + `privileged: true`
- [ ] ServiceAccount + ClusterRole + ClusterRoleBinding deploy 済

### 10 分以内 (= telemetry pipeline)

- [ ] Beyla Pod logs に discovery loop 動作 log
- [ ] ServiceMonitor `beyla` 存在 + Prometheus が scrape (`up{job="beyla.*"} == 1`)
- [ ] Beyla 自 metrics が Mimir に流入 (= Grafana で `beyla_internal_*` query)

### 30 分以内 (= Phase 5-2 prerequisite + smoke test)

- [ ] **`default` namespace に test Pod 配置 + HTTP request 生成** (= optional smoke test)
   - `kubectl run -n default test-nginx --image=nginx:latest --port=80 --restart=Never`
   - `kubectl exec -n default test-nginx -- curl -s http://localhost/` を数回実行
   - Beyla が Pod discover → eBPF probe attach → trace 生成
   - Tempo に traces 流入確認 (= Grafana Explore で nginx service.name search)
   - **smoke test 完了後に test Pod 削除** (= Phase 5-2 で正式 nginx 投入)
- [ ] Phase 4-3 Tempo empty issue (= L6) の partial 解消確認 (= test Pod 由来 trace が Tempo に流入)

### Regression check

- [ ] 既 deploy 済 component 全部 Running 維持 (= cert-manager / ESO / Reloader / oauth2-proxy / Mimir / Loki / Tempo / OpenTelemetry Collector)
- [ ] Grafana で既存 dashboard query が動作 (= PR #312 RF=1 + PR #314 cardinality limit + bucket drop の効果維持)

### Sub-project 4a L3 + 4-1 L2 + 4-2 L2 / L3 + 4-3 L1-L6 適用 (= persistent vs transient checklist)

- 起動 ~60s 以内の startup transient (= "no endpoints available" 等) は normal、`kubectl logs --since=2m` で recent state を見る
- ServiceMonitor が hydrate 出力に存在しない場合、helmfile.yaml に `helmDefaults.args: ["--api-versions=monitoring.coreos.com/v1"]` を追加して再 hydrate (= 4-2 L3 適用)
- chart values の `serviceMonitor.labels` が反映されない場合、chart-fixed value (= 4-3 L2) で labels block 省略を確認、panicboat の `serviceMonitorSelector: {}` で全 SM が match することを確認
- AWS direct verify が AccessDenied される場合、application-level proof (= Beyla Pod Running + ServiceMonitor scrape success + smoke test trace 流入) で検証 (= 4-2 L5)

## Sub-project 1-4-3 learnings 適用

- L1 (= chart binary verify systematic step): Beyla chart 1.16.x の latest stable + ServiceMonitor key path + DaemonSet hostPID 設定方法を Step 1-2 で確認、render verify を Step 5 で実施
- L2 (= chart capability assumption の限界、4-3 new): `discovery.services` の `open_ports` 省略の挙動を Beyla docs full read で裏付け、brainstorming で実施済
- L3 (= Pod Identity webhook timing-sensitive injection、4-3 new): Beyla は Pod Identity 不要のため適用外、ただし DaemonSet rollout 時の eBPF probe re-attach に類似の timing pattern が存在する可能性、post-flight で probe attach success を確認
- L4 (= distributed system replica / RF 整合、4-3 new): Beyla は distributed ring 構造を持たない (= DaemonSet 1 Pod per node)、適用外
- L5 (= post-flight end-to-end browser test、4-2 L5 extension): Phase 5-1 では trace source 不在で smoke test (= test Pod) 経由で Beyla pipeline 動作確認、5-2 で nginx 正式投入時に full validation
- L6 (= subagent-driven development cadence): Phase 5-1 は **single chart deploy + AWS なし + kustomization なし** で task 数 minimal (= chart deploy / hydrate / PR の 3 task)、subagent dispatch 数最小
- 4-1 L5 (= chart version placeholder pattern): helmfile.yaml で actual `1.16.x` pinned

## Rollback 手順 (想定外障害時)

```bash
# Pattern A: Standard rollback (= Flux suspend + revert)
flux suspend kustomization flux-system -n flux-system
gh pr create --base main --head revert-phase-5-1 --title "revert: Phase 5-1 (Beyla foundation)" --draft
gh pr merge <pr-number>
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system

# Pattern B: Beyla disable (= chart default に近い state、observability stack は維持)
# values.yaml.gotmpl で DaemonSet 関連 toggle (= replicas 制御不可な DaemonSet には enabled: false 等で対応)、
# revert で元に戻す (= Pattern A 類似)
```
````

Push command:

```bash
gh pr create --draft \
  --base main \
  --head docs/eks-production-beyla-foundation \
  --title "feat(eks): Phase 5-1 — Beyla eBPF auto-instrumentation foundation" \
  --body-file /tmp/pr-body-5-1.md
```

(= PR body を `/tmp/pr-body-5-1.md` に書き出してから `--body-file` で参照)

Expected: Draft PR created、PR URL 表示

---

## Summary

本 sub-project は **Phase 5 (= End-to-end validation) の最初 sub-project**、Phase 5-2 nginx 投入の prerequisite として Beyla eBPF auto-instrumentation 基盤を確立。AWS access 不要 + kustomization overlay 不要で **完全に K8s component 1 chart deploy** で完結、Phase 4 で蓄積した learnings (= L1-L6) を全部適用しつつ、Phase 5 全体 (= 5-1 / 5-2 / 5-3) の minimal 第 1 弾として **operational footprint 最小**。

## Spec / Plan

- spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- plan: `docs/superpowers/plans/2026-05-09-eks-production-beyla-foundation.md`

## Notable Decisions

| Decision | 採用 |
|---|---|
| Phase 5 全体 decomposition | 3 sub-projects (= 5-1 Beyla → 5-2 nginx → 5-3 rightsizing) |
| OTel Operator inclusion | 不採用 (= Phase 6+ monorepo migration 時) |
| Beyla discovery scope | `default` namespace のみ |
| Beyla discovery `open_ports` | 省略 (= 全 listening port auto-discover) |
| Traces export | OTel Collector 経由 → Tempo |
| Metrics export | Prometheus /metrics + ServiceMonitor → Mimir |
| AWS terragrunt 新規 stack | 不要 |

## Implementation 補記

- Beyla `preset: application` で chart が DaemonSet + hostPID + privileged + 標準 RBAC を自動 set、明示 override 不要
- `discovery.services.open_ports` 省略で全 listening port auto-discover (= microservice 追加時の port list maintenance 運用回避)
- `otel_metrics_export` は **意図的に未設定**: Phase 4-3 で OTel Collector の metrics pipeline は debug exporter (= Mimir 接続未設定、引き継ぎ #10 で systematic 対応予定)、Beyla は Prometheus exposition format で expose し ServiceMonitor 経由で Prometheus → remote_write → Mimir のルートを採用
- `filter.network` で kube* / *prometheus* / *grafana* / *mimir* / *loki* / *tempo* を exclude、infra Pod の trace noise 削減
- DaemonSet `priorityClassName: system-cluster-critical` で CPU 逼迫 node でも preempt 動作で確実に schedule

## Pre-flight check (executed pre-merge)

(= 上記 PR body の Pre-flight check と同内容)

## Test plan (post-flight, after merge)

(= 上記 PR body の Test plan と同内容)

## Sub-project 1-4-3 learnings 適用

(= 上記 PR body の learnings 適用と同内容)

## Rollback 手順 (想定外障害時)

(= 上記 PR body の Rollback 手順と同内容)

## Self-review

### Spec coverage check

| Spec section | Plan task |
|---|---|
| Architecture (= request flow) | Task 1 (= chart values で実現)、Task 2 (= hydrate output で render) |
| Components & File Structure | File Structure section + Task 1 / Task 2 |
| Manual Setup | **不要** (= AWS / Google 手動 setup なし、spec で明示済) |
| Decisions (= 7 件) | "Notable Decisions" section に同 7 件 |
| Post-flight Check (= 12 項目) | "Test plan (post-flight)" section に時系列分類で同等 |
| Rollback Patterns (= 2 patterns) | "Rollback 手順" section に同 2 patterns |
| Risks & Mitigations | "Implementation 補記" + "Test plan" の transient checklist |
| Out of Scope | spec-only (= plan には記述しない、scope 確認のみ) |
| Phase 5 引き継ぎ事項 update | spec-only (= post-execution learnings PR で update する pattern) |
| Sub-project 1-4-3 learnings 適用 | "Sub-project 1-4-3 learnings 適用" section |

### Type / Property name consistency

- [x] `monitoring` namespace name (= Beyla deploy 対象、Task 1 helmfile.yaml + values.yaml.gotmpl + spec 全箇所): 既存 namespace 活用、新規作成なし
- [x] `default` namespace name (= Beyla discovery target、Task 1 values.yaml.gotmpl + spec): Phase 5-2 nginx deploy 想定 namespace と整合
- [x] `opentelemetry-collector.monitoring.svc.cluster.local:4317` FQDN (= Task 1 values + spec): Phase 4-3 で deploy 済 OTel Collector Service と一致
- [x] `system-cluster-critical` priority class (= Task 1 values priorityClassName): Phase 4-2 ESO / Reloader / 4-3 oauth2-proxy と同 priority
- [x] `release: kube-prometheus-stack` ServiceMonitor label (= Task 1 values、Step 2 で chart-fixed か確認): 1-4-3 ServiceMonitor pattern と整合
- [x] commit subject prefix: `feat(eks):` (= 2 commits)、Sub-project 4a / 4b / 4-1 / 4-2 / 4-3 と整合
- [x] chart name `grafana/beyla` (= Task 1 helmfile.yaml + plan 全箇所): local の repository 設定と整合
