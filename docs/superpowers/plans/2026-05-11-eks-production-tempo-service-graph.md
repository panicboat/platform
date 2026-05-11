# EKS Production Tempo Metrics-Generator + Service Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** production の Tempo に metrics-generator を有効化し、`service-graphs` processor が生成する pairwise service edge metrics を Mimir に remote-write、Grafana Tempo datasource の `serviceMap` で Service Graph panel を動かす。

**Architecture:** Tempo monolithic (chart v1.24.4) の `metricsGenerator` ブロックを `enabled: true` に切替え、`service_graphs` processor のみ enable、Mimir gateway に Prometheus remote_write protocol で push する。tenant header (`X-Scope-OrgID: anonymous`) と external label `cluster=eks-production` を付与する。Grafana datasource は `serviceMap.datasourceUid: mimir` を追加して Service Graph panel が裏で Mimir に PromQL を投げられるようにする。

**Tech Stack:** Tempo helm chart v1.24.4 (monolithic mode) / Tempo 2.6.1 metrics-generator / Mimir distributed v6.0.6 / kube-prometheus-stack Grafana datasource provisioning / Mermaid diagram in README / kustomize / helmfile / Flux v2

**Working directory:** `.claude/worktrees/feat-tempo-service-graph/` (worktree on branch `feat/eks-production-tempo-service-graph`)

**Spec:** `docs/superpowers/specs/2026-05-11-eks-production-tempo-service-graph-design.md`

---

## File Structure

### Modified

| Path | 変更内容 |
|---|---|
| `kubernetes/components/tempo/production/values.yaml.gotmpl` | `metricsGenerator` ブロックを `enabled: false` から full config に置換、`overrides` ブロック新規追加 |
| `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` | Tempo datasource の `jsonData` に `serviceMap.datasourceUid: mimir` を追加 |
| `kubernetes/manifests/production/tempo/manifest.yaml` | `make hydrate-component COMPONENT=tempo ENV=production` で再生成 |
| `kubernetes/manifests/production/prometheus-operator/manifest.yaml` | `make hydrate-component COMPONENT=prometheus-operator ENV=production` で再生成 |
| `kubernetes/README.md` | Main architecture diagram に `Tempo --> Mimir` 矢印追加 + visualization 矢印 3 本反転、Dataflow diagram に同様の変更、Dataflow の後に新規 "Backend role separation" section 挿入 |

### Untouched

- `kubernetes/components/tempo/local/` (= 別 PR、surgical changes 原則)
- `kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json` (= datasource 側設定で自動動作)
- `kubernetes/components/mimir/production/` (= 既存 multi-tenant `anonymous` で受信可能、無変更)
- それ以外すべて

---

## Workflow Overview

PR-A と同じ Flux suspend → local iteration → commit/PR/merge → Flux resume の流れ:

```
Task 1   Flux suspend
   ↓
[ITERATION LOOP]
Task 2   Pre-flight: chart values schema を確認 (remoteWriteHeaders field 名)
Task 3-5 source 編集 (Tempo values / prometheus-operator values / README)
Task 6   hydrate を実行 (manifest 再生成)
Task 7   hydrated manifests を検査 (期待 chart output 確認)
Task 8   Tempo manifest を SSA apply → metrics-generator 起動確認
Task 9   prometheus-operator manifest を SSA apply → Grafana datasource reload 確認
Task 10  End-to-end verify (Mimir metrics + Service Graph panel)
   ↓ (verify 失敗なら controller が Task 3-10 を再実行)
[/ITERATION LOOP]
   ↓
Task 11  git diff inspect + commit
Task 12  push + Draft PR (user が merge)
   ↓ (user が merge)
Task 13  Flux resume + reconcile 確認 + worktree cleanup
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

## Task 2: Tempo chart values schema を確認

**Files:** なし (調査のみ)

**目的:** spec の open question — chart v1.24.4 の `metricsGenerator.remoteWriteHeaders` field 名と `persistentVolume` の有無を実物で確認する。

- [ ] **Step 1: chart の default values を取得して metricsGenerator セクションを抽出**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana
helm show values grafana/tempo --version 1.24.4 \
  | awk '/^metricsGenerator:/,/^[a-zA-Z]/' \
  | head -60
```

期待: `metricsGenerator:` section の YAML が出力される。下記 field が含まれていること:
- `enabled:` (bool)
- `remoteWriteUrl:` (string)
- `remoteWriteHeaders:` (map) ← この field 名で渡せるか確認
- `registry:` (object、external_labels 含む)
- `processor:` (object、service_graphs / span_metrics 含む)
- `persistentVolume:` (object、size / storageClass 含む) ← WAL 用 PVC 構成可否

- [ ] **Step 2: 結果を記録 (口頭または scratchpad)**

確認すべき 3 点:
1. `remoteWriteHeaders` field 名 (snake_case `remote_write_headers` の可能性も検証)
2. `persistentVolume` の field 名と必須性 (= `enabled: true/false` でデフォルト無効か)
3. `overrides` field の chart 側 schema (`overrides.defaults.metrics_generator.processors` を expose しているか、または `tempo.overrides` で生 yaml 渡すか)

