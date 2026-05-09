# EKS Production: Beyla Foundation (Phase 5-1) Design

> **Phase**: roadmap Phase 5 (End-to-end validation) の Sub-project 5-1 (= 最初 sub-project)
>
> **Prerequisites**: Phase 4 完了 (= cert-manager + ESO + Reloader + Grafana 認証ゲート + 公開) + Mimir cardinality fix (= PR #314)
>
> **Goal**: `grafana/beyla` chart を `monitoring` namespace に DaemonSet で deploy、`default` namespace の application Pod を eBPF auto-instrumentation で観測する基盤を確立する。Phase 5-2 nginx 投入時に **Beyla が即時に nginx HTTP request span を Tempo に送る + RED metrics を Prometheus → Mimir に流す** 状態を作る。引き継ぎ事項 #6 part 1 (= Beyla deploy) を解消し、Phase 4-3 L6 で発覚した Tempo empty 状態の root cause (= trace source 不在) を Phase 5-2 で完全解消する prerequisite。

---

## Context

### Phase 4 + Mimir cardinality fix 完了後の状況 (= 5-1 brainstorming 開始時の前提)

- ✅ cert-manager + selfsigned-cluster-issuer (= Phase 4-1)
- ✅ External Secrets Operator + ClusterSecretStore `aws-secrets-manager` + Reloader (= Phase 4-2)
- ✅ oauth2-proxy 4 instances + 4 monitoring UIs 公開 + Grafana adminPassword ESO 化 (= Phase 4-3)
- ✅ Mimir replication_factor: 1 + cardinality limit 500K + apiserver bucket drop (= PR #312 + #314)
- ✅ OpenTelemetry Collector traces pipeline ready (= 4-3 で deploy 済、Beyla からの OTLP 受信可能)
- ✅ Tempo + Loki + Prometheus operator + kube-prometheus-stack ready
- 🔜 Phase 5-1 で Beyla deploy → 5-2 nginx で end-to-end validate

### Roadmap Phase 5 完了条件 (= 13 checklist) の Phase 5-1 配分

| # | Checklist 項目 | 担当 sub-project |
|---|---|---|
| 10 | **Beyla が nginx HTTP request span を Tempo に送信** | **5-1 (= deploy 部分) + 5-2 (= 実 trace 流入で full validate)** |
| 1-9, 11-13 | その他 12 項目 | Phase 5-2 (= nginx 投入時) |

### roadmap 引き継ぎ事項 (= Phase 4-3 完了時の 17 項目) の Phase 5-1 配分

| # | 項目 | 5-1 での扱い |
|---|---|---|
| 4 | OTel Operator deploy 検討 | **本 spec で evaluation 結果 = "monorepo migration 時に同時 deploy" と判定**、Phase 5-1 では deploy せず |
| 6 | Beyla deploy + OTel Collector metrics pipeline | **本 spec で part 1 (= Beyla deploy) を解消**、part 2 (= OTel Collector metrics pipeline 拡張) は Phase 6+ 引き継ぎ #10 と統合 |
| その他 15 項目 | (= 各 Phase 6+ 引き継ぎ) | 5-1 では touch なし |

---

## Architecture

### High-level architecture

```
                                           Phase 5-2 (= nginx)
                                                  │
                                                  ▼
                                            default namespace
                                            ┌──────────────┐
                                            │  nginx Pod   │
                                            │  (port 80)   │
                                            └──────┬───────┘
                                                   │
              ┌────────────────────────────────────┘
              │ eBPF probes attach (= host-level)
              │ via hostPID + privileged container
              │
   ┌──────────▼──────────────┐
   │  Beyla DaemonSet        │
   │  (= 1 Pod per node)     │
   │  - hostPID: true        │
   │  - preset: application  │
   │  - discovery: default ns│
   │  - filter: kube* exclude│
   └──────────┬──────────────┘
              │
       ┌──────┴────────────────┐
       │                       │
       │ OTLP gRPC :4317       │ /metrics :9090
       │ (traces)              │ (Prometheus scrape format)
       │                       │
       ▼                       ▼
  OpenTelemetry           ServiceMonitor
  Collector              (= kube-prometheus-stack)
       │                       │
       │ traces                │ Prometheus scrape
       ▼                       ▼
    Tempo                  Prometheus
    (= S3)                     │
                               │ remote_write (= writeRelabelConfigs filter)
                               ▼
                            Mimir
                            (= S3、PR #312 RF=1 + PR #314 limits 500K)
                               │
                               │ Grafana datasource
                               ▼
                          Grafana dashboard
                          (= Phase 4-3 公開済、auth.proxy mode で SSO)
```

### Trace flow (= Phase 5-2 で nginx 投入時に動作開始)

1. nginx Pod が `default` namespace で起動 (= Phase 5-2)
2. Beyla DaemonSet が Pod 探索 (= K8s API watch)、eBPF probes を nginx process に attach
3. nginx HTTP request 受信 → Beyla eBPF が span 生成
4. Beyla → OTLP gRPC :4317 → OpenTelemetry Collector (= `monitoring` namespace の既存 Collector)
5. OTel Collector traces pipeline → otlp_grpc/tempo exporter → Tempo S3 backend
6. Grafana で **Explore → Tempo datasource → search by service.name** で nginx traces 表示

### RED metrics flow (= Phase 5-2 で動作開始)

1. nginx HTTP request 観測 → Beyla eBPF が RED metrics (= Rate / Errors / Duration) 生成
2. Beyla `/metrics` :9090 で Prometheus exposition format expose
3. ServiceMonitor (= kube-prometheus-stack の serviceMonitorSelector match) → Prometheus が scrape
4. Prometheus → remote_write (= PR #314 writeRelabelConfigs filter 適用) → Mimir
5. Grafana で **Explore → Mimir datasource → query `http_server_request_duration_seconds_*`** 等で RED metrics 表示

### Phase 5-1 単独 deploy 時の状態

- Beyla DaemonSet 起動成功 (= eBPF probes attach 可能、discovery loop 動作)
- ただし `default` namespace に **trace 対象 Pod 不在** (= Phase 5-2 で nginx 投入まで待ち)
- → Tempo trace 0 件継続 (= Phase 4-3 で発覚した状態のまま、Phase 5-2 で解消)
- → Beyla 自 metrics (= controller stats, eBPF stats) のみ Mimir に流入 (= Beyla deploy validation の primary signal)
- → Phase 5-1 deploy validation の **smoke test として test Pod (= nginx:latest 一時 deploy)** を post-flight に追加、Beyla pipeline 動作確認

---

## Components & File Structure

### Component matrix

| Component | New / Modified | namespace | 役割 |
|---|---|---|---|
| **Beyla** chart | 新規 component (production)、local 既存 | `monitoring` (= 既存、namespace 新規作成なし) | eBPF auto-instrumentation で `default` namespace の Pod を観測、traces + metrics を生成 |
| **AWS terragrunt stack** | **不要** | — | Beyla は AWS access 不要 (= S3 storage 不在、IAM role 不要、Pod Identity Association 不要) |
| **kustomization overlay** | **不要** | — | chart 範囲外 resource なし (= ExternalSecret / ConfigMap 等 不要) |

### File structure (= 新規作成 / 変更)

**新規 (= K8s component `beyla/production`)**:

```
kubernetes/components/beyla/production/
├── helmfile.yaml                  # grafana/beyla chart deploy
└── values.yaml.gotmpl             # production-specific config
                                   #   - preset: application (= local 踏襲)
                                   #   - discovery.services: default namespace のみ、open_ports 省略 (= 全 listening port auto-discover)
                                   #   - otel_traces_export → opentelemetry-collector.monitoring:4317
                                   #   - prometheus_export :9090 + serviceMonitor enable
                                   #   - filter.network: kube* / *prometheus* / *grafana* / *mimir* / *loki* / *tempo* exclude
                                   #   - resources: small DaemonSet sizing
                                   #   - priorityClassName: system-cluster-critical
```

**自動生成 (= production hydrate output)**:

```
kubernetes/manifests/production/beyla/{kustomization.yaml, manifest.yaml}     # 新規
kubernetes/manifests/production/kustomization.yaml                             # 修正 (= ./beyla auto-insert、alphabetical order)
```

**変更しないファイル**:

- `kubernetes/components/beyla/local/*` (= local 環境の既存 deploy はそのまま、Phase 5-1 で touch なし)
- `kubernetes/components/beyla/namespace.yaml` (= **新規作成不要、`monitoring` namespace 既存活用**)
- `aws/*` (= 全 terragrunt stack、AWS access 不要)
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= namespace 新規作成なし、index 変更不要)
- 他 K8s components

### Beyla chart-deployed resources (= helmfile template render output 想定)

| Resource | 個数 | 用途 |
|---|---|---|
| DaemonSet | 1 (= cluster の各 node に 1 Pod、~5-7 Pods total) | eBPF probes attach + discovery loop |
| ServiceAccount | 1 | K8s API access for namespace / Pod discovery |
| ClusterRole + ClusterRoleBinding | 各 1 | Pod / Service / Namespace read 権限 |
| Service | 1 | ServiceMonitor scrape target (= /metrics :9090) |
| ServiceMonitor | 1 | Prometheus scrape config (= `release: kube-prometheus-stack` label match) |
| ConfigMap | 1 | Beyla config (= configFile YAML) |

### values.yaml.gotmpl 概略 (= local 踏襲 + production 修正点)

```yaml
# Beyla eBPF Auto-Instrumentation Configuration for production

# preset: application (= local 踏襲、application-level metrics + traces focus)
preset: application

config:
  data:
    # Traces → OTel Collector (= Phase 4-3 で deploy 済 traces pipeline 経由 Tempo)
    otel_traces_export:
      endpoint: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
      protocol: grpc
      interval: 5s

    # Metrics は Prometheus /metrics 経由 (= ServiceMonitor で scrape)
    # NOTE: otel_metrics_export は Phase 4-3 で OTel Collector の metrics pipeline が
    # debug exporter (= 意図的、Mimir 接続未設定) のため設定しない。
    prometheus_export:
      port: 9090
      path: /metrics

    # Service Discovery (= default namespace の全 application Pod、open_ports 省略で全 listening port auto-discover)
    # microservice 追加時に Beyla config 更新不要 (= 新 service の任意 port が自動 trace 対象)
    discovery:
      services:
        - k8s_namespace: "default"
          # NOTE: open_ports は明示的に省略。default namespace は application 専用 (= infra Pod 不在)、
          # 全 listening port auto-discover で運用 friction 最小。

    routes:
      unmatched: heuristic

    attributes:
      kubernetes:
        enable: true

    # Network filter (= kube* / *prometheus* / *grafana* / *mimir* / *loki* / *tempo* 等の infra Pod を exclude)
    filter:
      network:
        k8s_dst_owner_name:
          not_match: "{kube*,*prometheus*,*grafana*,*mimir*,*loki*,*tempo*}"
        k8s_src_owner_name:
          not_match: "{kube*,*prometheus*,*grafana*,*mimir*,*loki*,*tempo*}"

# Resources (= small DaemonSet、~5-7 Pods total)
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 384Mi

# Priority Class (= Phase 4-2 ESO / Reloader / oauth2-proxy と同 priority)
priorityClassName: system-cluster-critical

# ServiceMonitor (= Beyla 自 metrics + RED metrics を kube-prometheus-stack 経由 Mimir へ)
serviceMonitor:
  enabled: true
  labels:
    release: kube-prometheus-stack

# Service (= ServiceMonitor scrape target)
service:
  enabled: true
```

NOTE: Phase 4-3 で確立した L1 / L2 / L4 lessons を Plan で再適用 (= chart 1.16.6 のキー verify、`metrics.serviceMonitor.*` 等の chart-fixed value 確認、急進化 chart の design assumption gap)。

---

## Decisions

7 件、brainstorming で確定:

| # | Decision | 採用 | 採用理由 |
|---|---|---|---|
| 1 | Phase 5 全体 decomposition | 3 sub-projects (= 5-1 Beyla → 5-2 nginx → 5-3 rightsizing) | Phase 4 の 3 decompose pattern 踏襲、5-1 で観測 stack を ready 状態にしてから nginx 投入、rightsizing は application traffic 観測後 (= 引き継ぎ #9 自体が "nginx + 観測 burst 後" と明記) |
| 2 | OTel Operator inclusion | **不採用** (= Phase 6+ monorepo migration 時に同時 deploy) | nginx (= Phase 5-2 target) は Beyla の eBPF instrumentation で cover、`Instrumentation` CR は SDK-based application の use case、operational footprint 最小 |
| 3 | Beyla discovery scope | `default` namespace のみ | scope minimal、Phase 5-2 nginx target 限定、infra namespace の trace noise 回避、将来 application 追加時に discovery rules 拡張容易 |
| 4 | Beyla discovery `open_ports` | **省略 (= 全 listening port auto-discover)** | microservice 追加時の port list maintenance 運用回避、`default` namespace scope + network filter で infra noise 回避 |
| 5 | Traces export | OTel Collector 経由 (= OTLP gRPC :4317) → Tempo | Phase 4-3 既存 traces pipeline 活用、Fluent Bit logs path と同 OTel Collector 経由 pattern で consistency |
| 6 | Metrics export | Prometheus /metrics endpoint :9090 + ServiceMonitor → Prometheus → remote_write → Mimir | OTel Collector の `metrics` pipeline = `debug` exporter (= Phase 4-3 design intent 維持)、ServiceMonitor pattern は kube-prometheus-stack の established remote_write 経由、Phase 4-3 で発覚した OTLP label invalid issue 回避 |
| 7 | AWS terragrunt 新規 stack | **不要** | Beyla は AWS access 不要 (= no S3 storage、no IAM role、no Pod Identity Association)、Phase 5-1 は **完全に K8s component のみ** で完了 |

---

## Post-flight Check

deploy 後 verify、~12 項目:

### A. Infrastructure layer (= 5 分以内)

1. Beyla DaemonSet status: `kubectl get ds -n monitoring beyla-beyla` で `DESIRED == READY` (= 全 node に 1 Pod、~5-7 Pods total)
2. Beyla Pod 全 Running、`/internal/status` health check 200 (= chart default health endpoint)
3. Beyla Pod に `hostPID: true` + `privileged: true` (= eBPF 必要 capability)
4. ServiceAccount + ClusterRole + ClusterRoleBinding deploy 済 (= K8s API discovery 用)

### B. Telemetry pipeline layer (= 10 分以内)

5. Beyla Pod logs に discovery loop 動作 log (= 例: `discovered application` or `service discovery: starting watcher`)
6. ServiceMonitor `beyla-beyla` 存在 + Prometheus が scrape (= `kubectl exec -n monitoring deployment/kube-prometheus-stack-prometheus -- promtool query instant http://localhost:9090 'up{job="beyla.*"}'` で `1`)
7. Beyla 自 metrics が Mimir に流入 (= Grafana で `beyla_internal_*` query)
8. OTel Collector traces pipeline は **既存動作維持** (= Beyla からの traces 受信 ready、ただし Phase 5-1 では trace source 不在で実 trace 流入なし)

### C. Phase 5-2 prerequisite layer (= 30 分以内)

9. **`default` namespace に test Pod 配置 + nginx-like HTTP request 生成** (= optional smoke test)
   - 簡易方法: `kubectl run -n default test-nginx --image=nginx:latest --port=80 --restart=Never` + `kubectl exec` で curl
   - Beyla が Pod discover → eBPF probe attach → trace 生成
   - Tempo に traces 流入確認 (= Grafana Explore で nginx service.name search)
   - **smoke test 完了後に test Pod 削除** (= Phase 5-2 で正式 nginx 投入)
10. Phase 4-3 Tempo empty issue (= L6) の **partial 解消確認** (= test Pod 由来 trace が Tempo に流入することで Beyla pipeline 動作 confirm)

### D. Regression check

11. 既 deploy 済 component (= cert-manager / ESO / Reloader / oauth2-proxy / Mimir / Loki / Tempo / OpenTelemetry Collector / etc.) の Pod 全部 Running 維持
12. Grafana で既存 dashboard query が動作 (= PR #312 RF=1 + PR #314 cardinality limit + bucket drop の効果維持)

---

## Rollback Patterns

| Pattern | 適用条件 | 操作 |
|---|---|---|
| **A. Standard rollback** | Phase 5-1 全体を巻き戻したい | Flux suspend → 5-1 merge commit を revert PR → resume |
| **B. Beyla disable (= chart default に近い state)** | Beyla 由来 issue (= eBPF probe 失敗 / resource consumption 過大) のみ、observability stack は維持 | values.yaml.gotmpl で `enabled: false` (chart top-level) or DaemonSet `replicas: 0` に変更、revert で元に戻す |

---

## Risks & Mitigations

| Risk | mitigation |
|---|---|
| **eBPF probe attach 失敗** (= kernel version 不適合 / hostPID 権限不足) | Beyla chart 1.16.6+ の supported kernel 範囲 (= EKS AL2023 Linux 5.10+) を docs で確認、production cluster で `uname -r` で kernel version verify。失敗時は Pod logs で eBPF load error message を identify |
| **Beyla resource consumption が想定外に大きい** (= eBPF probe 数 × Pod 数で memory 増) | values で `resources.limits` を 384Mi 上限に設定、production で actual usage を Grafana の Beyla `beyla_process_*` metrics で観測、必要なら Phase 5-3 rightsizing で調整 |
| **DaemonSet が 全 node に schedule されない** (= taint 問題) | `tolerations` で `system-cluster-critical` priority class に整合する toleration を chart values で設定。確認方法: `kubectl get ds -n monitoring beyla-beyla` で `DESIRED == CURRENT == READY` |
| **Phase 5-1 単独 deploy 時 trace 0 件** (= nginx 不在で当然) | Section "Architecture" で明記済の expected state、smoke test (= post-flight #9) で Beyla pipeline 動作 confirm |
| **discovery `default` namespace に application 不在** (= 5-1 完了時点で nginx 未 deploy) | post-flight #9 の test Pod smoke test で Beyla discovery + trace generation 動作確認、production usage は Phase 5-2 nginx 投入で開始 |

---

## Out of Scope (= Phase 5-2 / 5-3 / Phase 6+ へ postpone)

### Phase 5-2 (= nginx + Ingress + ESO + HPA + KEDA) で扱う

| 項目 | Phase 5-2 で扱う理由 |
|---|---|
| **nginx Deployment + Service + Ingress** | Phase 5-2 の primary scope |
| **HPA (cpu: 50%) + 負荷 test** | nginx + Metrics Server の autoscale validation |
| **KEDA ScaledObject (Prometheus query ベース)** | Beyla deploy 後に Beyla RED metrics を ScaledObject の trigger metric に活用可能 |
| **ExternalSecret + Reloader rollout test** | Phase 4-2 / 4-3 で確立した secret rotation pattern を nginx で end-to-end validate |
| **Beyla による nginx HTTP request span が Tempo に流入確認** | 5-1 deploy 後の **end-to-end validation**、Phase 4-3 L6 で発覚した Tempo empty 完全解消 |

### Phase 5-3 (= rightsizing audit) で扱う

| 項目 | Phase 5-3 で扱う理由 |
|---|---|
| **Pod CPU requests audit + rightsizing (= 引き継ぎ #9)** | 5-2 nginx + 観測 burst 後に必要、5-1 / 5-2 完了で application traffic 観測 data が蓄積された状態で実施 |

### Phase 6+ で扱う

| 項目 | Phase 6+ で扱う理由 |
|---|---|
| **OTel Operator deploy** (= 引き継ぎ #4) | monorepo migration 時に Hanami / Next.js application の OTel SDK + `Instrumentation` CR を同時設計、Phase 5 では Beyla で代替 |
| **Beyla discovery scope 拡張** (= multi-namespace / annotation-based) | 将来 application が複数 namespace に拡散時、または fine-grained 制御要件発生時 |
| **Beyla traces の OTel Collector filter / processor** | 高 cardinality trace 削減、retention 制御等 (= 現 panicboat scale で不要、operational maturity 系) |
| **OTel Collector metrics pipeline → Mimir 接続** (= 引き継ぎ #6 part 2、#10 と統合) | 現 design intent (= metrics → debug) のまま、本格的 application metrics push 要件発生時に評価 |

---

## Phase 5 引き継ぎ事項 update (= 5-1 完了時)

| 項目 | 5-1 完了時の状態 |
|---|---|
| 1-3. gp3 / bucket-per-env / multi-tenant | Phase 6+ 引き継ぎ (= 不変) |
| **4. OTel Operator deploy 検討** | **Phase 6+ 引き継ぎに変更** (= 5-1 evaluation 結果 = "monorepo migration 時に同時 deploy" と判定、Phase 5 内 deploy せず) |
| 5. post-flight check 自動化 | Phase 6+ 引き継ぎ (= 不変、4-3 L5 design 指針継続) |
| **6. Beyla deploy + OTel Collector metrics pipeline** | **Phase 5-1 で part 1 解消** (= Beyla deploy 完了)、part 2 (= OTel Collector metrics pipeline 拡張) は Phase 6+ 引き継ぎ #10 と統合 |
| 7-8. Hubble flow logs / local Fluent Bit OTLP | Phase 6+ 引き継ぎ (= 不変) |
| **9. Pod CPU requests audit + rightsizing** | **Phase 5-3 で解消予定** |
| 10-17. その他 (= 4-3 で追加された 7 項目) | Phase 6+ 引き継ぎ (= 不変) |

= 5-1 完了で **引き継ぎ #6 part 1 (= Beyla deploy) を解消**、#4 (OTel Operator) は **evaluation 結果として Phase 6+ 引き継ぎに変更**。

---

## Sub-project 1-4-3 learnings 適用

- **L1 (= chart binary verify systematic step)**: Beyla chart `1.16.6` (= local) の latest stable version + ServiceMonitor key path + extraEnv 構造 / discovery config schema を Plan の Step 1-2 で確認
- **L2 (= chart capability assumption の限界、4-3 new)**: `discovery.services` の port wildcard / `open_ports` 省略の挙動を **Beyla docs full read で裏付け**、brainstorming で Approach 比較した `open_ports` 明示 vs 省略の technical feasibility を verify (= 本 brainstorming で実施済)
- **L3 (= Pod Identity webhook timing-sensitive injection、4-3 new)**: Beyla は Pod Identity 不要のため適用外、ただし DaemonSet rollout 時の **eBPF probe re-attach** に類似の timing pattern が存在する可能性、post-flight check で probe attach success を確認
- **L4 (= distributed system replica / RF 整合、4-3 new)**: Beyla は distributed ring 構造を持たない (= DaemonSet 1 Pod per node)、適用外
- **L5 (= post-flight end-to-end browser test、4-2 L5 extension)**: Phase 5-1 では trace source 不在で **smoke test (= test Pod) 経由で Beyla pipeline 動作確認** が必須、5-2 で nginx 正式投入時に full validation
- **L6 (= subagent-driven development cadence)**: Phase 5-1 は **single chart deploy** で task 数 minimal (= AWS / chart / hydrate の 3 layer split → AWS 不要なので 2 layer split)、subagent dispatch 数最小
- **4-1 L5 (= chart version placeholder pattern)**: spec で chart version `1.16.x` placeholder、Plan で latest stable 確認

---

## Phase 5 全体 perspective

| Sub-project | scope | runtime issues 想定 | 依存 |
|---|---|---|---|
| **5-1 Beyla deploy** (= 本 spec) | Beyla DaemonSet 1 chart deploy、AWS terragrunt 不要 | 0 件想定 (= chart 1 種類のみ、Pod Identity 不要、L1 chart binary verify で gap 発見可能) | Phase 4 完了 + Mimir cardinality fix (= PR #314) merged |
| **5-2 nginx + Ingress + ESO + HPA + KEDA** | nginx Deployment / Service / Ingress (= ALB) / ExternalSecret / HPA / KEDA ScaledObject、Phase 1-4 全 component を end-to-end validate (= 13 checklist) | 多 (= Phase 5 の core sub-project、複数 component integration) | 5-1 完了 |
| **5-3 rightsizing audit** | nginx + observability stack の actual traffic 観測後、Pod CPU requests audit、引き継ぎ #9 解消 | 0-1 件想定 (= audit + values 修正のみ) | 5-2 完了 + 数日の actual traffic 観測 |

---

## References

- Phase 4-3 spec: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`
- Phase 4-3 plan + learnings: `docs/superpowers/plans/2026-05-09-eks-production-grafana-auth-ingress.md`
- platform roadmap: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- Beyla local config (= 参考 baseline): `kubernetes/components/beyla/local/{helmfile.yaml, values.yaml}`
- Mimir cardinality fix (= prerequisite): `fix(eks): Mimir cardinality limit + apiserver bucket drop` (= PR #314)
- Beyla 公式 docs: <https://grafana.com/docs/beyla/latest/>
- Beyla services discovery: <https://grafana.com/docs/beyla/latest/configure/services-discovery/>
- OpenTelemetry Operator (= Phase 6+ 引き継ぎ参考): <https://github.com/open-telemetry/opentelemetry-operator>
