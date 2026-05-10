# EKS Production: OTel-Native Log Collection Migration Design

> **Goal**: production cluster の log 収集を Fluent-bit DaemonSet + OTel Collector Deployment の二段構えから、**OTel Collector DaemonSet 一本** (chart preset `logsCollection` + `kubernetesAttributes`) に置換する。これにより Loki に `k8s_namespace_name` / `k8s_pod_name` 等の resource label が付与され、Application Monitoring / Unified Monitoring dashboard の Application Logs panel が動作するようになる。

---

## Context

### 直前 PR (#331) で観測された残留問題

PR #331 で local の 3 dashboard を production に移植したが、deploy 後の確認で 2 つの panel が空のまま残った:

- **Application Logs** (Application / Unified Monitoring): query `{k8s_namespace_name=~"$namespace", k8s_pod_name=~"$pod"} |= "$search"` が常に空
- **Service Graph** (Application / Unified Monitoring): Tempo `serviceMap` queryType が空 ← 別 PR (PR-B) で対応

### 実測した production の状態

systematic-debugging Phase 1 で kubectl 経由で実測した結果:

| Component | 実測 | 期待 |
|---|---|---|
| Production Loki labels | `["__stream_shard__", "service_name"]` のみ。全 log の service_name は `unknown_service` | `k8s_namespace_name`, `k8s_pod_name`, `service_name` 等 |
| Production Tempo tags | `k8s.namespace.name` / `k8s.pod.name` / `service.name` 等フル装備 (= Beyla が直接付与) | (期待通り、Beyla 側で完結) |
| Production Mimir metrics | `kube_*` / `container_*` / `http_server_*` / `hubble_*` 全て揃う | (期待通り) |

つまり logs だけが label 不足 + service.name 不在の状態。

### Root cause の特定

production OTel Collector の logs pipeline (`kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`):

```yaml
logs:
  exporters: [otlp_http/loki]
  processors: [memory_limiter, batch]   # ← k8s metadata 救済 processor 不在
  receivers: [otlp]
```

local には存在する `transform/logs` (Fluent-bit の nested attribute を OTel resource attribute に昇格) と `k8sattributes` (k8s API から enrich) processor が production には無い。よって Fluent-bit が付けた `attributes["kubernetes"]["..."]` が **resource attribute に昇格しない** → Loki OTLP ingest は resource attribute のみを label 化する仕様 → label が生成されない。

### なぜ「local pattern を移植」ではなく「OTel-native 化」を選ぶのか

ユーザーから明示された方針: 「OTel 構成として最も美しい A 案で進めたい」 (= brainstorming 中の choice A)。

OTel community の推奨パターンは:

1. **filelogreceiver** で OTel Collector が直接 container log を tail する (Fluent-bit を経由しない)
2. **kubernetesattributes** processor で k8s API から metadata を直接 enrich する (= nested attribute 救済が不要)
3. **DaemonSet** mode で per-node で動かす (= Beyla も per-node、log file も per-node のため自然)

local pattern はあくまで Fluent-bit 経路の歴史的事情に対する救済策。production を最初から OTel-native で構築するなら、Fluent-bit を撤去して collector に統合するのが筋。

---

## Architecture

### Before (現状)

```
Beyla DaemonSet ──┐ (OTLP gRPC、Service DNS)
                  ▼
Fluent-bit DaemonSet ──→ OTel Collector (Deployment, 1 replica) ──→ Tempo
                                                               └─→ Loki
                              ↑
                        OTLP gRPC (kubernetes filter で nested metadata 付与済)
```

### After (本 PR の終端状態)

```
Beyla DaemonSet ──┐ (OTLP gRPC、Service DNS — 無修正)
                  ▼
            OTel Collector DaemonSet (per node、5 instance)
              receivers:
                - otlp (Beyla からの traces 受信)
                - filelog (chart preset、/var/log/pods/*/*/*.log 直 tail)
              processors:
                - memory_limiter
                - k8sattributes (chart preset、k8s API から enrich)
                - resource (cluster.name=eks-production)
                - batch
              exporters:
                - otlp_grpc/tempo (traces)
                - otlp_http/loki (logs)
              ▼
        Tempo / Loki
```

### 本 PR で削除されるもの