field 名差異がある場合は Task 3 の Tempo values 改訂で吸収する。chart 側で expose されていない field は `tempo.config` (生 YAML override) で渡す fallback も視野。

- [ ] **Step 3: overrides の取扱を確認 (chart の generated config を覗く)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
helm show values grafana/tempo --version 1.24.4 \
  | grep -A 5 "^overrides:\|^tempo:" \
  | head -30
```

期待: 以下のいずれかが見える
- `tempo.metricsGenerator.processor` が monolithic config に直接展開される pattern
- top-level `overrides:` セクションを chart が `overrides.yaml` として ConfigMap 化する pattern

実装段階で必要なら `helm template grafana/tempo --version 1.24.4 -f kubernetes/components/tempo/production/values.yaml.gotmpl` を局所実行して生成内容を確認する選択肢もある。

---

## Task 3: Tempo values.yaml.gotmpl を改訂

**Files:**
- Modify: `kubernetes/components/tempo/production/values.yaml.gotmpl`

- [ ] **Step 1: `metricsGenerator` ブロックを enabled: true 側に置換**

`kubernetes/components/tempo/production/values.yaml.gotmpl` の以下のセクションを編集する。

before (現在の L56-60 付近):

```yaml
  # -------------------------------------------------------------------------
  # Metrics generator は OFF (= advanced features、Phase 4 で再検討)
  # -------------------------------------------------------------------------
  metricsGenerator:
    enabled: false
```

after:

```yaml
  # -------------------------------------------------------------------------
  # Metrics generator
  # =============================================================================
  # service_graphs processor のみ enable し、生成される traces_service_graph_*
  # を Mimir に remote_write する。Beyla が既に http_server_* で RED metrics を
  # 出しているため span_metrics は併走させない (cardinality 二重持ち回避)。
  # tenant header (X-Scope-OrgID: anonymous) は既存 Prometheus remote_write と同値。
  # external_labels.cluster は multi-cluster 集約時の expectation に備えて付与。
  # -------------------------------------------------------------------------
  metricsGenerator:
    enabled: true
    remoteWriteUrl: http://mimir-distributed-gateway.monitoring.svc.cluster.local/api/v1/push
    remoteWriteHeaders:
      X-Scope-OrgID: anonymous
    registry:
      external_labels:
        cluster: eks-production
    processor:
      service_graphs:
        wait: 10s
        max_items: 10000

  # -------------------------------------------------------------------------
  # Overrides (multitenancy OFF でも processor を起動させるために必要)
  # -------------------------------------------------------------------------
  # Tempo の仕様: per-tenant `metrics_generator.processors` が空だと processor は
  # 起動しない。multitenancy OFF (1 tenant anonymous) でも `defaults` 経由で明示
  # 列挙が必要。
  overrides:
    defaults:
      metrics_generator:
        processors:
          - service-graphs
```

(Task 2 で `remoteWriteHeaders` field 名が異なる結果が出た場合: 確認した chart field 名に合わせて修正、または fallback で `tempo.config` 直書きする。同様に `overrides` の field 名も chart の expose 方法に合わせる)

- [ ] **Step 2: ファイル差分を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git diff kubernetes/components/tempo/production/values.yaml.gotmpl
```

期待:
- `metricsGenerator:` ブロック内が `enabled: false` から複数 field 構成に変わっている
- `overrides:` ブロックが新規追加されている
- 他ブロック (storage / persistence / serviceAccount 等) は無変更

---

## Task 4: prometheus-operator values.yaml.gotmpl の Tempo datasource に serviceMap を追加

**Files:**
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`

- [ ] **Step 1: Tempo datasource の jsonData に serviceMap.datasourceUid を追加**

L115-128 付近の Tempo datasource ブロック内 `jsonData:` を編集する。

before:

```yaml
        # Phase 3 Sub-project 4a (Traces stack foundation)
        - name: Tempo
          uid: tempo
          type: tempo
          url: http://tempo.monitoring.svc.cluster.local:3200
          access: proxy
          isDefault: false
          jsonData:
            # 1 tenant 運用 (= Decision 8、multitenancy OFF)
            httpMethod: GET
            tracesToLogsV2:
              datasourceUid: loki
            tracesToMetrics:
              datasourceUid: mimir
```

after:

```yaml
        # Phase 3 Sub-project 4a (Traces stack foundation)
        - name: Tempo
          uid: tempo
          type: tempo
          url: http://tempo.monitoring.svc.cluster.local:3200
          access: proxy
          isDefault: false
          jsonData:
            # 1 tenant 運用 (= Decision 8、multitenancy OFF)
            httpMethod: GET
            tracesToLogsV2:
              datasourceUid: loki
            tracesToMetrics:
              datasourceUid: mimir
            # Service Graph panel: Tempo metrics-generator が remote_write した
            # traces_service_graph_* metrics を Mimir 経由で query する
            serviceMap:
              datasourceUid: mimir
```

- [ ] **Step 2: ファイル差分を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git diff kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
```

期待: `tracesToMetrics` ブロックの後に `serviceMap` ブロックが 2 行追加されている。それ以外無変更。

