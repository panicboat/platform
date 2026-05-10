# EKS Production: Grafana Dashboards Migration Design

> **Goal**: local cluster で動いている 3 枚の Grafana dashboard (`app-monitoring` / `infra-monitoring` / `unified-monitoring`) を production cluster に移植する。コピー後そのままでは「全 panel に何も表示されない」状態になる既知の 2 bug を併せて fix する。

---

## Context

### 現状

- `kubernetes/components/dashboard/local/kustomization/grafana/` に 3 枚の dashboard JSON が存在し、kustomize の `configMapGenerator` + label `grafana_dashboard: "1"` 経由で local Grafana の sidecar (k8s-sidecar) に拾わせる構成
- production 側には `kubernetes/components/dashboard/production/` も `kubernetes/manifests/production/dashboard/` も存在しない (= dashboard が deploy されていない)
- production の `prometheus-operator` Helm values で `grafana.sidecar.dashboards.searchNamespace: ALL` は既に有効
- production には Mimir / Loki / Tempo がすでに deploy 済み、Grafana datasource として登録済み

### 「そのままだと動かない」の根本原因

local 由来 JSON を production にコピーしただけでは全 panel が空になる。原因は 2 段:

1. **Prometheus datasource UID `prometheus` が production に存在しない**
   - local: kube-prometheus-stack chart 自動生成の `uid: prometheus` が default
   - production: `defaultDatasourceEnabled: false` で chart 自動生成を disable、代わりに Mimir を `uid: mimir` で `isDefault: true` 登録、Prometheus (in-cluster, 24h retention) を `uid: prometheus-local` で secondary 登録
   - 結果: dashboard JSON 内の全 `"uid": "prometheus"` 参照が解決不能 → Prometheus 系 panel と、Prometheus datasource を source にする `$namespace` / `$service` template variable が空になる
2. **Loki / Tempo の query が "All" 選択時に全部 `=~".*"` になり Loki が parse error で reject**
   - Loki 3.x: `{label1=~".*", label2=~".*"}` のように **全 matcher が empty-compatible だと拒否される** (= 観測されたエラー: `queries require at least one regexp or equality matcher that does not have an empty-compatible value`)
   - 原因: dashboard JSON の templating variable に `allValue` が未設定で、Grafana のデフォルト挙動では "All" 選択時に regex matcher を `.*` で展開する
   - 結果: Loki / Tempo panel も空になる (= local では「All」を選ばずに使っていたため気付かれなかった)

---

## Architecture

### Deploy 経路

local と同じ kustomize + Flux + hydrate 経路に乗せる。

#### Source 配置 (人が書くもの)

```
kubernetes/components/dashboard/
├── local/kustomization/                  (既存、無修正)
│   ├── kustomization.yaml
│   └── grafana/{app,infra,unified}-monitoring.json
└── production/kustomization/             (★ 新規、人が書く)
    ├── kustomization.yaml
    └── grafana/{app,infra,unified}-monitoring.json
```

#### Hydrated 出力 (Makefile が自動生成)

```
kubernetes/manifests/production/
├── kustomization.yaml                    (= make hydrate-index が再生成)
└── dashboard/                            (= make hydrate-component が生成)
    ├── kustomization.yaml
    └── manifest.yaml
```

`kubernetes/Makefile` の hydrate target は次の動作をする:

- `make hydrate-component COMPONENT=dashboard ENV=production`
  - `components/dashboard/production/kustomization/` に対し `kustomize build` を実行
  - 出力を `manifests/production/dashboard/manifest.yaml` に書き出す
  - `manifests/production/dashboard/kustomization.yaml` を `resources: [manifest.yaml]` で再生成
- `make hydrate-index ENV=production`
  - `manifests/production/kustomization.yaml` の resources リストを `manifests/production/*/` から alphabetical 順で再生成
  - `components/<name>/production/` が存在しない `manifests/production/<name>/` は自動削除

つまり **`manifests/production/` 配下は手で書かない**。 `components/dashboard/production/kustomization/` を書いて hydrate コマンドを叩くだけ。

#### Deploy 後の挙動 (local と同じ)

1. Flux が `manifests/production/` を reconcile
2. kustomize が build → ConfigMap 3 枚 (label `grafana_dashboard: "1"`) を `monitoring` namespace に展開
3. Grafana Pod の k8s-sidecar が ConfigMap label を watch → JSON を Grafana の dashboards provisioner ディレクトリに drop
4. Grafana が dashboard を import → Web UI に出現

### Datasource 接続

| Panel 種別 | 使用する datasource UID | production での実体 |
|---|---|---|
| Stat / Timeseries (Prometheus 系) | `mimir` | Mimir gateway (`mimir-distributed-gateway.monitoring.svc.cluster.local`) |
| Logs | `loki` | Loki gateway (`loki-gateway.monitoring.svc.cluster.local`) |
| Traces / Service Graph | `tempo` | Tempo (`tempo.monitoring.svc.cluster.local:3200`) |

---

## Implementation

### 変更点 1: dashboard JSON の datasource UID 置換

local の 3 枚をコピー後、JSON 内の全ての

```json
"datasource": { "type": "prometheus", "uid": "prometheus" }
```

を

```json
"datasource": { "type": "prometheus", "uid": "mimir" }
```

に置換する。これは `panels[].datasource` / `panels[].targets[].datasource` / `templating.list[].datasource` の全てに出現する。

local の `loki` / `tempo` UID 参照は production も同じ UID なので **無修正**。

### 変更点 2: template variable に `allValue: ".+"` を追加

