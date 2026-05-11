# Phase 6-3 Theme B - Monitoring stack hardening 調査結果

**関連 spec**: `docs/superpowers/specs/2026-05-12-eks-production-application-end-to-end-validation-design.md`
**調査対象 cluster**: eks-production (ap-northeast-1, account 559744160976)
**Cluster 観測時刻**: 2026-05-11T16:55Z

---

## 調査結果 summary (= 確定済 facts)

### Beyla 1 series labels (= Mimir で観測した実際の `http_server_request_duration_seconds_count` series; 29 labels + `__name__` = 30、 `_bucket` 派生で `le` 追加 → 31)

| Category | Labels (実物) | Count |
|---|---|---|
| Beyla k8s decorator | `k8s_container_name`, `k8s_deployment_name`, `k8s_kind`, `k8s_namespace_name`, `k8s_node_name`, `k8s_owner_name`, `k8s_pod_name`, `k8s_pod_start_time`, `k8s_pod_uid`, `k8s_replicaset_name` | 10 |
| Beyla OTel HTTP attr | `http_request_method`, `http_response_status_code`, `http_route`, `url_scheme` | 4 |
| Beyla OTel server attr | `server_address`, `server_port` | 2 |
| Beyla OTel service attr | `service_name`, `service_namespace` | 2 |
| Prometheus ServiceMonitor scrape meta | `container`, `endpoint`, `instance`, `job`, `namespace`, `pod`, `service` | 7 |
| `exported_*` (= Beyla の自前 `job`/`instance` を Prometheus が renames) | `exported_instance`, `exported_job` | 2 |
| Prometheus external_labels | `prometheus`, `prometheus_replica` | 2 |
| Metric meta | `__name__` (+`le` for `_bucket`) | 1+1 |
| **Total** | | **30+1=31** |

Cluster 状態の追加確認:

