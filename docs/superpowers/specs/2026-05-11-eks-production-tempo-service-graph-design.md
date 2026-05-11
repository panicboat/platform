# EKS Production: Tempo Metrics-Generator + Service Graph Design

> **Goal**: production の Tempo に metrics-generator を有効化し、`service-graphs` processor が生成する pairwise service edge metrics を Mimir に remote-write する。Grafana の Tempo datasource に `serviceMap` 設定を追加し、Application / Unified Monitoring dashboard の Service Graph panel を動かす。

---

## Context

### 前提 (PR-A の完了状態)

PR #342 (PR-A) で OTel-native log collection への移行が完了し、Tempo は OTel Collector DaemonSet から OTLP gRPC で trace を受信する構成で稼働中。Tempo の `tempodb` (S3 backend) にも trace tag (`k8s.namespace.name` / `k8s.pod.name` / `service.name` 等) が正しく格納されていることは PR-A の verification で実測済。

ただし production Tempo の `metricsGenerator.enabled` は `false` のままで、`kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json:446` の Service Graph panel (`queryType: "serviceMap"`) は依然として空。

### Root cause

Service Graph panel は Tempo datasource の `serviceMap` query type を使う。この query は **Tempo に格納された trace 自体ではなく、Tempo metrics-generator が生成する `traces_service_graph_*` metrics を Prometheus-compatible datasource から取得する** 動作仕様。

production には 2 つの欠落がある:

1. **Tempo metrics-generator が無効** (`kubernetes/components/tempo/production/values.yaml.gotmpl:59-60`): `metricsGenerator.enabled: false`。よって `traces_service_graph_*` metrics が生成されていない。
2. **Grafana Tempo datasource に `serviceMap.datasourceUid` 未設定** (`kubernetes/components/prometheus-operator/production/values.yaml.gotmpl:116-128`): 設定されていても Tempo は metrics を生成していないため Mimir に該当 series 無し。

### なぜ service-graphs のみで span-metrics を併走させないか