---

## Task 5: kubernetes/README.md を改訂

**Files:**
- Modify: `kubernetes/README.md`

3 spot の編集:
- 5-1: Main architecture diagram (L9-70) に Tempo→Mimir 矢印 + visualization 矢印反転
- 5-2: Dataflow diagram (L87-122) に同様の変更
- 5-3: Dataflow の後 / セットアップの前に新規 "Backend role separation" section 挿入

- [ ] **Step 1: Main architecture diagram の visualization セクションを書き換える**

L60-70 付近の以下を:

```mermaid
    %% Long-term storage
    Mimir --> S3Mimir
    Tempo --> S3Tempo
    Loki --> S3Loki

    %% Visualization
    Mimir --> Grafana
    Tempo --> Grafana
    Loki --> Grafana
```

以下に置き換える:

```mermaid
    %% Long-term storage
    Mimir --> S3Mimir
    Tempo --> S3Tempo
    Loki --> S3Loki

    %% Tempo metrics-generator → Mimir (service-graph metrics)
    Tempo -->|remote_write<br/>traces_service_graph_*| Mimir

    %% Visualization
    Grafana -.-> Mimir
    Grafana -.-> Tempo
    Grafana -.-> Loki
```

- [ ] **Step 2: Dataflow diagram (L87-122) の visualization セクションを書き換える**

L115-121 付近の以下を:

```mermaid
    OTel -.->|self-metrics scraped| P
    OTel -->|OTLP| T
    OTel -->|OTLP HTTP logs| LO

    P --> Grafana
    T --> Grafana
    LO --> Grafana
```

以下に置き換える:

```mermaid
    OTel -.->|self-metrics scraped| P
    OTel -->|OTLP| T
    OTel -->|OTLP HTTP logs| LO

    T -->|remote_write<br/>traces_service_graph_*| P

    Grafana -.-> P
    Grafana -.-> T
    Grafana -.-> LO
```

- [ ] **Step 3: Dataflow diagram (Mermaid 閉じタグ ` ``` ` の直後) と「🚀 セットアップ」section の間に新規 section を挿入**

挿入位置: L122 (` ``` ` で Dataflow Mermaid block が閉じる行) と L124 (`## 🚀 セットアップ`) の間。

挿入する内容:

````markdown
### Backend role separation

3 つの telemetry backend (Mimir / Tempo / Loki) と短期 buffer の Prometheus は、signal type ごとに役割を分離して並走させる。

| Component | Signal | Mode | Backing store | Retention | Receives |
|---|---|---|---|---|---|
| Prometheus (kube-prometheus-stack) | metrics | scraper + 短期 buffer | local PVC (gp3 EBS) | 24h | ServiceMonitor / PodMonitor から active scrape |
| Mimir (mimir-distributed) | metrics | passive store + query gateway | S3 (`mimir-…`) | 90d | Prometheus からの `remote_write` (+ Tempo metrics-generator) |
| Tempo (monolithic) | traces | trace ingest + metrics-generator | S3 (`tempo-…`) | 7d | OTel Collector からの OTLP traces |
| Loki (SingleBinary) | logs | log ingest | S3 (`loki-…`) | 30d | OTel Collector からの OTLP logs |

**Prometheus と Mimir で metrics を 2 段に分ける理由:**

Prometheus は cluster 内の active scraper で ServiceMonitor / PodMonitor から metrics を pull する責務。disk 制約から retention は 24h と短い。Mimir は Prometheus が `remote_write` で送ってくる metrics を S3 に堆積する passive store で、長期保存 (90d) と Grafana への query 提供が役割。短期 scrape と長期 store を分離して、両者の retention / capacity を独立に運用する。

Prometheus を agent mode で動かす alternative もあるが、Alertmanager / Prometheus Operator CRD が必要なため full Prometheus を維持している。

**Tempo metrics-generator の delegation pattern:**

Tempo は trace を S3 に保管する primary role に加え、metrics-generator が trace を集計して service-graph metrics を生成する。Tempo は PromQL を喋らないため、生成された metrics は metrics 専門の Mimir に `remote_write` で委譲する。Grafana の Service Graph panel は Tempo datasource を経由しつつ、裏で Mimir に PromQL クエリを投げる構造 (Tempo datasource の `serviceMap.datasourceUid` で Mimir を指定)。

Tempo は「自分の trace を集計した metrics を、metrics 専門の Mimir に委ねる」role separation を取る。

**S3 を共通 backing store にする理由:**

3 backend (Mimir / Tempo / Loki) が ingest / index / query を担う本体で、S3 は **それぞれの永続化層** に位置づく。S3 単独では telemetry data の format (= TSDB block / trace block / chunk + index) を解釈できないため、データ access は必ず backend を経由する (= S3 にデータが先にあって backend がそれを読みに行く、という関係ではない)。

production で S3 を選ぶのは scale 要件の一致による:
- **durability**: Pod 削除でデータが失われない (EBS は AZ-local、Pod 横断 attach 不可)
- **retention**: 7d-90d の長期保管
- **cost**: 数十 GB-数百 GB を EBS で持つより S3 が安価
- **elastic**: backend pod の replica 数変更で storage rebalance 不要