- `service_name=nginx, frontend, reverse-proxy` は Mimir に流入 (= rate>0 は `nginx` のみ、 frontend/reverse-proxy は stale)
- `service_name=monolith` は Beyla には全く流入していない (= `count by(service_name)(http_server_request_duration_seconds_count)` で 3 services のみ、 monolith 不在)
- Tempo に存在する `service.name` 値 = `nginx` のみ (= 840 traces stored、 ただし `inspected_spans=0` は全 trace に span 0 個ではなく Tempo `/api/search` で query range 不一致による表示制限の挙動)
- `target_lang` per Beyla pod: `beyla-kcd4p`=`generic` only、 `beyla-v2nqf`=`generic + nodejs`。 `ruby` の `beyla_build_info` が 0 (= ruby 用 prober が起動していない)
- Beyla log: `instrumenting process cmd=/usr/local/bin/node service=frontend` → 直後に `Script successfully injected` で nodejs prober 起動。 ruby は `instrumenting process cmd=/usr/local/bin/ruby type=ruby service=monolith` の後に対応する prober 起動 log なし (= `Launching p.Tracer` も `Script successfully injected` も出ていない)
- OTel Collector v0.151.0 (= ≥v0.120.0 = Prometheus 3.0 scraper、 dotted-name label 保持) を採用
- Prometheus v3.11.3 (= UTF-8 names default-on)
- Mimir `validation.max-label-names-per-series` の 明示 override なし (= chart default 30、 PR #321 で 25 → 30 引き上げの 形跡は repo 側に残っていない、 chart default 値そのもの)
- distributor reject rate: ~17 件/分 (= `invalid label` + `max-label-names-per-series` 合計)

---

## 問題 1: Mimir max-label-names-per-series

### Root cause (確定)

31 labels の内訳は上表のとおり。 雪だるま化の理由は 3 layer の二重・三重 enrichment が加算式に積み上がる こと:

1. Beyla 側 (= 上表 18 labels = k8s 10 + http 4 + server 2 + service 2) を Prometheus exposition で `/metrics` に expose
2. Prometheus ServiceMonitor 側 (= scrape meta 7 labels) を scrape 時に注入
3. Prometheus remote_write 側 (= external_labels 2 + `exported_*` rename 2 = 4 labels) を Mimir 送信時に追加
4. ヒストグラム由来の `le` で +1

panicboat の `attributes.kubernetes.enable: true` が全 `k8s_*` 10 個一括 ON (= Beyla 3.x の "Default Always-shown + Kubernetes group + Cloud group" の中で K8s group が一括加算される仕様)。 さらに ServiceMonitor scrape meta (= `container`/`endpoint`/`instance`/`job`/`namespace`/`pod`/`service`) は Beyla 自身が emit する `instance`/`job` と衝突して Prometheus が `exported_*` に rename、 元の labels を drop せず 2 倍化。

limit 引き上げの雪だるま化の理由: Beyla 側はデフォルトで k8s decorator を増やす方向に進化 (= 例 chart 1.20+ で `k8s.statefulset.name` 等の追加候補)、 cluster 拡張で external_labels も増える可能性、 結果として `31 → 32 → 35` と単調増加し最終的に Prometheus 上限 (= remote-write spec の labels 上限 = 32 が legacy default、 Mimir で 60-100 まで設定可能) に達する前提が壊れる。

### Best practice fix options

**Option A: Beyla `attributes.select` で http_* metric の label を明示 include**

公式 docs: https://grafana.com/docs/beyla/latest/configure/metrics-traces-attributes/

`kubernetes/components/beyla/production/values.yaml.gotmpl` に追加:

```yaml
config:
  data:
    attributes:
      kubernetes:
        enable: true
      select:
        # http_server / http_client 両方 (wildcard 可)
        http_*:
          include:
            - http.request.method
            - http.response.status_code
            - http.route
            - url.scheme
            - server.address
            - server.port
            - service.name
            - service.namespace
            - k8s.namespace.name
            - k8s.deployment.name
            - k8s.pod.name
            # 必要なら k8s.node.name のみ追加 (= node 故障 debug 用)
```

これで Beyla 側 18 → ~11 labels (= 7 reduction)、 `k8s_pod_uid` / `k8s_replicaset_name` / `k8s_owner_name` / `k8s_kind` / `k8s_pod_start_time` / `k8s_container_name` / `k8s_node_name` を drop。 21 labels (= 11+7 scrape+2 external+1 le=21) になり余裕 9。

- 利点: Beyla 公式 sanctioned 機能 (= cardinality 制御に明記の選択肢)、 root に最も近い、 Tempo / Prometheus / remote_write 系の挙動を変えない
- 欠点: select は per-metric なので Beyla の他の metric (= `process_*` / `beyla_network_*`) には別途指定が必要 (= ただし current 構成ではそれらは未使用)
- 公式 ref: https://grafana.com/docs/beyla/latest/configure/metrics-traces-attributes/

**Option B: Prometheus ServiceMonitor の `metricRelabelings` で `prometheus` / `prometheus_replica` / `exported_*` / `k8s_pod_uid` / `k8s_pod_start_time` / `k8s_replicaset_name` を drop**

`kubernetes/components/beyla/production/values.yaml.gotmpl` の `serviceMonitor:` 配下に:

```yaml
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack
  metricRelabelings:
    - sourceLabels: [k8s_pod_uid]
      action: labeldrop
    - regex: "k8s_pod_start_time|k8s_replicaset_name|exported_instance|exported_job|prometheus|prometheus_replica"
      action: labeldrop
```

- 利点: 1 箇所変更で全 Beyla metrics 一括 drop、 Beyla config 不変
- 欠点: "なぜそれを drop か" の理由が ServiceMonitor 側に分散 (= source of truth が 2 箇所)、 Beyla が emit したものを後段で 削るので CPU / network 帯域は無駄に消費したまま (= small cluster なので影響軽微)
- 公式 ref: https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.RelabelConfig

**推奨: Option A (= Beyla `attributes.select`)**

理由: (1) root cause (= Beyla が大量 label を emit している) に最も近い fix、 (2) panicboat の CLAUDE.md 「surgical change」「不要な抽象化を作らない」原則と整合、 (3) 同時に問題 3 の Beyla 関連設定改善と同 file で進められる、 (4) Beyla 自身の CPU / 内蔵 ring buffer / memory usage も削減 (= side benefit)。

---

## 問題 2: OTel Collector self-metric invalid label

### Root cause (確定)

OTel Collector v0.151.0 (= ≥v0.120.0) は Prometheus 3.0 scraper 採用後、 dotted-name (= UTF-8 label name) を Prometheus exposition endpoint にそのまま expose する 仕様。 Collector v0.119.0 以前は dots を underscore に escape していたが v0.120.0 で停止 (= migration toward OTel semconv strict)。

panicboat の self-monitoring 経路:

```
OTel Collector (= telemetry.metrics.readers[].pull.exporter.prometheus on :8888)
  → ServiceMonitor scrape (= chart auto-generated)
  → Prometheus 3.11.3 (= UTF-8 names default on、 dotted labels pass-through)
  → remote_write to Mimir
  → Mimir distributor の Prometheus 2.x 互換 label validator (= ^[a-zA-Z_][a-zA-Z0-9_]*$) で reject
```

dotted labels の具体例 (= 上記 Mimir log + 自分で 取得した metrics 確認):

- `otelcol_exporter_sent_log_records_total` series: `server.address="loki-gateway..."`, `server.port="80"`, `url.path="/otlp/v1/logs"`
- `target_info` series (= OTel SDK の Prometheus exporter が auto-emit する resource attribute holder): `host.name`, `k8s.namespace.name`, `k8s.node.name`, `k8s.pod.name`, `k8s.pod.ip` 等

これらは OTel SDK の internal-telemetry `service.telemetry.metrics.resource:` + Prometheus exporter の挙動の合算。 Mimir は v3.x でも 既存 metric name に対する `chronosphere`-style UTF-8 validation 拡張は default off、 Prometheus 2.x 互換の strict validation を継続。

### Best practice fix options

**Option A: OTel Collector の telemetry.metrics の reader を pull→push (= OTLP) に切替**

公式 docs: https://opentelemetry.io/docs/collector/internal-telemetry/ (Collector v0.96+ で OTel SDK config-based telemetry が安定、 `readers` 配下に複数 reader 並立可能)

`kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl` の `config.service:` に追加 (= 既存 `telemetry.metrics.readers` を override する形):

```yaml
config:
  service:
    telemetry:
      metrics:
        readers:
          # Loopback: 自分自身の otlp receiver に push、 traces / logs と同じ pipeline で
          # Mimir に流す (= ただし Mimir 側は依然 dotted label を reject するため、
          # OTel processor で `transform` / `attributes` を使い dotted name を underscore
          # に変換する pipeline を併設する必要がある = Option C の前提)
          - periodic:
              interval: 30s
              exporter:
                otlp:
                  protocol: grpc/protobuf
                  endpoint: http://localhost:4317
```

ただし single-tier の単独 Option A は Mimir 側が依然 dotted を reject するので Option C と組み合わせ必須。

**Option B: ServiceMonitor の `metricRelabelings` で dotted labels を underscore に rename**

```yaml
serviceMonitor:
  enabled: true
  extraLabels:
    release: kube-prometheus-stack
  metricsEndpoints:
    - port: metrics
      interval: 15s
      metricRelabelings:
        # Mimir-incompatible UTF-8 labels を _に rename
        - sourceLabels: [__name__]
          regex: "otelcol_.*|target_info"
          action: keep   # 対象を限定
        # 個別 dotted name を underscore form に統合
        # NOTE: action: labelmap で source 'server\.address' → target 'server_address' は
        #       Prometheus 2.x で label name に dot を含む regex が match しない問題があり、
        #       Prometheus 3.x の UTF-8 mode 下でないと動かない
```

注意点: `labeldrop` / `labelkeep` の regex は label name に対する match (= UTF-8 mode で動く)、 ただし Prometheus 3.x 仕様で複雑。 また Loki / Tempo 自身の self-metric (= `loki_*` / `tempo_*`) も同じ問題を抱える可能性があるため 全 OTel SDK-emit endpoint に影響。

- 利点: 設定変更が 1 file に局所化
- 欠点: dotted label を underscore に変換するためには Prometheus scrape config 側の `metric_name_validation_scheme: legacy` (= 推奨 = Option C) のほうが clean

**Option C (= 推奨): Prometheus scrape config を `legacy` validation で固定し、 全 scrape 入口で UTF-8 escape を有効化**

公式 docs: https://prometheus.io/docs/guides/utf8/

`kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` の `prometheus.prometheusSpec:` に追加:

```yaml
prometheus:
  prometheusSpec:
    # ... 既存 ...
    # Prometheus 3.x で UTF-8 受け入れる default 動作を停止、 scrape 時点で
    # underscore escape に変換 (= 後段 Mimir の Prometheus 2.x 互換 validator と整合)
    # https://prometheus.io/docs/guides/utf8/
    nameValidationScheme: legacy
    nameEscapingScheme: underscores
```

- 利点:
  - root に最も近い fix (= Prometheus 3.x が dotted を保持する default 挙動を、 Mimir downstream の能力に合わせて切り戻す single setting)
  - 同時に問題 1 で `server.address` のような Beyla 側 dotted attribute (= 万一発生した場合) も自動 escape
  - kube-prometheus-stack v84.x (Prometheus 3.x default) の panicboat 構成全体で uniform 適用
  - Mimir / Loki / Tempo の self-metric も同 mechanism で escape
- 欠点:
  - Prometheus 3.x の "UTF-8 metric names native" advancement を意図的に巻き戻す (= Prometheus → Mimir downstream の能力差を Prometheus 側で吸収する trade-off)
  - prometheus-operator が `nameValidationScheme` field を まだ expose していない可能性 (= CRD field name を chart で確認の必要)
- 公式 ref:
  - https://prometheus.io/docs/guides/utf8/
  - https://prometheus.io/docs/prometheus/latest/configuration/configuration/ (= `metric_name_validation_scheme` / `metric_name_escaping_scheme`)

**推奨: Option C (= Prometheus 3.x validation scheme を legacy 固定)**

理由: (1) 全 OTel SDK-based component (= OTel Collector / Tempo / 将来 Loki / 各 application OTel SDK の Prometheus exporter) に uniform に効く、 (2) Option B のように OTel Collector 個別の serviceMonitor で対症療法せず Prometheus 入口で systematic、 (3) Mimir が UTF-8 label name 対応を完了するまで (= 引き継ぎ Theme で track) の bridging。 ただし prometheus-operator CRD field の expose 状況を spec 段階で確認必要 (= 未 expose なら podMonitor / scrapeConfig CR の `nameValidationScheme:` を使う、 もしくは `additionalScrapeConfigs:` で直接 raw Prometheus YAML 注入)。

---

## 問題 3: Beyla traces 片肺

### Root cause (確定 = 確度高い 多重要因)

実観測の事実列挙:

1. Tempo に存在する `service.name` は `nginx` のみ (= 1 値)、 nginx 由来 traces 840 件 storage 済
2. Mimir に存在する Beyla `service_name` は `nginx`, `frontend`, `reverse-proxy` の 3 値、 monolith 不在
3. Beyla pod 別 `target_lang`: `generic` (= nginx 系)、 `nodejs` (= frontend) のみ。 `ruby` の `beyla_build_info` は 0 (= Beyla の ruby prober が attached してから build_info を emit していない)
4. Beyla log: ruby process に対しては `instrumenting process` log のみ、 `Launching p.Tracer` (= generic prober) や `Script successfully injected` (= nodejs prober) のような prober 起動 log が出ない
5. `http_client_request_*` (= 外向 HTTP) は frontend と reverse-proxy にだけ存在 (= nginx は server-only、 ruby/monolith は gRPC = HTTP/2 + ConnectRPC で生 HTTP/1.1 trace は emit されない)
6. Beyla 公式 compatibility table: Ruby は "Supported with limitations"、 distributed traces 非対応、 gRPC は Go のみ "Recommended"、 他言語は明示なし
7. nginx 5 traces が span 0 件 = Tempo `/api/search` の挙動仕様 (= bare search は span 列挙せず metadata のみ返す)、 単 trace `/api/traces/<id>` で取得すると span は正常存在 (= 確認済)
8. OTel Collector の起動直後に 1 つの pod (= nhgtf) で Tempo 4317 への接続が `connect: operation not permitted` で reject される一過性 (= Cilium L4 LB policy 初期化 race と推測、 現時刻では再現せず)、 `otelcol_receiver_accepted_spans_total` は ~2 spans/sec 安定流入

### Hypothesis 整理 (= 確度別)

**Hypothesis A (確度 90%): Beyla の Ruby/gRPC 非対応 + Mimir reject 巻き込み 複合**

- monolith (= Ruby + gruf gRPC) → Beyla の Ruby prober は HTTP のみ trace、 ConnectRPC over h2c (= h2c = HTTP/2 cleartext) を捕捉できない → そもそも span / metric を emit しない (= 既知 limitation)
- frontend (= NodeJS + Next.js HTTP) → Beyla の nodejs prober (= `Script successfully injected` 確認済) は span を emit、 OTel Collector も `otelcol_receiver_accepted_spans_total` で 2 spans/s 受信、 ただし Tempo の `service.name` には `frontend` 不在 = Mimir の dotted-label reject による副作用で OTel Collector の trace pipeline は健全だが metric pipeline 出力が観測できないため誤検出 している可能性、 もしくは frontend からの実 application traffic が極小で span が 5-10 個程度しか溜まっていない (= Tempo block flush までに時間)
- reverse-proxy (= nginx generic) → server-only nginx で generic prober は attach 済、 ただし application traffic 量が現状ほぼ 0 (= Mimir で rate=0) のため span emit がない
- nginx (= demo) → 唯一 application traffic がある (= rate=0.7 req/s)、 Tempo に 840 traces 流入

**Hypothesis B (確度 8%): Tempo metrics-generator processor 起動による generator queue overflow**

- 直近 PR #345 で metrics-generator + service_graphs processor 投入、 multitenancy OFF + overrides defaults で起動。 metrics-generator が generator queue を blocking 消費し、 receiver からの ingester forward が slow → drop。 ただし観測 evidence (= `inspected_spans=0` は Tempo search 仕様であって drop の証拠ではない) は薄い

**Hypothesis C (確度 2%): Beyla → OTel Collector の trace pipeline 片方向 drop**

- 起動直後の Cilium policy race による Tempo 4317 unreachable は確認、 ただし現時刻は OK。 これは 過去 transient で root cause ではない

### Best practice fix options

**Option A: 「想定どおりの動作」を 文書化し、 Beyla の対象を HTTP traffic のある service に限定する**

Beyla 公式 distributed traces compatibility: https://grafana.com/docs/beyla/latest/

`kubernetes/components/beyla/production/values.yaml.gotmpl` の `discovery` を 3.x style に更新 + `exports` 明示:

```yaml
config:
  data:
    discovery:
      # Beyla 3.x 推奨 syntax (= 旧 `services:` は deprecated)
      instrument:
        - k8s_namespace: default
          # monolith は Ruby gRPC server で Beyla の HTTP/gRPC tracing 非対応、
          # metric noise を避けるため exclude_instrument で除外
      exclude_instrument:
        - k8s_deployment_name: monolith
```

- 利点: noise 排除 + 公式 sanctioned 設定。 Ruby/gRPC の 制限を spec 上 explicit
- 欠点: monolith trace は OTel SDK L1 (= 6-2 で Gemfile に opentelemetry-instrumentation-all) + L2 gruf custom interceptor (= 6-3 F2 scope) の 2-layer 体制に依存
- 公式 ref: https://grafana.com/docs/beyla/latest/configure/service-discovery/

**Option B: Beyla 3.x の `routes` + sampling 明示化 (= 安全側の 100% sampling 保証)**

Beyla 公式 sampling: https://grafana.com/docs/beyla/latest/configure/sample-traces/

```yaml
config:
  data:
    otel_traces_export:
      endpoint: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
      protocol: grpc
      interval: 5s
      max_export_batch_size: 512
      sampler:
        # default は parentbased_always_on (= 100% root)、 明示 declare
        name: parentbased_always_on
    routes:
      unmatched: heuristic
      # 既知 application route patterns を明示宣言 (= unknown route の grouping を
      # /api/v1/* など意図する group に丸める)、 cardinality 制御の副次効果
      patterns:
        - /
        - /api/*
```

- 利点: Phase 6-3 後の application route 拡大時に span 取りこぼし / cardinality 増殖の予防
- 欠点: 現状の attach 状況には直接効かない (= 既に attach 成功した nginx 以外の trace 不在は sampling のせいではない)

**Option C: 並行する Mimir 受け入れ修正 (= 問題 2 Option C) で観測精度向上 → reactive 判定**

問題 2 Option C で `nameValidationScheme: legacy` 投入 → Mimir に `otelcol_*` self-metric が流入 → `otelcol_receiver_accepted_spans_total{exporter="otlp_grpc/tempo"}` / `otelcol_exporter_sent_spans_total` / `otelcol_processor_dropped_spans` を Grafana で観測 → 「frontend / reverse-proxy 由来 span が Beyla → OTel Collector → Tempo の どこで消えているか」を機械的に切り分け

- 利点: root cause 確定が データ駆動になる、 6-3 application traffic 投入後に reactive で対応できる
- 欠点: 観測のみで 直接 fix にはならない (= 問題 1/2 fix に組み込まれる)

**推奨: Option A + Option C 併用**

理由:

- Hypothesis A (= Beyla の Ruby/gRPC 非対応) は 設定問題ではなく Beyla 自体の能力 limitation、 これに対する best practice は「対象を Beyla の得意領域 (= HTTP server / Go gRPC) に絞り、 残りは OTel SDK L1+L2 で cover する」設計 = Option A の `exclude_instrument: monolith`
- frontend / reverse-proxy が Tempo に span 不在の件は application traffic が現状ほぼ 0 (= reverse-proxy への smoke test 以外実トラフィック皆無、 Mimir で rate=0 確認) という traffic 量 問題、 設定問題ではない可能性が極めて高い。 6-3 で develop.panicboat.net 公開 + application 実トラフィック投入後に再 validation
- Option C は問題 2 Option C 投入で 副次的に達成 (= 別 work 不要)

**Beyla 復活 (引き継ぎ #31) との関係**: 引き継ぎ doc では「Beyla 復活 investigation」と書かれているが、 本調査では Beyla DaemonSet は 2/2 Running、 attach も成功、 metrics 流入も成功。 「復活」概念自体が古い = Phase 6-1 期の状態を反映していて、 現状は `Beyla 3.x の Ruby/gRPC 非対応という設計 limitation を明示認識する` ことが best practice。

---

## 全体 pipeline 図 (= 現状)

```
Application Pod (default namespace)
├─ monolith (Ruby gruf gRPC)
│   ├─ eBPF attach: 成功 (= "instrumenting process type=ruby service=monolith")
│   ├─ Beyla prober: 起動せず (= ruby prober は HTTP のみ、 gRPC は対応外)
│   ├─ HTTP metrics: 0 件 (= 上記理由)
│   ├─ traces: 0 件
│   └─ OTel SDK L1 (Gemfile): 6-2 で導入済、 L2 gruf custom interceptor は 6-3 F2 scope
│
├─ frontend (NodeJS Next.js)
│   ├─ Beyla nodejs prober: 起動成功
│   ├─ HTTP metrics: Mimir に 1 series 流入 (= 但し rate=0、 traffic 不在)
│   └─ traces → OTel Collector OTLP gRPC 4317
│
├─ reverse-proxy (nginx)
│   ├─ Beyla generic prober: 起動成功
│   ├─ HTTP metrics: Mimir に 1 series 流入 (= rate=0)
│   └─ traces → OTel Collector OTLP gRPC 4317
│
└─ nginx (demo, Phase 5-2 残)
    ├─ Beyla generic prober: 起動成功
    ├─ HTTP metrics: Mimir に 2 series、 rate=0.7 req/s
    └─ traces → OTel Collector OTLP gRPC 4317 → Tempo OTLP gRPC 4317 ✅ 840 traces stored

Beyla DaemonSet (monitoring ns)
├─ Prometheus /metrics :9090 → ServiceMonitor → Prometheus 3.11.3
│   └─ remote_write → Mimir distributor
│       ├─ http_server_*_bucket: 31 labels で reject ❌ (= 問題 1)
│       └─ http_server_*_count / _sum: 30 labels で borderline 通過 ⚠️
└─ traces → OTel Collector OTLP gRPC

OTel Collector DaemonSet (monitoring ns、 v0.151.0、 mode=daemonset、 contrib)
├─ receivers: otlp (gRPC/HTTP)、 filelog (= log collection)
├─ processors: memory_limiter, k8sattributes, resource, batch
├─ exporters
│   ├─ otlp_grpc/tempo (= Beyla / OTel SDK の traces) → Tempo
│   └─ otlp_http/loki (= filelog の logs) → Loki gateway
├─ service.telemetry.metrics.readers[].pull.exporter.prometheus :8888
│   └─ 自前 ServiceMonitor scrape → Prometheus → remote_write → Mimir
│       └─ dotted labels (server.address / host.name / k8s.pod.name 等) で reject ❌ (= 問題 2)

Tempo (= monolithic mode、 receivers.otlp.grpc 4317、 metricsGenerator service_graphs)
├─ traces 840 件 (= 全て nginx 由来)
└─ metrics-generator → traces_service_graph_* → remote_write → Mimir
    └─ traces_service_graph_* metric: dot 含まないので reject なし ✅
```

---

## 注意点 / 副次効果

### Option 選択時の cross-issue 影響

| Option | 同時 fix 効果 |
|---|---|
| **問題 1 Option A** (= Beyla `attributes.select`) | (a) Beyla 自身の CPU / mem 削減、 (b) 将来 Tempo の `traces_service_graph_*` で同じ k8s_* labels が emit されるが、 Tempo metrics-generator は独自 label set のため影響なし |
| **問題 2 Option C** (= Prometheus `nameValidationScheme: legacy`) | (a) 問題 3 の OTel Collector self-metric が Mimir 流入し、 Beyla→OTel Collector→Tempo の pipeline 健全性を `otelcol_exporter_sent_spans_total` 等で可観測化、 (b) 将来 Loki / Tempo / application OTel SDK が emit する dotted labels も uniform に escape、 (c) Mimir `target_info` series (= OTel resource attribute holder) も同経路で escape され 副作用消失、 (d) 引き継ぎ #21 (= Mimir limit 雪だるま) 自体が「label 数 reduction → limit 不要」と「dotted reject → escape」の 2 axis で systematic 解消 |
| **問題 3 Option A** (= `exclude_instrument: monolith`) | (a) Beyla の Ruby prober による無駄な eBPF attach 試行を停止、 (b) 引き継ぎ #25 (= OTel Operator Ruby support、 chart 0.155.0+ 想定) と分離。 Ruby observability は OTel SDK L1+L2 で systematic 担当 |

### 適用順序の推奨

1. 問題 2 Option C を最初 (= Prometheus validation 修正)。 これで OTel Collector self-metric が Mimir に流入し、 「Beyla → Tempo pipeline の健全性メトリクス」が可視化される
2. 問題 1 Option A を次 (= Beyla `attributes.select`)。 hydrate + Beyla restart で 即時効果 (= reject 0 件確認)
3. 問題 3 Option A を最後 (= `exclude_instrument: monolith` + discovery 3.x style)。 Beyla restart + 引き継ぎ #31 概念 update を documentation

### 既知の副作用注意点

- 問題 2 Option C で `nameValidationScheme: legacy` 適用後、 `target_info` series は Prometheus 上で `host_name` / `k8s_namespace_name` 等 underscore 化された label を持つ。 Grafana dashboard で `{host.name=...}` を query している既存 panel があれば update 必要 (= panicboat dashboard は `kube-prometheus-stack-*` chart 提供で legacy label 前提のため互換)
- 問題 1 Option A で `k8s.pod.uid` 等 drop すると、 同 pod 内で deployment rollout 跨いだ series identity が `k8s.pod.name` ベース化される (= pod 再作成で名前変わるため series churn 増加可能性、 ただし Pod 名 = Deployment 名 + replicaset hash + 5 chars suffix で安定性十分)
- 問題 3 Option A で monolith を Beyla 対象外にすると、 Phase 7+ で Beyla が Ruby gRPC 対応した時に再有効化が必要 (= spec doc に "Beyla Ruby gRPC support 動向 watch" を引き継ぎ事項として 残す)

### Beyla 3.x discovery deprecation (= 副次)

現 `discovery.services` syntax は Beyla 起動 log で deprecation warning が出ている (= "discovery > services YAML property is deprecated and will be removed in a future version. Use discovery > instrument instead.")。 問題 3 Option A で同時に新 syntax (= `discovery.instrument`) に migration、 chart 1.16.7 が 新 syntax 対応済 (= chart template は raw passthrough なので Beyla binary version 1f27f83 = v3.14.0 が直接 解釈) を 1 PR で systematic 適用可能。

---

## 公式 reference 索引

- Beyla attributes selection: https://grafana.com/docs/beyla/latest/configure/metrics-traces-attributes/
- Beyla service-discovery (3.x): https://grafana.com/docs/beyla/latest/configure/service-discovery/
- Beyla distributed traces compatibility: https://grafana.com/docs/beyla/latest/distributed-traces/
- Beyla sampling: https://grafana.com/docs/beyla/latest/configure/sample-traces/
- Beyla overview (= language support matrix): https://grafana.com/docs/beyla/latest/
- OTel Collector internal telemetry (= v0.96+ readers config): https://opentelemetry.io/docs/collector/internal-telemetry/
- Prometheus UTF-8 + validation scheme: https://prometheus.io/docs/guides/utf8/
- Prometheus scrape config full spec: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Mimir limits doc: https://grafana.com/docs/mimir/latest/configure/about-runtime-configuration/ (= `max_label_names_per_series` / `max_label_value_length`)

---

## 関連 file paths (= 修正候補)

- `kubernetes/components/beyla/production/values.yaml.gotmpl` (= 問題 1 Option A + 問題 3 Option A 該当)
- `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` (= 問題 2 Option C 該当)
- `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl` (= 問題 2 Option A 代替候補、 ただし Option C 採用なら未変更)
- `kubernetes/components/mimir/production/values.yaml.gotmpl` (= 未変更で良い、 雪だるま路線を採用しないため)