`namespace` / `service` / `pod` の 3 変数 (= `templating.list[]` 内で `includeAll: true` のもの) に

```json
"allValue": ".+"
```

を追加する。textbox 型の `search` / `traceId` は変更不要。

これにより "All" 選択時に matcher が `=~".+"` (= 1 文字以上) となり、Loki の empty-compatible 拒否を回避する。Mimir / Tempo 側も regex として正常に動作する。

### 変更点 3: production kustomization (source) 追加

#### `kubernetes/components/dashboard/production/kustomization/kustomization.yaml` (新規)

local と同じ構成 (namespace=monitoring、3 つの configMapGenerator、label `grafana_dashboard: "1"`、`disableNameSuffixHash: true`) で新規作成する。

#### `kubernetes/manifests/production/dashboard/` (Makefile 自動生成)

手では作らない。次のコマンドで生成される:

```
make -C kubernetes hydrate-component COMPONENT=dashboard ENV=production
make -C kubernetes hydrate-index ENV=production
```

これにより:

- `kubernetes/manifests/production/dashboard/manifest.yaml` (= 3 ConfigMap の rendered YAML)
- `kubernetes/manifests/production/dashboard/kustomization.yaml`
- `kubernetes/manifests/production/kustomization.yaml` の resources リストに `./dashboard` を追加

の 3 つが自動更新される。これらを最終的に commit する。

### 変更しないもの

- `kubernetes/components/dashboard/local/` 配下の JSON / kustomization.yaml (= surgical changes)
- `prometheus-operator` の Helm values (sidecar 設定はすでに有効)
- production OTel Collector の logs pipeline (= 別 sub-project の領域)
- dashboard UID と title (local と同名のまま、別 cluster なので衝突しない)

---

## Verification

deploy 後、Grafana UI (https://grafana.panicboat.net) で以下を確認する。

| # | 項目 | 期待結果 | NG 時の対応 |
|---|---|---|---|
| 1 | Dashboards 一覧に Application Monitoring / Infrastructure Monitoring / Unified Monitoring が出現 | 表示 | sidecar log + `kubectl get cm -n monitoring -l grafana_dashboard=1` |
| 2 | "All" 選択時に namespace / service / pod variable dropdown に値が出る | 値表示 | 該当 datasource に metric / log が来ていない可能性、3-3 へ |
| 3 | Infrastructure Monitoring の Cluster Overview row (Nodes / Namespaces / Total Pods 等) | 数値表示 | Mimir に `kube_node_info` / `kube_pod_info` が無い → kube-state-metrics の remote_write 経路を確認 |
| 4 | Application Monitoring の Trace Search Results | 行表示 (Beyla 由来 trace) | Tempo の `resource.service.name` が空 or service variable 0 件 → Tempo `/api/search/tags` で実 tag 確認 |
| 5 | Application Monitoring の Application Logs | log 表示 | Loki label が `k8s_namespace_name` でない可能性 → Loki `/loki/api/v1/labels` で実 label 確認 |
| 6 | Container Restarts / CPU / Memory panel | 値表示 | `kube_pod_container_status_restarts_total` / `container_cpu_usage_seconds_total` が Mimir に来ているか確認 |

検証で label 不一致が見つかった場合は **別 PR で query を実 label に合わせて修正**する (= 本 PR の scope 外)。

### NG 時の調査コマンド (参考)

```bash
# Mimir のメトリクス一覧
kubectl -n monitoring port-forward svc/mimir-distributed-gateway 8080:80
curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/prometheus/api/v1/label/__name__/values' | jq '.data | length'

# Loki の label 一覧
kubectl -n monitoring port-forward svc/loki-gateway 8080:80
curl -s -H "X-Scope-OrgID: anonymous" \
  'http://localhost:8080/loki/api/v1/labels' | jq

# Tempo の tag 一覧
kubectl -n monitoring port-forward svc/tempo 3200
curl -s 'http://localhost:3200/api/search/tags' | jq
```

---

## Risks / Open Questions

| リスク | 影響 | 緩和策 |
|---|---|---|
| production OTel Collector に local の `transform/logs` processor が無い → Loki label が `k8s_namespace_name` でない可能性 | Logs panel 空のまま | Verification step #5 で確認、不一致なら follow-up PR で query 修正 |
| Beyla → otel-collector → Tempo path で `resource.service.name` がセットされていない可能性 | Trace Search Results / Service Graph 空 | Verification step #4 で確認、不一致なら Tempo query 修正 or Beyla 設定追加 (本 PR scope 外) |
| `${service:regex}` の Grafana 内挿で "All" + `allValue: ".+"` が `(.+)` になる仕様 | Tempo TraceQL は regex を受けるので問題なし | Verification step #4 で実 trace が出るか目視確認 |
| ConfigMap 1MB 制限 | dashboard 増加で将来抵触の可能性 | 現状 3 枚で合計 ~30KB、十分 margin あり |

### 本 PR で意図的に扱わない範囲

- **local dashboard の同種 bug 修正** (`allValue` 不在): surgical changes 原則で local 側は無修正
- **production OTel Collector の `transform/logs` 追加**: 影響範囲が大きく別 sub-project の領域
- **dashboard の機能追加・新 panel**: 既存の 3 枚を production で動かすことに focus
- **Grafana folder / tag / 並び順の整理**: 必要に応じて follow-up

---

## Out of Scope

- 新しい dashboard / panel の作成
- alert rule の追加
- local 側 dashboard の修正
- OTel Collector / Beyla 等 upstream component の設定変更
