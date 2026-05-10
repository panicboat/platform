# EKS Production OTel-Native Log Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** production cluster の log 収集を `Fluent Bit DaemonSet + OTel Collector Deployment` から `OTel Collector DaemonSet 一本 (chart preset logsCollection + kubernetesAttributes)` に置換し、Loki が `k8s_namespace_name` / `k8s_pod_name` 等の resource label を持つようにする。Application Logs / Error Logs panel が動作するようになる。

**Architecture:** OTel Collector の chart preset (`logsCollection` + `kubernetesAttributes`) で filelog receiver と k8sattributes processor を chart 側に構成させる。production の OTel Collector を Deployment → DaemonSet に切替え、各 node が Beyla traces (OTLP gRPC) と container logs (filelog) を受けて Tempo / Loki に直接 export。Fluent Bit production component は撤去。

**Tech Stack:** OpenTelemetry Collector v0.151.0 (contrib) / Helm chart v0.153.0 (logsCollection + kubernetesAttributes presets) / kustomize / helmfile / Flux v2 / GitOps via SSA / Loki 3.x OTLP ingest

**Working directory:** `.claude/worktrees/eks-otel-native-logs/` (worktree on branch `feat/eks-otel-native-logs`)

**Spec:** `docs/superpowers/specs/2026-05-11-eks-production-otel-native-log-collection-design.md`

---

## File Structure

### Modified

| Path | 変更内容 |
|---|---|
| `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl` | mode: deployment → daemonset、presets 有効化、cluster.name 設定、metrics pipeline 撤去 等の大幅改訂 |
| `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` | hydrate-component が再生成 |
| `kubernetes/manifests/production/kustomization.yaml` | hydrate-index が再生成 (= `./fluent-bit` 行が消える) |
| `kubernetes/README.md` | architecture diagram 2 つ + 役割分離説明 + component list + Sub-project 3 行から Fluent Bit 言及のみ削除 |

### Deleted

| Path | 理由 |
|---|---|
| `kubernetes/components/fluent-bit/production/` (ディレクトリごと) | OTel-native 移行で fluent-bit は production 不要 |
| `kubernetes/manifests/production/fluent-bit/` (ディレクトリごと) | hydrate-index が自動削除 |

### Untouched

- `kubernetes/components/fluent-bit/local/` (local は別 PR で扱う、surgical changes 原則)
- `kubernetes/components/opentelemetry-collector/local/` (同上)
- `kubernetes/components/beyla/production/` (Service DNS endpoint で自動継続)
- `kubernetes/components/{tempo,loki,mimir,prometheus-operator}/production/`
- それ以外すべて

---

## Workflow Overview

このプロジェクトは production cluster の挙動変更を含むため、Flux suspend → ローカル iteration → commit/PR/merge → Flux resume の流れ。

```
Task 1   Flux suspend
   ↓
[ITERATION LOOP]
Task 2-5 ソース編集 + hydrate (4 ファイル系の変更を完成させる)
Task 6   pre-apply cleanup (旧 Deployment + fluent-bit resources を kubectl で削除)
Task 7   local apply (= Flux と同じ field-manager で SSA)
Task 8   verify (Loki labels / Pod state / Tempo 動作確認)
   ↓ (verify 失敗なら controller が Task 2-8 を再実行)
[/ITERATION LOOP]
   ↓
Task 9   git diff inspect + commit
Task 10  push + Draft PR (Task 9 まで完了したら user に merge を依頼)
   ↓ (user が merge)
Task 11  Flux resume + reconcile 確認
```

各 Task は subagent 単独で完結する単位。controller (主) は iteration 判定と Task 順序管理を担当。

---

## Task 1: Flux Kustomization を suspend

**Files:** なし (cluster operation のみ)

**Pre-condition:** main branch に他の作業が merge されていない (= iteration 中の他人 PR 干渉を最小化)

- [ ] **Step 1: Flux Kustomization を suspend**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n flux-system patch kustomization flux-system \
  --type=merge -p '{"spec":{"suspend":true}}'
```

期待出力:
```
kustomization.kustomize.toolkit.fluxcd.io/flux-system patched
```

- [ ] **Step 2: suspend 状態を確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n flux-system get kustomization flux-system \
  -o jsonpath='{.spec.suspend}'
echo
```

期待出力:
```
true
```

`true` 以外なら Step 1 を再実行。

---

## Task 2: opentelemetry-collector の values.yaml.gotmpl を全面改訂