local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)、production-specific な storage choice。

````

- [ ] **Step 4: 編集差分を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git diff kubernetes/README.md
```

期待:
- Main architecture diagram に 2 ブロック差分 (Tempo→Mimir 矢印追加 + visualization 矢印反転)
- Dataflow diagram に 2 ブロック差分 (同上)
- 新規 section "Backend role separation" が full text として挿入されている

- [ ] **Step 5: Mermaid syntax check (local エディタの preview か GitHub web UI で表示)**

VSCode / Cursor 等の Markdown preview で `kubernetes/README.md` を開き、2 つの Mermaid 図が syntax error なくレンダリングされ、新規矢印 (`Tempo --> Mimir`) と反転後の visualization 矢印 (`Grafana -.-> Mimir` 等) が見えることを確認。

---

## Task 6: hydrate を実行して manifests を再生成

**Files:**
- Modified (by hydrate): `kubernetes/manifests/production/tempo/manifest.yaml`
- Modified (by hydrate): `kubernetes/manifests/production/prometheus-operator/manifest.yaml`

- [ ] **Step 1: aqua で helmfile / helm / kustomize を install (初回のみ)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
aqua install
```

期待: helmfile / helm / kustomize 各 binary が `~/.local/share/aquaproj-aqua/` 配下に install される (既に install 済ならスキップ)。

- [ ] **Step 2: tempo component を hydrate**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph/kubernetes
make hydrate-component COMPONENT=tempo ENV=production
```

期待: `kubernetes/manifests/production/tempo/manifest.yaml` が再生成される。helmfile のレンダリング → kustomize build の chain が成功する。

- [ ] **Step 3: prometheus-operator component を hydrate**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph/kubernetes
make hydrate-component COMPONENT=prometheus-operator ENV=production
```

期待: `kubernetes/manifests/production/prometheus-operator/manifest.yaml` が再生成される。

- [ ] **Step 4: hydrated manifests の差分を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git diff kubernetes/manifests/production/tempo/manifest.yaml \
        kubernetes/manifests/production/prometheus-operator/manifest.yaml
```

期待:
- tempo manifest 内に `metrics_generator:` (snake_case for Tempo runtime config) が出現
- tempo manifest 内に `service_graphs:` / `remote_write:` が出現
- tempo manifest 内に `overrides:` (生 yaml で defaults.metrics_generator.processors 列挙) が出現
- prometheus-operator manifest 内の Tempo datasource jsonData に `serviceMap:` が出現

---

## Task 7: hydrated manifests を検査

**Files:** なし (read-only inspection)

**目的:** chart が期待通りに values を展開しているか確認、apply 前の sanity check。

- [ ] **Step 1: Tempo ConfigMap の metrics_generator 設定を抽出**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
awk '/^kind: ConfigMap$/,/^---/' kubernetes/manifests/production/tempo/manifest.yaml \
  | grep -A 30 "metrics_generator:"
```

期待出力 (一部):
```
    metrics_generator:
      processor:
        service_graphs:
          max_items: 10000
          wait: 10s
      registry:
        external_labels:
          cluster: eks-production
      storage:
        remote_write:
          - url: http://mimir-distributed-gateway.monitoring.svc.cluster.local/api/v1/push
            headers:
              X-Scope-OrgID: anonymous
        ...
```

`headers` に `X-Scope-OrgID: anonymous` が含まれていることが最重要。空または `X-Scope-OrgID:` 行が無い場合は Task 2 の field 名問題、Task 3 の修正に戻る。

- [ ] **Step 2: Tempo ConfigMap の overrides セクションを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
awk '/^kind: ConfigMap$/,/^---/' kubernetes/manifests/production/tempo/manifest.yaml \
  | grep -B 2 -A 10 "overrides"
```

期待出力 (一部):
```
    overrides:
      defaults:
        metrics_generator:
          processors:
            - service-graphs
```

空または `processors: []` の場合は Task 3 の `overrides` 構造を修正し Task 6 から再実行。

- [ ] **Step 3: Tempo Deployment の args / startup config を確認 (= metrics-generator 起動が含まれるか)**

monolithic は単一 image / single binary で、`-target=all` で全 component が起動する。args 自体に metrics-generator 関連の特殊な flag は無いことが正常。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
grep -A 5 "args:" kubernetes/manifests/production/tempo/manifest.yaml | head -20
```

期待: `-target=all` または `--target=all` (もしくは default で all)。default の場合は明示行が無くても OK。

- [ ] **Step 4: Grafana datasource ConfigMap の serviceMap を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
grep -A 20 "name: Tempo" kubernetes/manifests/production/prometheus-operator/manifest.yaml \
  | head -25
```

期待出力 (jsonData 内):
```
        jsonData:
          httpMethod: GET
          tracesToLogsV2:
            datasourceUid: loki
          tracesToMetrics:
            datasourceUid: mimir
          serviceMap:
            datasourceUid: mimir