panicboat platform は既に **Beyla (eBPF)** が `http_server_*` / `http_client_*` / `sql_client_*` を独立に生成し、production の Application Monitoring dashboard はそれを参照している (PR #331 の verify で実測確認済)。Tempo の `span-metrics` processor を併走させると同じ trace から派生する RED 系 metrics (`traces_spanmetrics_*`) が二重に Mimir に書かれ、cardinality / cost が増えるだけで既存 dashboard に新規 value は無い。

Service Graph 機能は `traces_service_graph_*` のみに依存するので、`span-metrics` 無しで完結する。Beyla を将来撤去する / Tempo APM stock dashboard を導入する等の方針転換が発生した時点で再評価。

---

## Architecture

### Before (PR-A 完了直後の現状)

```
Beyla DS ──OTLP gRPC──► OTel Collector DS ──OTLP gRPC──► Tempo
                                                          └─ ingester ──► S3 (trace blob)

Grafana Tempo DS (jsonData: tracesToLogsV2, tracesToMetrics — serviceMap 未設定)
   Service Graph panel ── queryType: serviceMap ──► (空、Tempo に該当 metrics 無し)
```

### After (本 PR の終端状態)

```
Beyla DS ──OTLP gRPC──► OTel Collector DS ──OTLP gRPC──► Tempo
                                                          ├─ ingester ──► S3 (trace blob)
                                                          └─ metrics-generator (★ NEW)
                                                              └─ service_graphs processor
                                                                   │ traces_service_graph_request_total
                                                                   │ traces_service_graph_request_failed_total
                                                                   │ traces_service_graph_request_server_seconds
                                                                   │ traces_service_graph_request_client_seconds
                                                                   ▼
                                                              remote_write
                                                                   │ headers: X-Scope-OrgID: anonymous
                                                                   │ external_labels: cluster=eks-production
                                                                   ▼
                                                              Mimir gateway ──► Mimir blocks (S3)

Grafana Tempo DS (jsonData.serviceMap.datasourceUid=mimir ★ NEW)
   Service Graph panel ── queryType: serviceMap ──► PromQL on Mimir ──► graph 描画
```

---

## Design Decisions

| 決定 | 値 | 根拠 |
|---|---|---|
| processors | `service-graphs` のみ | 既存 RED metrics 源 (Beyla) と重複しない最小スコープ。Service Graph panel 要件を満たす最小集合。 |
| remote-write 先 | `http://mimir-distributed-gateway.monitoring.svc.cluster.local/api/v1/push` | 既存 Prometheus remote_write と同じ宛先。Mimir が production の長期 metrics store。 |
| Mimir tenant header | `X-Scope-OrgID: anonymous` | 1 tenant 運用 (Decision 3、PR-A spec 参照)。既存 Prometheus remote_write と同値。 |
| external_labels | `cluster: eks-production` のみ | multi-cluster Mimir で `cluster` は事実上の必須。`source: tempo` は production の他コンポーネントが `source` label を使っておらず metric 名 `traces_*` prefix で識別可能のため redundant、削除。 |
| `service_graphs.wait` | `10s` | Tempo docs default。eBPF Beyla 由来 trace は短く十分。長 latency バックエンド追加時に再評価。 |
| `service_graphs.max_items` | `10000` | local 同値。eBPF 計装の service 数規模 (~数十) で余裕。LRU eviction は上限超過時のみ。 |
| `overrides.defaults.metrics_generator.processors` | `[service-graphs]` | multitenancy OFF でも `defaults` override が無いと processor が起動しない (Tempo 仕様)。 |
| Tempo datasource `serviceMap.datasourceUid` | `mimir` | metrics 書き込み先と一致。Service Graph panel の PromQL クエリが Mimir に到達。 |
| metrics-generator WAL persistence | 実装段階で chart 挙動確認後決定 | Tempo helm chart v1.24.4 の `metricsGenerator.persistentVolume` の有無 / 必須性は hydrate で確認、専用 PVC が必要なら明示構成、不要なら default 任せ。 |

---

## Changes

### 1. `kubernetes/components/tempo/production/values.yaml.gotmpl`

`metricsGenerator` ブロックを `enabled: false` から下記に置換:

```yaml
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
```

加えて `overrides` ブロックを新規追加 (現状 production には無い):

```yaml
overrides:
  defaults:
    metrics_generator:
      processors:
        - service-graphs
```

WAL persistence は実装段階で chart hydrate output を確認し、専用 PVC が必要なら下記を追加:

```yaml
metricsGenerator:
  persistentVolume:
    enabled: true
    size: 10Gi
    storageClass: gp3
```

field 名 (`remoteWriteHeaders` / `persistentVolume`) は chart v1.24.4 spec を実装段階で確認。chart spec と差異があれば `tempo.config` で生 YAML override するか、chart docs に合わせて修正する。

### 2. `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`

Tempo datasource の `jsonData` に `serviceMap` を追加:

```yaml
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
    serviceMap:
      datasourceUid: mimir
```

### 3. Dashboard JSON は変更不要

`kubernetes/components/dashboard/production/kustomization/grafana/app-monitoring.json:446` の `queryType: "serviceMap"` panel は Tempo datasource の `serviceMap.datasourceUid` jsonData を参照する。datasource 側の設定で自動的に動作する。

### 4. local 構成は変更しない

local の Tempo は既に metrics-generator 有効 + `service-graphs` + `span-metrics` の両 processor で稼働中。本 PR は production 側のみ変更し、local の歴史的構成を尊重する (surgical changes 原則)。local の `span-metrics` 削除 / local Tempo datasource への `serviceMap` 追加等は別 PR (= local の OTel-native 化 / dashboard 統一の文脈) で扱う。

---

## Implementation Strategy

PR-A と同じ pattern を採用:

1. Worktree (`feat/eks-production-tempo-service-graph`) で source 編集 → kubernetes/manifests/production への hydrate を local で実行
2. Flux suspend (= `flux suspend kustomization flux-system`) → 手動 `kubectl apply` で先に動作確認 (= production への risk を最小化)
3. Verification 完了後、commit + push + Draft PR
4. Flux resume + reconcile 確認 + worktree cleanup

iteration 中の手元 commit は push せず、まとめて最終 commit にする。

---

## Verification

1. **Tempo Pod の起動確認**
   - `kubectl -n monitoring logs deploy/tempo` に `started module=metrics-generator` ログが出る
   - `kubectl -n monitoring get pod -l app.kubernetes.io/name=tempo` が Running

2. **Mimir に metrics が書かれていることの確認**
   - Grafana > Explore > Mimir で `traces_service_graph_request_total{cluster="eks-production"}` を query
   - 非空 series が返る (= nginx-sample 等の trace が流れていること前提)
   - `external_labels` で `cluster="eks-production"` が付与されていることを確認

3. **Grafana datasource 設定の確認**
   - Grafana UI > Connections > Data sources > Tempo > Service Graph セクションが mimir を指している
   - Configuration の `serviceMap.datasourceUid` が `mimir` で反映済

4. **Service Graph panel の動作確認**
   - Grafana > Explore > Tempo > Service Graph タブで graph が描画される
   - Application Monitoring / Unified Monitoring dashboard の Service Graph panel が non-empty

5. **既存 metrics への非影響確認**
   - Beyla 由来の `http_server_*` 系 metrics が継続して Mimir に流入していること (= Application Monitoring dashboard が引き続き動作)
   - Mimir の `up{job="tempo"}` が継続して 1

---

## Risks / Open Questions

| リスク | 影響 | 緩和策 |
|---|---|---|
| Tempo chart v1.24.4 の `remoteWriteHeaders` field 名・存在 | tenant header が渡らず Mimir が 401 / no-tenant 返却 | 実装段階で hydrate output を確認、chart docs 確認、必要なら `tempo.config` で生 YAML override |
| metrics-generator WAL の persistence chart 挙動 | Pod restart 時の metric ロスト or 起動失敗 | 実装段階で hydrate output を確認、専用 PVC 必要なら明示構成 |
| service-graphs の cardinality 増加 | Mimir 書き込み量 / cost 増 | 現状 service 数 ~数個 (nginx-sample + system)、影響軽微。実観測で大量 series が発生したら別 PR で `dimensions` 制限 |
| Tempo Pod 再起動時の monolithic mode における metrics-gen + ingester の競合 | 起動失敗 | 公式に monolithic mode + metrics-generator は同居可、Tempo 2.6.1 でサポート済 |
| Grafana datasource provisioning の reload tail | datasource 設定の反映に Grafana Pod restart が必要な可能性 | chart の Grafana sidecar が ConfigMap reload を検知して自動再読込、効かなければ `kubectl rollout restart deploy/kube-prometheus-stack-grafana` で対応 |

---

## Out of Scope

- `span-metrics` processor (= 別 phase / 別 PR、Beyla 撤去等で再評価)
- 既存 dashboard panel の修正
- Mimir 側の retention / tenant 設計変更
- local の構成変更 (local Tempo の `span-metrics` 削除、local Tempo datasource の `serviceMap` 追加等)
- Tempo の HA 化 / replica 数増 (= 別 phase)
- `kubernetes/README.md` の historical commentary 整理 (= PR-C で一括)