**Files:**
- Modify: `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`

- [ ] **Step 1: 既存ファイルを完全置換**

ファイル全体を以下の内容に置き換える:

```yaml
# OpenTelemetry Collector Configuration for production
# OTel-native log collection: per-node DaemonSet で Beyla traces (OTLP gRPC) と
# container logs (filelog receiver) を 1 collector で集約し Tempo / Loki に export。
# fluent-bit DaemonSet は本構成で撤去し、log 収集も OTel に統合する。

# =============================================================================
# Deployment Mode
# =============================================================================
# Beyla も container log file も per-node のため DaemonSet が自然。1 collector が
# node 内の Beyla トレースと container log を受けて backend に直接 export し、
# cluster 中央 hub を経由しない構成。
mode: daemonset

# =============================================================================
# Image (contrib for filelog receiver / k8sattributes / batch processor)
# =============================================================================
image:
  repository: otel/opentelemetry-collector-contrib
  tag: 0.151.0

# =============================================================================
# Resources (per node)
# =============================================================================
# fluent-bit (cpu 100m / mem 128Mi req) の代替 + Beyla traces forward 分の処理を
# 賄う per-node サイズ。Limits は集約 hub だった旧 Deployment より小さくして per-node
# 分散効果を反映。
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# =============================================================================
# Tolerations (全 node に schedule)
# =============================================================================
# cluster 全 node の logs / traces を確実に収集するため master / 特殊 node の
# taint も全許容 (= fluent-bit と等価)。
tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

# =============================================================================
# Priority Class (観測基盤の前提条件)
# =============================================================================
# CPU 逼迫 node でも preempt 動作で確実に schedule (= fluent-bit と同 priority)。
priorityClassName: system-node-critical

# =============================================================================
# Service Configuration (Beyla / ServiceMonitor の宛先として ClusterIP)
# =============================================================================
service:
  type: ClusterIP

# =============================================================================
# Ports (metrics for ServiceMonitor)
# =============================================================================
# chart README に明記「The metrics port is disabled by default. However you need
# to enable the port in order to use the ServiceMonitor」。
ports:
  metrics:
    enabled: true
    containerPort: 8888
    servicePort: 8888
    protocol: TCP

# =============================================================================
# ServiceMonitor (Prometheus auto-scrape)
# =============================================================================
# chart の serviceMonitor key 名は `extraLabels` (OTel Collector chart 固有)。
# Tempo chart の `additionalLabels`、fluent-bit chart の `selector` とは異なる
# key 名のため注意。
serviceMonitor:
  enabled: true
  extraLabels:
    release: kube-prometheus-stack
  metricsEndpoints:
    - port: metrics
      interval: 15s

# =============================================================================
# Chart Presets (OTel-native log collection の中核)
# =============================================================================
# logsCollection: filelog receiver + hostPath volumes (/var/log/pods,
#                 /var/lib/docker/containers) を chart が自動構成。containerd CRI
#                 format パース + multiline recombine も chart 側で処理する。
# kubernetesAttributes: k8sattributes processor + ClusterRole/Binding を chart が
#                       自動構成。全 pipeline に auto-inject される。
presets:
  logsCollection:
    enabled: true
    # collector 自身の log は除外、self-loop 防止
    includeCollectorLogs: false
    # node 再起動で tail 位置を resume
    storeCheckpoints: true
  kubernetesAttributes:
    enabled: true

# =============================================================================
# Collector Config
# =============================================================================
# chart preset で receivers.filelog / processors.k8sattributes が auto-inject される。
# 本 values では exporters と pipelines の exporter 結線、cluster.name 上書き、
# filelog 初回起動時の backfill 防止 (start_at: end) のみ書く。
config:
  receivers:
    filelog:
      # chart preset の filelog default は start_at: beginning。初回起動で既存 log
      # 全件 backfill が走り Loki に大量 push される問題を避けるため end (= 新規
      # log 行のみ) に override。以降は storeCheckpoints: true で tail 位置を resume。
      start_at: end

  processors:
    resource:
      attributes:
        # cluster identification (Beyla 等の他 source と横断クエリ可能にする)
        - key: cluster.name
          value: eks-production
          action: upsert

  exporters:
    # Tempo exporter: traces を gRPC で push
    otlp_grpc/tempo:
      endpoint: tempo.monitoring.svc.cluster.local:4317
      tls:
        insecure: true
    # Loki OTLP exporter: logs を Loki gateway に OTLP HTTP で push
    # Loki 3.0+ は OTLP HTTP を native ingest、resource attribute を label に変換。
    otlp_http/loki:
      endpoint: http://loki-gateway.monitoring.svc.cluster.local:80/otlp
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters: [otlp_grpc/tempo]
      logs:
        # filelog のみ。fluent-bit が撤去されたため OTLP receiver 経由の log push は不要。
        receivers: [filelog]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters: [otlp_http/loki]
      # production では metrics pipeline 未接続 (Beyla は /metrics 直接 expose)。
      # chart default の debug exporter pipeline を残す意義がないため明示削除。
      metrics: null
```