```

`serviceMap:` 行が出ていなければ Task 4 を修正し Task 6 から再実行。

---

## Task 8: Tempo manifest を SSA apply し、metrics-generator 起動を確認

**Files:** なし (cluster operation)

- [ ] **Step 1: Tempo manifest を kustomize build → kubectl SSA apply**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
kubectl kustomize kubernetes/manifests/production/tempo \
  | kubectl apply --server-side --force-conflicts \
      --field-manager=kustomize-controller -f -
```

期待出力 (一部):
```
configmap/tempo serverside-applied
service/tempo serverside-applied
serviceaccount/tempo serverside-applied
statefulset.apps/tempo serverside-applied
servicemonitor.monitoring.coreos.com/tempo serverside-applied
```

(chart によっては Deployment ではなく StatefulSet。production の Tempo monolithic は single replica StatefulSet)

- [ ] **Step 2: Tempo Pod の状態を観測 (1-2 分待機)**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring rollout status statefulset/tempo --timeout=180s
```

期待:
```
statefulset rolling update complete 1 pods at revision <hash>...
```

- [ ] **Step 3: Tempo Pod の log で metrics-generator subsystem が start していることを確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring logs statefulset/tempo --tail=200 \
  | grep -i "metrics.*generator\|service.*graph\|remote.*write" \
  | head -20
```

期待出力: 以下のような log が含まれる
- `started module=metrics-generator`
- `service-graph processor: started`
- (remote_write attempt 系のログがあれば成功兆候)

`error` / `panic` / `crash` 系のキーワードが見えたら Task 7 に戻り設定を見直す。

- [ ] **Step 4: Mimir 側で受信 error が無いことを確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring logs deploy/mimir-distributed-distributor --tail=100 \
  | grep -iE "error|reject|denied" \
  | head -20
```

期待: tempo からの remote_write を reject する error が無い。`auth: invalid tenant` 等の error があれば tenant header (X-Scope-OrgID) が正しく渡っていない、Task 3 / 7 に戻る。

---

## Task 9: prometheus-operator manifest を SSA apply し、Grafana datasource reload を確認

**Files:** なし (cluster operation)

- [ ] **Step 1: prometheus-operator manifest を SSA apply**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
kubectl kustomize kubernetes/manifests/production/prometheus-operator \
  | kubectl apply --server-side --force-conflicts \
      --field-manager=kustomize-controller -f -
```

期待出力: 多数の resource が `serverside-applied` で出る。`error` 系は無し。

- [ ] **Step 2: Grafana datasource ConfigMap が更新されたことを確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring get configmap kube-prometheus-stack-grafana-datasource \
  -o jsonpath='{.data.datasources\.yaml}' \
  | grep -A 15 "name: Tempo" \
  | head -20
```

期待: `serviceMap:` `datasourceUid: mimir` 行が cluster 上の ConfigMap に反映されている。

- [ ] **Step 3: Grafana sidecar が datasource reload を picked up しているか確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana \
  -c grafana-sc-datasources --tail=20
```

期待: 以下のような log が見える
- `Working on configmap kube-prometheus-stack-grafana-datasource`
- `Writing /etc/grafana/provisioning/datasources/datasources.yaml`
- `Reloading via http`

reload log が無い場合は Step 4 の手動 restart で対応。

- [ ] **Step 4 (fallback): 反映されない場合は Grafana Pod を rolling restart**

Step 3 で reload log が見えなかった場合のみ実行:

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=120s
```

期待: rolling update が completes。

---

## Task 10: End-to-end verify (Mimir metrics + Service Graph panel)

**Files:** なし (cluster query + browser inspection)

- [ ] **Step 1: Mimir に traces_service_graph_* metrics が書かれていることを確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
# Mimir gateway を port-forward
kubectl -n monitoring port-forward svc/mimir-distributed-gateway 8080:80 \
  >/dev/null 2>&1 &
PORTFWD_PID=$!
sleep 3

# PromQL query (URL encoded)
curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/prometheus/api/v1/query?query=traces_service_graph_request_total' \
  | jq '.data.result[:3]'

kill $PORTFWD_PID 2>/dev/null
```

期待: non-empty array が返る。各 element に `metric.cluster: "eks-production"` label が含まれる。`status: "success"` で `data.result: []` (空配列) なら以下を順に確認:
- Beyla が trace を出している (= nginx-sample 等にアクセスがあるか)
- Tempo Pod が再起動後に metrics-generator buffer を埋める時間 (= 10s `wait` + scrape interval) が経過しているか
- Tempo log に `remote_write` の error が出ていないか (Task 8 Step 3 再確認)

- [ ] **Step 2: external_labels の cluster が付与されていることを確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring port-forward svc/mimir-distributed-gateway 8080:80 \
  >/dev/null 2>&1 &
PORTFWD_PID=$!
sleep 3

curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/prometheus/api/v1/series?match[]=traces_service_graph_request_total' \
  | jq '.data[0]'