- Fluent-bit DaemonSet (component / manifest 両方)
- 旧 OTel Collector Deployment (helm が DaemonSet に切替時に削除)

### 本 PR で無修正のもの

- Beyla (Service DNS で OTel に接続、DaemonSet 化されても Service 経由でルーティング自動継続)
- Tempo / Loki / Mimir / prometheus-operator
- local の OTel Collector / fluent-bit (= 本 PR の scope は production のみ、surgical changes 原則)

---

## Implementation

### 変更点 1: `opentelemetry-collector/production/values.yaml.gotmpl` 大改訂

主要変更 (詳細は実装計画にて確定):

```yaml
mode: daemonset                         # ← was: deployment
# replicaCount: 1                       # ← 削除 (DaemonSet では無効)

resources:                              # 5 instance に分散、per-node サイズ
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 512Mi }

tolerations:                            # ← 新規 (全 node に schedule)
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

priorityClassName: system-node-critical # ← 新規 (= fluent-bit と同等)

presets:                                # ← 新規、OTel-native の中核
  logsCollection:
    enabled: true
    includeCollectorLogs: false         # collector 自身の log は除外、self-loop 防止
    storeCheckpoints: true              # node 再起動で tail 位置を resume
  kubernetesAttributes:
    enabled: true                       # k8sattributes + ClusterRole/Binding を chart 一括構成

config:
  receivers:
    filelog:                            # chart preset の filelog receiver を override
      start_at: end                     # ← 初回起動時の backfill 防止
                                        # (chart default の beginning だと既存 log 全件再送、
                                        #  Fluent-bit 経由分とのダブり大量発生)

  processors:
    resource:                           # ← 新規、cluster identification
      attributes:
        - key: cluster.name
          value: eks-production
          action: upsert

  exporters:
    otlp_grpc/tempo:                    # ← 既存維持
      endpoint: tempo.monitoring.svc.cluster.local:4317
      tls: { insecure: true }
    otlp_http/loki:                     # ← 既存維持
      endpoint: http://loki-gateway.monitoring.svc.cluster.local:80/otlp
      tls: { insecure: true }

  service:
    pipelines:
      traces:
        receivers:  [otlp]
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters:  [otlp_grpc/tempo]
      logs:
        receivers:  [filelog]           # ← was: [otlp]、Fluent-bit 撤去で otlp 不要
        processors: [memory_limiter, k8sattributes, resource, batch]
        exporters:  [otlp_http/loki]
      # metrics pipeline は削除 (= production 未接続、debug exporter のまま残す意義なし)
```

### 変更点 2: Fluent-bit component の撤去

```
kubernetes/components/fluent-bit/production/         ← ディレクトリごと削除
kubernetes/components/fluent-bit/local/              ← 残す (local は Fluent-bit を維持)
```

`make hydrate-index ENV=production` 実行時に `kubernetes/manifests/production/fluent-bit/` が自動削除され、`kubernetes/manifests/production/kustomization.yaml` の resources リストから `./fluent-bit` が消える。

### 変更点 3: hydrated 出力の更新

```
kubernetes/manifests/production/opentelemetry-collector/manifest.yaml   ← 大幅変更
kubernetes/manifests/production/fluent-bit/                              ← 自動削除
kubernetes/manifests/production/kustomization.yaml                       ← fluent-bit 行削除
```

`make hydrate-component COMPONENT=opentelemetry-collector ENV=production` + `make hydrate-index ENV=production` で生成。

### 変更点 4: Beyla / Tempo / Loki / Mimir / prometheus-operator は **無修正**

- Beyla の OTLP endpoint は Service DNS。Deployment → DaemonSet 化されても Service の selector が DaemonSet pods を拾うため自動継続。
- 他の component は受信側、何も変わらず。

---

## Migration Strategy

本 PR は架構変更を含むため、ローカル iteration → 確定 → PR の流れで進める (= Flux suspend して local apply で iterate)。

### Step 1: Flux を suspend

```bash
kubectl -n flux-system patch kustomization flux-system \
  --type=merge -p '{"spec":{"suspend":true}}'
```

### Step 2: 編集 → hydrate → apply の loop