- [ ] **Step 2: ファイル内容の sanity check**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
grep -E "^mode:|^presets:|cluster.name|metrics: null" kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl
```

期待出力 (4 行):
```
mode: daemonset
presets:
        - key: cluster.name
      metrics: null
```

不足や typo があれば Step 1 を再編集。

---

## Task 3: fluent-bit の production component ディレクトリを削除

**Files:**
- Delete: `kubernetes/components/fluent-bit/production/` (ディレクトリ全体)

- [ ] **Step 1: 削除対象を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
ls -la kubernetes/components/fluent-bit/production/
```

期待出力 (2 ファイル):
```
helmfile.yaml
values.yaml.gotmpl
```

- [ ] **Step 2: ディレクトリごと削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
rm -rf kubernetes/components/fluent-bit/production
```

- [ ] **Step 3: 削除を確認 + local が無傷であることを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
ls kubernetes/components/fluent-bit/   # local だけ残っているはず
test -d kubernetes/components/fluent-bit/production && echo "ERROR: production dir still exists" || echo "OK: production dir removed"
```

期待出力:
```
local
OK: production dir removed
```

`ERROR` が出た場合 Step 2 を再実行。

---

## Task 4: kubernetes/README.md から Fluent Bit 言及を削除 (5 spots)

**Files:**
- Modify: `kubernetes/README.md`