kill $PORTFWD_PID 2>/dev/null
```

期待: returned object に `"cluster": "eks-production"` が含まれる。

- [ ] **Step 3: Grafana の Tempo datasource provisioning を確認**

ブラウザで Grafana にアクセス (gateway 経由、URL は環境変数 / dashboard 等で既知)、 Connections > Data sources > Tempo に移動し、`Service Graph` セクションの `Data source` が `mimir` を指していることを目視確認。

代替 (CLI で確認):

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
  cat /etc/grafana/provisioning/datasources/datasources.yaml \
  | grep -A 20 "name: Tempo"
```

期待: `serviceMap:` `datasourceUid: mimir` 行が file 内に存在。

- [ ] **Step 4: Service Graph panel の動作を Grafana UI で確認**

ブラウザで Grafana にアクセスし、Explore > Tempo datasource > 「Service Graph」 タブを開く。time range を Last 15 minutes に設定、`Run query` を押す。

期待: nginx-sample 等の service ノードと edge が描画される。空のままなら以下を確認:
- 時刻範囲を Last 1 hour に広げる
- Beyla が trace を生成しているか (Tempo の Explore > Search で trace が出るか確認)
- Tempo の `wait: 10s` が完了するまで待つ (apply 直後は不完全)

- [ ] **Step 5: Application Monitoring dashboard の Service Graph panel を確認**

Grafana > Dashboards > Application Monitoring を開き、Service Graph panel に graph が表示されることを確認。

- [ ] **Step 6: 既存 metrics への非影響確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring port-forward svc/mimir-distributed-gateway 8080:80 \
  >/dev/null 2>&1 &
PORTFWD_PID=$!
sleep 3

# Beyla 由来の http_server_* が継続して書かれているか
curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/prometheus/api/v1/query?query=count(http_server_request_duration_seconds_count)' \
  | jq '.data.result[0].value[1]'

# Tempo の up が 1 を返すか
curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/prometheus/api/v1/query?query=up{job="tempo"}' \
  | jq '.data.result[0].value[1]'

kill $PORTFWD_PID 2>/dev/null
```

期待:
- `count(http_server_request_duration_seconds_count)` が非ゼロ
- `up{job="tempo"}` が `"1"`

---

## Task 11: git diff inspect + commit

**Files:** 多数 (= Task 3-6 で modify 済)

- [ ] **Step 1: 変更 file 一覧を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git status
```

期待: 以下の 5 file が modified:
- `kubernetes/components/tempo/production/values.yaml.gotmpl`
- `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`
- `kubernetes/manifests/production/tempo/manifest.yaml`
- `kubernetes/manifests/production/prometheus-operator/manifest.yaml`
- `kubernetes/README.md`

(spec は別 commit で worktree に作成済、本 commit には含めない or 含めるか確認。本 PR では既存 commit に spec / plan を含めているので、status には出ない)

- [ ] **Step 2: 全 diff を eyeball check**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git diff --stat
git diff -- kubernetes/components/
git diff -- kubernetes/manifests/
git diff -- kubernetes/README.md
```

期待:
- tempo values: `metricsGenerator` ブロック大幅増 + `overrides` 新規
- prometheus-operator values: `serviceMap:` 2 行追加
- tempo manifest: `metrics_generator` runtime config + `overrides` ConfigMap data 反映
- prometheus-operator manifest: Grafana datasource ConfigMap の Tempo entry に `serviceMap` 反映
- README: Mermaid 2 図に矢印追加 + 新規 "Backend role separation" section 挿入

- [ ] **Step 3: staged 状態に登録**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git add kubernetes/components/tempo/production/values.yaml.gotmpl \
        kubernetes/components/prometheus-operator/production/values.yaml.gotmpl \
        kubernetes/manifests/production/tempo/manifest.yaml \
        kubernetes/manifests/production/prometheus-operator/manifest.yaml \
        kubernetes/README.md
git status
```

期待: 上記 5 file が staged 状態。untracked / modified なし。

- [ ] **Step 4: signoff 付きで commit (Co-Authored-By 禁止)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git -c commit.gpgsign=false commit -s -m "feat(eks): tempo metrics-generator + service graph datasource