1. `values.yaml.gotmpl` を編集
2. `rm -rf kubernetes/components/fluent-bit/production`
3. `make -C kubernetes hydrate-component COMPONENT=opentelemetry-collector ENV=production`
4. `make -C kubernetes hydrate-index ENV=production`
5. **手動 cleanup** (= kubectl apply は prune しないため):

   ```bash
   kubectl -n monitoring delete deployment opentelemetry-collector --ignore-not-found
   kubectl -n monitoring delete daemonset,sa,cm,clusterrole,clusterrolebinding \
     -l app.kubernetes.io/instance=fluent-bit
   ```

6. 適用 (Flux と同じ field-manager で):

   ```bash
   kubectl apply --server-side --force-conflicts \
     --field-manager=kustomize-controller \
     -k kubernetes/manifests/production
   ```

### Step 3: 検証

| # | 確認項目 | 期待 |
|---|---|---|
| 1 | OTel Collector DaemonSet が全 node で Running | 5/5 |
| 2 | 旧 OTel Collector Deployment が削除済み | なし |
| 3 | Fluent-bit DaemonSet 関連リソース全削除 | なし |
| 4 | Loki labels に `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name` 等が出現 | あり |
| 5 | 任意の log を query: `{k8s_namespace_name="monitoring"}` で結果あり | あり |
| 6 | Tempo の Trace Search Results が引き続き動作 | あり |
| 7 | Grafana UI: Application Logs panel に log が出る | 出る |
| 8 | Grafana UI: Error Logs panel (Infra dashboard) に出る | 出る |

成功条件を満たさない場合は Step 2 の編集に戻り iterate。

### Step 4: 確定 → commit + push + PR + review + merge

通常の PR flow。

### Step 5: Flux を resume

```bash
git pull --ff-only origin main
kubectl -n flux-system patch kustomization flux-system \
  --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate kustomization flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -u +%FT%TZ)" --overwrite
```

reconcile 完了後、cluster 状態 = manifest = main branch が一致する drift-free 状態に戻る。

### 操作上の注意

- **Flux suspend を忘れない**: 他 PR が merge されると我々の local apply が上書きされる
- **Flux resume を merge 前にしない**: 旧 fluent-bit が manifest 上にまだ残っているため再 deploy される
- **field-manager を `kustomize-controller` に揃える**: SSA conflict warning を防ぐ
- **iteration 中の commit は手元のみ**: push せず、まとめて最終 commit にする

---

## Risks / Open Questions

| リスク | 影響 | 緩和策 |
|---|---|---|
| chart preset `logsCollection` + `kubernetesAttributes` の動作確認 | filelog receiver / k8sattributes processor の chart 自動生成内容が想定と異なる可能性 | local iteration で hydrate output を `kubectl get` で実物確認、必要なら override |
| filelog receiver `start_at: end` 上書きが chart preset 内で適用されるか | chart の値マージ挙動次第で `beginning` のままなら大量 backfill | hydrate 後の manifest.yaml で確認、効かなければ `config.receivers.filelog.start_at` で明示設定 |
| 旧 Deployment と新 DaemonSet の Service endpoint の入れ替え時の Beyla trace gap | helm upgrade 時の数十秒、Beyla の retry buffer で大半は保持 | 許容 |
| Fluent-bit hostPath storage の残骸 (`/var/log/flb_storage`) | hostPath は K8s 管理外、自動削除されない | 実害なし、放置 or 後日手動 cleanup |
| `priorityClassName: system-node-critical` の使用 | system reserved namespace 以外では cluster admin 制約あり | monitoring namespace は既に fluent-bit が使用中 = 制約クリア |

### 本 PR で意図的に扱わない範囲

- **local OTel Collector の OTel-native 化**: surgical changes 原則、別 phase
- **Tempo metrics-generator 有効化** (= Service Graph 復活): 別 PR (PR-B)
- **既存 dashboard JSON の修正**: PR #331 の query は本 PR の修正で動作するはず、変更不要
- **Loki の OTLP attribute → label mapping 調整** (低 cardinality 化): production scale が顕在化したら別 PR

---

## Out of Scope

- 新 dashboard / panel の追加
- alert rule の追加
- local 側の OTel Collector / Fluent-bit の変更
- Tempo / Loki / Mimir 設定の変更
- Beyla 設定の変更