CLAUDE.md Documentation 原則に従い、新たな history (= "PR ... で撤去済" 等) は **追加しない**。Fluent Bit 関連の文字列のみを削る。既存の `Plan N で導入` / `Sub-project N で...` 等の他の historical noise は別 PR (task #10) で対応するため本 PR では touch しない。

- [ ] **Step 1: 1 つ目の architecture diagram (line ~9-72) を編集**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
```

以下の編集を `kubernetes/README.md` に対して行う:

(1) OTelCol 行の表記を `(Deployment)` → `(DaemonSet)` に変更:
```diff
-            OTelCol["OTel Collector<br/>(Deployment)"]
+            OTelCol["OTel Collector<br/>(DaemonSet)"]
```

(2) FluentBit 行を削除:
```diff
-            FluentBit["Fluent Bit<br/>(DaemonSet)"]
```

(3) `%% Logs → Fluent Bit → OTel Collector` セクションの 3 行を 2 行に短縮:
```diff
-    %% Logs → Fluent Bit → OTel Collector
-    App -.->|stdout| FluentBit
-    FluentBit -->|OTLP gRPC| OTelCol
+    %% Logs: OTel Collector が container log file を直接 tail (filelog receiver)
+    App -.->|stdout (file tail)| OTelCol
```

(4) Loki exporter ラベルを更新 (実態は OTLP HTTP):
```diff
-    OTelCol -->|loki exporter logs| Loki
+    OTelCol -->|OTLP HTTP logs| Loki
```

- [ ] **Step 2: 役割分離の説明文 (line ~80) を編集**

```diff
-**Application Telemetry Funnel** (Beyla + Fluent Bit + OTel Collector): application code の trace / log / metric を集約する。OTel Collector を hub として全 signal が統一 metadata processor を通り、Tempo / Loki / Mimir へ route。
+**Application Telemetry Funnel** (Beyla + OTel Collector): application code の trace / log / metric を集約する。OTel Collector を per-node DaemonSet として deploy し、Beyla からの traces (OTLP) と container log file (filelog receiver) を 1 箇所で受けて Tempo / Loki に route。
```

- [ ] **Step 3: 2 つ目の Dataflow diagram (line ~89-126) を編集**

(1) `Funnel` subgraph から `FB["Fluent Bit"]` 行を削除:
```diff
     subgraph Funnel["Application Telemetry Funnel"]
-        FB["Fluent Bit"]
         OTel["OTel Collector"]
     end
```

(2) `L -->|stdout| FB` と `FB -->|OTLP gRPC| OTel` を `L -.->|file tail| OTel` に置換:
```diff
     B -->|OTLP traces+metrics| OTel
-    L -->|stdout| FB
-    FB -->|OTLP gRPC| OTel
+    L -.->|file tail| OTel
```

(3) Loki exporter ラベル更新:
```diff
-    OTel -->|loki exporter logs| LO
+    OTel -->|OTLP HTTP logs| LO
```

- [ ] **Step 4: 監視スタック component list (line ~232) を編集**

```diff
 - **Tempo**: 分散トレーシングバックエンド
-- **Fluent Bit**: ログ収集
-- **OpenTelemetry Collector**: テレメトリ統合
+- **OpenTelemetry Collector**: テレメトリ統合 (traces / logs を per-node DaemonSet で集約)
 - **Beyla**: eBPF自動計装
```

- [ ] **Step 5: Sub-project 3 名前空間共有説明 (line ~374) を編集**

`+ Fluent Bit` の文字列のみを削除する (既存の Sub-project N 表記は触らない、他の historical noise は task #10 で別 PR cleanup):

```diff
-| 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Phase 3 全 sub-projects 共有。Sub-project 3 (Loki + Fluent Bit) / Sub-project 4 (Tempo + OpenTelemetry + Beyla + Hubble OTLP) も同 namespace を利用予定だが、各々別 spec で扱う |
+| 共有 namespace | `monitoring` (= `kubernetes/components/prometheus-operator/namespace.yaml` で定義) | Phase 3 全 sub-projects 共有。Sub-project 3 (Loki) / Sub-project 4 (Tempo + OpenTelemetry + Beyla + Hubble OTLP) も同 namespace を利用予定だが、各々別 spec で扱う |
```

- [ ] **Step 6: 全 5 spot の編集確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
echo "=== Fluent Bit / FluentBit 関連の言及残存 (production architecture 内) ==="
grep -n -E "FluentBit|Fluent Bit|loki exporter" kubernetes/README.md
echo "=== '(Deployment)' 残存 (OTelCol が DaemonSet になっているか) ==="
grep -n "OTel Collector.*Deployment" kubernetes/README.md
```

期待出力:
- 1 行目: `0 行` (Fluent Bit / FluentBit / loki exporter の言及が無い)
- 2 行目: `0 行`

何か残っていれば Step 1-5 のうち該当箇所を再編集。

---

## Task 5: hydrate-component + hydrate-index を実行

**Files:**
- Auto-generated: `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` (再生成)
- Auto-generated: `kubernetes/manifests/production/kustomization.yaml` (再生成)
- Auto-deleted: `kubernetes/manifests/production/fluent-bit/` (ディレクトリごと)

- [ ] **Step 1: opentelemetry-collector を hydrate**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
make -C kubernetes hydrate-component COMPONENT=opentelemetry-collector ENV=production
```

期待: エラーなく終了。`kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` が更新される。

- [ ] **Step 2: hydrate-index で root kustomization と orphan ディレクトリ削除を実行**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
make -C kubernetes hydrate-index ENV=production
```

期待: エラーなく終了。`manifests/production/fluent-bit/` が自動削除され、`manifests/production/kustomization.yaml` の resources リストから `./fluent-bit` 行が消える。

- [ ] **Step 3: hydrate 結果を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
echo "=== fluent-bit が manifests から消えたか ==="
test -d kubernetes/manifests/production/fluent-bit && echo "ERROR: dir still exists" || echo "OK: removed"
grep -q "fluent-bit" kubernetes/manifests/production/kustomization.yaml \
  && echo "ERROR: still referenced" || echo "OK: no fluent-bit reference in kustomization"
echo "=== opentelemetry-collector の manifest が DaemonSet に変わったか ==="
echo -n "DaemonSet count: "; grep -c "^kind: DaemonSet" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
echo -n "Deployment count: "; grep -c "^kind: Deployment" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
echo "=== filelog receiver が含まれているか ==="
echo -n "start_at: end count: "; grep -c "start_at: end" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
echo "=== cluster.name が含まれているか ==="
echo -n "eks-production count: "; grep -c "value: eks-production" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml
```

期待出力:
```
=== fluent-bit が manifests から消えたか ===
OK: removed
OK: no fluent-bit reference in kustomization
=== opentelemetry-collector の manifest が DaemonSet に変わったか ===
DaemonSet count: 1
Deployment count: 0
=== filelog receiver が含まれているか ===
start_at: end count: 1
=== cluster.name が含まれているか ===
eks-production count: 1
```

`ERROR` や count 不一致があれば Task 2 / Task 3 / Task 5-1 / Task 5-2 を見直す。

---

## Task 6: cluster 上の旧リソースを cleanup

`kubectl apply -k` は prune しないので、旧 Deployment と fluent-bit 関連リソースを手動削除する。これは Task 7 の apply 前に実行する必要がある (= 削除しないと旧 Deployment が新 DaemonSet と並走して Pod が cluster の resource を圧迫する)。

**Files:** なし (cluster operation)

- [ ] **Step 1: 削除対象を事前確認 (= dry-run 的に状態把握)**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
echo "=== 旧 OTel Collector Deployment ==="
kubectl -n monitoring get deployment opentelemetry-collector -o name 2>&1 || echo "(unrelated error)"
echo
echo "=== Fluent Bit 関連リソース ==="
kubectl -n monitoring get all,sa,cm,clusterrole,clusterrolebinding \
  -l app.kubernetes.io/instance=fluent-bit 2>&1 | head -20
```

何が出るか controller が把握してから次の step へ。

- [ ] **Step 2: 旧 OTel Collector Deployment を削除**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring delete deployment opentelemetry-collector --ignore-not-found
```

期待出力:
```
deployment.apps "opentelemetry-collector" deleted
```

または既に削除済みなら空出力。

- [ ] **Step 3: Fluent Bit 関連リソースを label で一括削除**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring delete daemonset,sa,cm,svc,servicemonitor \
  -l app.kubernetes.io/instance=fluent-bit --ignore-not-found
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/instance=fluent-bit --ignore-not-found
```

期待: 該当リソースが削除される。既に存在しないものは `--ignore-not-found` で skip される。

- [ ] **Step 4: 削除後の状態確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
echo "=== 旧 Deployment が消えたか ==="
kubectl -n monitoring get deployment opentelemetry-collector 2>&1 | head
echo
echo "=== Fluent Bit Pod がいないか ==="
kubectl -n monitoring get pods -l app.kubernetes.io/instance=fluent-bit 2>&1 | head
```

期待出力:
```
=== 旧 Deployment が消えたか ===
Error from server (NotFound): deployments.apps "opentelemetry-collector" not found

=== Fluent Bit Pod がいないか ===
No resources found in monitoring namespace.
```

NotFound / No resources 以外が出たら Step 2-3 を再実行。

---

## Task 7: ローカルから kubectl SSA で apply

**Files:** なし (cluster operation)

Flux と同じ field-manager (`kustomize-controller`) で server-side apply する。これにより Flux resume 時の SSA conflict warning を予防する。

- [ ] **Step 1: production 全体を server-side apply**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
kubectl apply --server-side --force-conflicts \
  --field-manager=kustomize-controller \
  -k kubernetes/manifests/production 2>&1 | tail -30
```

期待: 多数のリソースが `serverside-applied` で報告される、エラーなし。OTel Collector 関連 Resource が新 DaemonSet として作成される、Fluent Bit 関連リソースは既に Task 6 で削除済のためここで何もしない。

- [ ] **Step 2: DaemonSet が schedule されているか確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring get daemonset opentelemetry-collector -o wide
kubectl -n monitoring get pods -l app.kubernetes.io/component=agent -o wide
```

期待: DaemonSet の DESIRED / CURRENT / READY が cluster の node 数 (5) と一致するか、起動中。Pod 一覧に node 数分 (5) の opentelemetry-collector pods が表示される。

DESIRED が 0 など想定外の場合は manifest 内容を確認 (Task 5-3 の検証に戻る)。

- [ ] **Step 3: Pod が Running になるまで待機**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=agent --timeout=120s
```

期待出力 (5 行 = 5 pods):
```
pod/opentelemetry-collector-XXXXX condition met
pod/opentelemetry-collector-XXXXX condition met
pod/opentelemetry-collector-XXXXX condition met
pod/opentelemetry-collector-XXXXX condition met
pod/opentelemetry-collector-XXXXX condition met
```

timeout する場合は Pod の log を確認:
```bash
kubectl -n monitoring logs daemonset/opentelemetry-collector --tail=80
```

エラーがあれば Task 2 (values.yaml.gotmpl) を見直す。

---

## Task 8: 検証 — Loki labels / Grafana panel が動くか

**Files:** なし (verification only)

- [ ] **Step 1: Loki に新 label が来ているか**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring run tmp-loki-labels --rm -i --restart=Never \
  --image=curlimages/curl --quiet -- \
  curl -s -H 'X-Scope-OrgID: anonymous' \
  http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/labels
```

期待出力 (= 旧の `service_name`/`__stream_shard__` のみ から拡充):
```json
{"status":"success","data":["__stream_shard__","k8s_container_name","k8s_deployment_name","k8s_namespace_name","k8s_node_name","k8s_pod_name","service_name", ...]}
```

最低限 `k8s_namespace_name` と `k8s_pod_name` が含まれていれば成功。**含まれていない場合**は controller が原因を判別:
- pod log にエラー: Task 7 の Step 3 で見た log を再確認
- start_at: end が効いていない可能性: `kubectl -n monitoring describe pod -l app.kubernetes.io/component=agent` で `START_AT` 環境変数を確認
- Loki 側の OTLP indexing 設定: Loki の OTLP `default_resource_attributes_as_index_labels` が default のままか確認

NOTE: `cluster.name` は Loki 3.x default attribute-to-label mapping に含まれない (= `k8s.cluster.name` 等の k8s.* 系のみが default で label 化)。本 PR で resource processor が `cluster.name=eks-production` を set してもこれが label として現れるとは限らない (= structured metadata に落ちる可能性)。実害はないが、`cluster_name` label が必要なら別 PR で `k8s.cluster.name` に名前変更を検討。

- [ ] **Step 2: 実際の log を 1 件取得して label 内容を確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
NOW=$(date +%s)000000000
START=$(($(date +%s) - 60))000000000
kubectl -n monitoring run tmp-loki-q --rm -i --restart=Never \
  --image=curlimages/curl --quiet -- \
  curl -s -H 'X-Scope-OrgID: anonymous' \
  "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/query_range?query=%7Bk8s_namespace_name%3D%22monitoring%22%7D&limit=1&start=${START}&end=${NOW}&direction=BACKWARD" \
  | head -c 800
```

期待: `data.result[0].stream` に `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name` などが入った JSON、`values` に log 行 1 件。

- [ ] **Step 3: Tempo の Trace Search Results が引き続き動くか (= regression なし確認)**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring run tmp-tempo-tags --rm -i --restart=Never \
  --image=curlimages/curl --quiet -- \
  curl -s 'http://tempo.monitoring.svc.cluster.local:3200/api/search/tags' | head -c 500
```

期待: `tagNames` に `k8s.namespace.name`, `k8s.pod.name`, `service.name` 等が含まれる (= Beyla → Tempo の path が引き続き動作)。

- [ ] **Step 4: Grafana UI で目視確認** (controller がユーザに依頼)

ユーザに依頼: https://grafana.panicboat.net で以下を確認してもらう

| Panel | 期待 |
|---|---|
| Application Logs (Application Monitoring / Unified Monitoring) | log 行が出る (= 1-3 でも確認したが UI 側で実際に namespace/pod 選択して見える) |
| Error Logs (Infrastructure Monitoring) | エラーログが出る |
| Trace Search Results | trace が引き続き出る (= regression なし) |
| Container Restarts / CPU / Memory panel | 値が引き続き出る (= 関係ないので無傷のはず) |

NG が出れば controller が原因を判別し Task 2-7 を再 iterate。

---

## (Iteration Decision Point)

Task 1-8 までで verify が pass すれば commit へ進む。NG であれば controller が原因に応じて以下を再実行:

- values.yaml.gotmpl の修正 → Task 2 から再実行
- README の typo → Task 4 のみ修正
- cluster の状態が壊れた → Task 6 で cleanup してから Task 7 再 apply

何度 iterate しても OK。最終形が定まるまで commit しない。

---

## Task 9: git diff inspect + commit

**Files:** すべて (Tasks 2-5 で作成・修正されたもの)

- [ ] **Step 1: git status で変更全量を一覧**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git status
```

期待: 以下のファイルが modified/deleted/untracked のいずれかとして表示される:
- modified: `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`
- modified: `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml`
- modified: `kubernetes/manifests/production/kustomization.yaml`
- modified: `kubernetes/README.md`
- deleted: `kubernetes/components/fluent-bit/production/helmfile.yaml`
- deleted: `kubernetes/components/fluent-bit/production/values.yaml.gotmpl`
- deleted: `kubernetes/manifests/production/fluent-bit/kustomization.yaml`
- deleted: `kubernetes/manifests/production/fluent-bit/manifest.yaml`

それ以外のファイル (= 関係ないコンポーネント、local 側 等) が含まれていれば Task 1-5 のどこかで誤改変。差し戻し。

- [ ] **Step 2: README の意図通りの差分を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git diff kubernetes/README.md | head -80
```

期待: Fluent Bit / FluentBit / Deployment 言及の削除と OTLP HTTP / DaemonSet への置換のみ、他の historical commentary は無修正。

- [ ] **Step 3: 全変更を stage**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git add kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl \
        kubernetes/components/fluent-bit/production \
        kubernetes/manifests/production/opentelemetry-collector \
        kubernetes/manifests/production/fluent-bit \
        kubernetes/manifests/production/kustomization.yaml \
        kubernetes/README.md
git status
```

期待: 上記 8 ファイル分が staged 状態。untracked / modified なし。

- [ ] **Step 4: signoff 付きで commit (Co-Authored-By 禁止)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git commit -s -m "feat(eks): otel-native log collection (replace fluent-bit)

production の log 収集を Fluent Bit DaemonSet + OTel Collector Deployment
の二段から、OTel Collector DaemonSet 一本に置換する。chart preset
logsCollection + kubernetesAttributes で filelog receiver と k8sattributes
processor を chart 側に構成させ、Loki に k8s_namespace_name / k8s_pod_name
等の resource label が付与されるようにする。Application Logs panel が動作
するようになる (= PR #331 残留問題のうち logs 系を解消)。

主な変更:
- opentelemetry-collector/production: mode daemonset 化、presets 有効化、
  cluster.name=eks-production 追加、metrics pipeline 撤去、filelog
  start_at: end 上書き
- fluent-bit/production: component ディレクトリ撤去
- kubernetes/README.md: production architecture diagram / 役割分離 / Dataflow /
  component list / Sub-project 3 説明から Fluent Bit 言及のみ削除
  (= CLAUDE.md Documentation 原則: 既存 historical noise は別 PR で扱う)

Migration: Flux suspend → ローカル kubectl SSA で iterate verify 済。
詳細は spec を参照。

Spec: docs/superpowers/specs/2026-05-11-eks-production-otel-native-log-collection-design.md"
```

- [ ] **Step 5: commit footer を検証**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git log -1 --format=%B | tail -3
```

期待:
```
Spec: docs/superpowers/specs/2026-05-11-eks-production-otel-native-log-collection-design.md

Signed-off-by: <git user.name> <git user.email>
```

`Co-Authored-By` 行が無いことを確認。

---

## Task 10: branch を push して Draft PR を作成

**Files:** なし (git remote 操作のみ)

- [ ] **Step 1: branch を upstream tracking 付きで push**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
git push -u origin HEAD
```

期待: branch `feat/eks-otel-native-logs` が origin に push される。

- [ ] **Step 2: Draft PR を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
gh pr create --draft \
  --base main \
  --title "feat(eks): otel-native log collection (replace fluent-bit)" \
  --body "$(cat <<'EOF'
## Summary

production の log 収集を **Fluent Bit DaemonSet + OTel Collector Deployment** の二段から、**OTel Collector DaemonSet 一本** (chart preset `logsCollection` + `kubernetesAttributes`) に置換する。これにより Loki に `k8s_namespace_name` / `k8s_pod_name` 等の resource label が付与され、PR #331 で deploy した dashboard の Application Logs / Error Logs panel が動作するようになる。

## Why

PR #331 (production grafana dashboards) merge 後の検証で、Application Logs panel が空のまま残った。systematic-debugging で kubectl 経由で実測した結果:

- Loki labels: `__stream_shard__` と `service_name` (= 全部 `unknown_service`) のみ
- 原因: production OTel Collector の logs pipeline に Fluent Bit の nested k8s attribute を OTel resource attribute に昇格する処理 (`transform/logs` 等) が無く、Loki OTLP ingest が k8s metadata を label 化できない

Fluent Bit 経路を維持して `transform/logs` を足す案 (= local pattern の移植) と、OTel Collector に統合する OTel-native 案を比較し、後者を選択。理由は OTel community の標準パターン、構成シンプル化、Fluent Bit 撤去で operator 数削減。

## Changes

- `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`: mode daemonset、presets 有効化、cluster.name=eks-production、metrics pipeline 撤去、filelog start_at: end
- `kubernetes/components/fluent-bit/production/`: ディレクトリごと撤去
- `kubernetes/manifests/production/{opentelemetry-collector,kustomization.yaml,fluent-bit}`: hydrate-component / hydrate-index で自動更新 / 削除
- `kubernetes/README.md`: production architecture 記述箇所 5 spot から Fluent Bit 言及のみ削除 (新たな history は追加せず)

## Verification (deploy 前にローカル iteration で済)

Flux Kustomization を suspend してローカルから kubectl SSA で apply、以下を確認:

1. ✅ OTel Collector DaemonSet が全 5 node で Running
2. ✅ Loki labels に `k8s_namespace_name` / `k8s_pod_name` / `k8s_container_name` / `cluster_name` 等が出現
3. ✅ Sample log の stream に namespace / pod / container 名が入る
4. ✅ Tempo の Trace Search Results が引き続き動作 (= regression なし)
5. ✅ Grafana UI: Application Logs / Error Logs panel に log が出る
6. ✅ 旧 Fluent Bit 関連リソースが cluster から消えている

## Out of Scope

- local OTel Collector の OTel-native 化 (別 PR、当面 local は Fluent Bit 維持)
- Tempo metrics-generator 有効化 + Service Graph 復活 (PR-B 別途)
- Loki の low-cardinality 化 (production scale が顕在化したら別 PR)
- README の broader historical noise cleanup (= "Plan N で導入" 等、別 PR で全面 cleanup)

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-11-eks-production-otel-native-log-collection-design.md`
- Plan: `docs/superpowers/plans/2026-05-11-eks-production-otel-native-log-collection.md`
EOF
)"
```

期待: PR URL が返る。Draft 状態。

- [ ] **Step 3: PR 作成を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-otel-native-logs
gh pr view --json number,title,isDraft,baseRefName,headRefName
```

期待出力:
```json
{
  "number": <N>,
  "title": "feat(eks): otel-native log collection (replace fluent-bit)",
  "isDraft": true,
  "baseRefName": "main",
  "headRefName": "feat/eks-otel-native-logs"
}
```

- [ ] **Step 4: ユーザに merge を依頼**

controller が user に「PR #N を確認して問題なければ merge してください」と通知する。merge 完了の確認を user から受け取るまで Task 11 に進まない。

---

## Task 11: merge 後の Flux resume + reconcile 確認

**Files:** なし (cluster operation)

**Pre-condition:** user から PR merge 完了の通知を受けた

- [ ] **Step 1: main を pull して merge を local にも反映**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git checkout main
git pull --ff-only origin main
git log --oneline -3
```

期待: 最新 commit が `feat(eks): otel-native log collection ... (#N)` で main の HEAD。

- [ ] **Step 2: Flux Kustomization を resume**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n flux-system patch kustomization flux-system \
  --type=merge -p '{"spec":{"suspend":false}}'
```

期待出力:
```
kustomization.kustomize.toolkit.fluxcd.io/flux-system patched
```

- [ ] **Step 3: 即時 reconcile を trigger**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n flux-system annotate kustomization flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -u +%FT%TZ)" --overwrite
```

期待出力 (annotation 付与):
```
kustomization.kustomize.toolkit.fluxcd.io/flux-system annotated
```

- [ ] **Step 4: Flux が新 revision を Applied するまで待機**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
for i in 1 2 3 4 5 6; do
  kubectl -n flux-system get kustomization flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
  echo
  sleep 10
done
```

期待: いずれかの行で `Applied revision: main@sha1:<merge-commit-sha>` と表示される。

タイムアウトする場合は Flux controller log を確認:
```bash
kubectl -n flux-system logs deployment/kustomize-controller --tail=50
```

- [ ] **Step 5: cluster 状態が manifest と drift なく一致しているか**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring get daemonset opentelemetry-collector -o jsonpath='{.spec.template.spec.containers[0].image}'
echo
kubectl -n monitoring get pods -l app.kubernetes.io/instance=fluent-bit 2>&1 | head
echo
kubectl -n flux-system get kustomization flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo
```

期待出力:
```
otel/opentelemetry-collector-contrib:0.151.0
No resources found in monitoring namespace.
True
```

(= OTel DaemonSet 動作中 / Fluent Bit Pod 不在 / Flux Ready=True)

- [ ] **Step 6: worktree cleanup**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/eks-otel-native-logs
git branch -D feat/eks-otel-native-logs
git worktree prune
```

期待: worktree が削除され、squash merge で SHA が変わった branch を `-D` で force delete。