production の Tempo に metrics-generator を有効化し、service_graphs
processor が生成する traces_service_graph_* metrics を Mimir に
remote_write する。Grafana Tempo datasource に serviceMap.datasourceUid:
mimir を追加し、Application / Unified Monitoring dashboard の Service
Graph panel が動作するようになる (= PR #331 残留問題のうち Service Graph 系を解消)。

主な変更:
- tempo/production: metricsGenerator.enabled true、service_graphs only
  (span_metrics は Beyla の http_server_* と重複するため除外)、Mimir
  gateway に remote_write (X-Scope-OrgID: anonymous)、external_labels.cluster
  追加、overrides.defaults.metrics_generator.processors を明示
- prometheus-operator/production: Tempo datasource jsonData に serviceMap
  追加 (datasourceUid: mimir)
- kubernetes/README.md: architecture diagram 2 つに Tempo→Mimir remote_write
  矢印追加 + visualization 矢印を depends-on convention に統一、Dataflow
  の後に Backend role separation section を新設 (Prometheus / Mimir 2 段
  構成 / Tempo metrics-generator の delegation pattern / S3 backing store
  の意味づけを明文化)

Migration: Flux suspend → ローカル kubectl SSA で iterate verify 済。
詳細は spec を参照。

Spec: docs/superpowers/specs/2026-05-11-eks-production-tempo-service-graph-design.md"
```

- [ ] **Step 5: commit footer を検証**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git log -1 --format=%B | tail -3
```

期待:
```
Spec: docs/superpowers/specs/2026-05-11-eks-production-tempo-service-graph-design.md

Signed-off-by: panicboat <panicboat@gmail.com>
```

`Co-Authored-By` 行が無いことを確認。

---

## Task 12: branch を push して Draft PR を作成

**Files:** なし (git remote 操作のみ)

- [ ] **Step 1: branch を upstream tracking 付きで push**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
git push -u origin HEAD
```

期待: branch `feat/eks-production-tempo-service-graph` が origin に push される。

- [ ] **Step 2: Draft PR を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
gh pr create --draft \
  --base main \
  --title "feat(eks): tempo metrics-generator + service graph datasource" \
  --body "$(cat <<'EOF'
## Summary

production の Tempo に **metrics-generator (service_graphs processor)** を有効化し、生成された `traces_service_graph_*` metrics を Mimir に remote_write する。Grafana Tempo datasource に `serviceMap.datasourceUid: mimir` を追加することで、Application / Unified Monitoring dashboard の Service Graph panel が動作するようになる (= PR #331 残留問題のうち Service Graph 系を解消、PR-A `#342` は logs 系を解消済)。

## Why

PR #331 で deploy した 3 dashboard のうち、Application / Unified Monitoring の Service Graph panel (`queryType: serviceMap`) が deploy 後も空のまま残った。

原因: Service Graph panel は Tempo datasource の `serviceMap` query type を使うが、これは **Tempo の trace 自体ではなく、Tempo metrics-generator が生成する `traces_service_graph_*` metrics を Prometheus-compatible datasource から取得** する仕様。production には 2 つの欠落があった:

1. Tempo metrics-generator が `enabled: false` だった (= Phase 4 で再検討との保留状態)
2. Grafana Tempo datasource に `serviceMap.datasourceUid` 未設定だった

## Approach

`service_graphs` processor のみを enable する **option A** を選択。`span_metrics` は併走させない。理由:
- Beyla (eBPF) が既に `http_server_*` / `http_client_*` / `sql_client_*` で RED 系 metrics を生成済、production の Application Monitoring dashboard はそれを参照中
- `span_metrics` を併走させると同じ trace から派生する RED 系 metrics が二重に Mimir に書かれ、cardinality / cost が増えるだけで dashboard 上の新規 value 無し
- Service Graph 機能は `traces_service_graph_*` のみに依存するため、`span_metrics` 無しで完結

## Changes

- `kubernetes/components/tempo/production/values.yaml.gotmpl`: `metricsGenerator` block を full config に置換 (Mimir gateway 宛 remote_write、`X-Scope-OrgID: anonymous` header、`cluster=eks-production` external label、`service_graphs` processor only)、`overrides.defaults.metrics_generator.processors` を新規追加
- `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`: Tempo datasource `jsonData` に `serviceMap.datasourceUid: mimir` を追加
- `kubernetes/manifests/production/{tempo,prometheus-operator}/manifest.yaml`: hydrate-component で自動更新
- `kubernetes/README.md`: 2 つの Mermaid 図に `Tempo --> Mimir` 矢印 (remote_write) を追加、visualization 矢印を `Storage --> Grafana` (push 実線) から `Grafana -.-> Storage` (depends-on 点線) に convention 統一。Dataflow の後に新規 "Backend role separation" section を挿入 (= Prometheus と Mimir 2 段の理由、Tempo metrics-generator の delegation pattern、S3 backing store の意味づけ)

## Verification (deploy 前にローカル iteration で済)

Flux Kustomization を suspend してローカルから kubectl SSA で apply、以下を確認:

1. ✅ Tempo Pod が `started module=metrics-generator` で起動、`service-graph processor` の log 出力
2. ✅ Mimir に `traces_service_graph_request_total{cluster="eks-production"}` 系列が出現
3. ✅ Grafana Tempo datasource の `serviceMap.datasourceUid: mimir` が ConfigMap に反映
4. ✅ Grafana > Explore > Tempo > Service Graph タブで graph 描画
5. ✅ Application Monitoring / Unified Monitoring dashboard の Service Graph panel に graph 表示
6. ✅ Beyla 由来の `http_server_*` 系 metrics が継続して流入 (= 既存 dashboard regression 無し)
7. ✅ Tempo の `up{job="tempo"}` が継続して `1`
8. ✅ README の 2 Mermaid 図と新規 section が GitHub web UI で正常レンダリング

## Out of Scope

- `span_metrics` processor (Beyla 撤去等の方針転換時に別 PR で再評価)
- 既存 dashboard panel の修正
- local の構成変更 (local Tempo の `span_metrics` 削除等は別 PR)
- Tempo の HA 化 / replica 数増 (別 phase)
- `kubernetes/README.md` の historical commentary 整理 (= `Plan N で導入` 等の累積 annotation 削除は PR-C で一括)。本 PR で touch する README 編集は architecture 図の "what" 更新と新規 section 追加に限定。

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-11-eks-production-tempo-service-graph-design.md`
- Plan: `docs/superpowers/plans/2026-05-11-eks-production-tempo-service-graph.md`

EOF
)"
```

期待: gh コマンドが PR URL を返す。Draft 状態であること。

- [ ] **Step 3: PR URL を保存 (= user に渡して merge を依頼)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-tempo-service-graph
gh pr view --json url -q .url
```

PR URL を controller に報告し、user が web UI から merge することを待つ。

---

## Task 13: Flux resume + reconcile 確認 + worktree cleanup (post-merge)

**Files:** なし (cluster operation + worktree 削除)

**Pre-condition:** user が PR を main に merge 済。

- [ ] **Step 1: main を local に fetch**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin main
git rev-parse origin/main | head
```

期待: PR がマージされた SHA が表示される。

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

- [ ] **Step 3: GitRepository / Kustomization を手動 reconcile**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
```

期待: `reconciliation finished in <duration>` で完了。

- [ ] **Step 4: Flux の sync 状態を確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n flux-system get kustomization flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
echo
```

期待: `Applied revision: main@sha1:<merged-sha>` のような message。

- [ ] **Step 5: Tempo Pod が Flux 経由でも継続稼働していることを再確認**

```bash
source ~/.script/eks-login.sh production >/dev/null 2>&1
kubectl -n monitoring get pod -l app.kubernetes.io/name=tempo
kubectl -n monitoring logs statefulset/tempo --tail=20 \
  | grep -i "metrics.*generator" | head -5
```

期待: Pod Running、`metrics-generator` 関連 log が継続して出ている。

- [ ] **Step 6: worktree を削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/feat-tempo-service-graph
git worktree prune
git worktree list
```

期待: `feat-tempo-service-graph` 行が消えている。

- [ ] **Step 7: local branch を削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git branch -D feat/eks-production-tempo-service-graph 2>/dev/null || true
git fetch -p origin
```

期待: local branch が削除される。`-p` で削除済 remote tracking ref も整理。

---

## Failure Modes

| 症状 | 推定原因 | リカバリ |
|---|---|---|
| Task 8 Step 3 で metrics-generator log が出ない | `enabled: false` のままレンダリング、`overrides` が反映されていない | Task 3 で `metricsGenerator.enabled: true` 確認、Task 6 で hydrate 再実行、Task 7 で ConfigMap 内容を再確認 |
| Task 8 Step 4 で Mimir distributor が `auth: invalid tenant` 系 error | `X-Scope-OrgID` header が remote_write に乗っていない | Task 7 Step 1 で ConfigMap の `headers:` を確認、chart field 名が異なる (`remoteWriteHeaders` vs 別名) なら Task 2 結果に基づき Task 3 で修正、Fallback で `tempo.config` 直書き |
| Task 10 Step 1 で `traces_service_graph_*` が空 | (a) Beyla の trace が無い、(b) `wait: 10s` 未経過、(c) overrides.defaults.metrics_generator.processors が空 | Tempo の Explore > Search で trace 自体が見えるか、time range を 15 min に広げる、Task 7 Step 2 で ConfigMap の overrides を再確認 |
| Task 10 Step 4 で Service Graph panel が空 | datasource 設定の反映遅延 or `serviceMap.datasourceUid` が `mimir` 以外を指している | Task 9 Step 4 で Grafana Pod を rolling restart、Step 3 で ConfigMap 内容を再確認 |
| Task 5 Step 5 で Mermaid 図が syntax error | アロー記法のミスタイプ (`- - >` 等)、閉じ括弧抜け | git diff で行単位確認、`mermaid.live` でも確認可能 |
| Task 6 で hydrate-component が fail | chart version が repo 側で削除、aqua の helmfile/helm/kustomize version 不一致 | `aqua install` を再実行、`helm repo update` で `grafana` repo を更新 |
| Task 13 Step 4 で `Applied revision:` が古いまま | flux suspend が解除されていない、reconcile が走っていない | Step 2 / Step 3 を再実行、`kubectl -n flux-system get gitrepository flux-system -o yaml` で fetch error を確認 |
| Task 8 で Tempo Pod が `PersistentVolumeClaim` mount error で start しない | chart v1.24.4 の `metricsGenerator` が専用 WAL PVC を要求しており top-level `persistence` だけでは不足 | Task 2 の `helm show values` 結果から `metricsGenerator.persistentVolume.enabled: true` の有無を再確認、Task 3 で `metricsGenerator` ブロックに `persistentVolume: {enabled: true, size: 10Gi, storageClassName: gp3}` を追加して Task 6 から再実行 |

---

## Notes

- iteration loop (Task 2-10) 中は **commit 不要**。Task 11 でまとめて commit。
- worktree (`feat-tempo-service-graph/`) 内で hydrate を実行することで、main の状態と独立に iterate 可能。
- Flux suspend 中は cluster 上の resource が drift していても reconciliation で上書きされない (= 手動 SSA が safe)。
- Tempo の StatefulSet は単一 replica なので rollout は数秒〜数十秒で完了する。
