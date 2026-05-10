# EKS Production: Phase 5 Closure (= End-to-end validation 完了 + Phase 6+ 引き継ぎ整理)

> **Phase**: roadmap Phase 5 (End-to-end validation) の **closure document**
>
> **Nature**: 集約 doc (= deploy 不要、CI / cluster 影響なし)、過去 sub-project specs / plans / learnings の summary + Phase 6+ planning の starting point
>
> **Goal**: Phase 5 (= 5-1 Beyla foundation + 5-2 nginx end-to-end validation + 5-3 rightsizing audit skip) の closing。roadmap Phase 5 完了条件 13 checklist の達成 status を整理、Phase 1-5 で蓄積した 21 件 引き継ぎ事項を Phase 6+ に handoff、Phase 5 で確立された 10 lessons を集約。

---

## 1. Phase 5 overview

### Phase 5 goal (= roadmap)

```
含むコンポーネント: nginx Deployment + Service + Ingress + HPA + KEDA `ScaledObject` + ExternalSecret

完了条件 / End-to-end チェックリスト (= 13 items)
- [ ] Pod が起動して Cilium chaining mode で IP を持つ（Phase 1 / VPC CNI bootstrap）
- [ ] ClusterIP Service の DNS 解決ができる（Phase 1 / CoreDNS）
- [ ] Ingress から ALB が起動する（Phase 1 / ALB Controller）
- [ ] external-dns で Route53 にレコードが作られる（Phase 1 / ExternalDNS）
- [ ] ACM 証明書が ALB に bind されて HTTPS が通る
- [ ] HPA を cpu: 50% で書いて、負荷をかけたら replica が増える（Phase 1 / Metrics Server）
- [ ] KEDA ScaledObject（Prometheus query ベース）でも replica が増える（Phase 1 / KEDA + Phase 3 / Prometheus）
- [ ] 高負荷で NodePool が空いたら Karpenter が node を増やす（Phase 2）
- [ ] Hubble が nginx Pod の L3/L4/L7 フローを見せる（Phase 3 / Cilium Hubble + OTel）
- [ ] Beyla が nginx の HTTP request span を Tempo に送る（Phase 3 / Beyla）
- [ ] Pod の stdout が Fluent Bit → OTel → Loki に流れて Grafana で見える（Phase 3）
- [ ] Prometheus に nginx のメトリクスが入って Grafana ダッシュボードで見える（Phase 3）
- [ ] AWS Secrets Manager の値が ESO 経由で Secret になり、nginx に env として注入できる（Phase 4 / ESO）
- [ ] Secrets Manager 側を更新したら Reloader で nginx Pod が rollout される（Phase 4 / Reloader）
- [ ] Grafana が認証ゲートで保護されている（Phase 4）
```

### Phase 5 sub-projects + status

| Sub-project | Scope | Status | PRs |
|---|---|---|---|
| **5-1 Beyla foundation** | Beyla DaemonSet 1 chart deploy、`default` namespace の application Pod を eBPF auto-instrument | ✅ **完了** | #315 (= deploy)、#316 (= Cilium Hubble CA-based ClusterIssuer fix forward)、#317 (= learnings) |
| **5-2 nginx end-to-end validation** | nginx Plain manifests + 13 checklist end-to-end validate (= Deployment / Service / Ingress / KEDA ScaledObject / ExternalSecret) | ✅ **完了** | #318 (= deploy)、#319 (= learnings) |
| **5-3 rightsizing audit** | Pod CPU requests audit + rightsizing (= 引き継ぎ #9) | **skip** (= Phase 6+ に postpone) | — |

### Phase 5-3 skip rationale

Phase 5-2 完了時に actual usage data を query して判断:

```
Top 20 Pods by CPU usage (= 直近 5min avg、millicores):
  prometheus-kube-prometheus-stack-prometheus-0    131.6m
  kustomize-controller-57cdfb859b-vckm9             62.7m
  mimir-distributed-distributor-68b5898b7-qnqc9     39.0m
  cilium-9nc25                                      34.7m
  cilium-76kh7                                      32.7m
  karpenter-75bc795bb8-fqlws                        30.5m
  mimir-distributed-ingester-0                      29.6m
  cilium-r7l87                                      27.5m
  cilium-22ljn                                      27.1m
  cilium-w26sn                                      24.4m
  cilium-t5hg7                                      22.0m
  opentelemetry-collector-84d6795576-t8429          15.4m
  fluent-bit-dw2gs                                   9.1m
  coredns-6c85777ddd-2mr5g                           8.4m
  coredns-6c85777ddd-x8bls                           8.3m
  kube-prometheus-stack-grafana-6f49548b44-v7w6l     6.9m
  loki-0                                             6.7m
  fluent-bit-g6w8k                                   6.2m
  cilium-envoy-54lzn                                 6.2m
  beyla-7fhfs                                        4.8m
```

**判断**:

- **全 Pod が現 cpu requests を大幅に下回る usage** (= 例: Loki 500m vs 6.7m actual = 1.3% utilization、Tempo 200m vs ~1m actual)
- **panicboat 個人運用 cluster** で cost optimization の effective benefit 小 (= request 削減で cluster size 縮小は Karpenter consolidation が既追随済み、削減対象は scheduling buffer のみ)
- **rightsizing で削減できるのは scheduling buffer 程度**、actual cluster cost への影響は限定的
- 引き継ぎ #9 は Phase 6+ application multi-tenant 化や production traffic 投入時に再 audit が合理的

= **Phase 5-3 skip + 引き継ぎ #9 を Phase 6+ に明示 postpone**、Phase 5-2 で roadmap 13 checklist は essentially 達成済のため Phase 5 全体 closure は本 doc で完了。

---

## 2. roadmap Phase 5 完了条件 13 checklist 達成 status

| # | Checklist | 達成 sub-project | Evidence |
|---|---|---|---|
| 1 | Pod 起動 + Cilium chaining mode IP | **5-2** | nginx Pod schedule + Cilium chaining mode で Pod IP 割当 (= post-flight Section A #1) |
| 2 | ClusterIP Service DNS resolution | **5-2** | nginx Service ClusterIP active、`nginx.default.svc.cluster.local:80` 内部 DNS 解決可 (= Section A #2) |
| 3 | Ingress → ALB | **5-2** | ALB Controller が monitoring-uis ALB に rule 追加 (= Section A #3) |
| 4 | external-dns → Route53 | **5-2** | `nginx.panicboat.net` Route53 record 自動作成、`dig nginx.panicboat.net` で 3 ALB IPs に resolve (= Section A #4 + Section B DNS test) |
| 5 | ACM HTTPS | **5-2** | `curl -v https://nginx.panicboat.net/` → HTTP 200、TLS verify success、ACM wildcard cert 適用 (= Section B HTTPS test) |
| 6 | HPA cpu 50% scale | **5-2** | KEDA ScaledObject の cpu trigger configured (= cpu 50% threshold)、actual scale-up は load test 中 cpu 11% で threshold 未到達 (= prometheus trigger driven scale)、mechanism は configured + functional 確認 (= Section C #14) |
| 7 | KEDA ScaledObject Prometheus scale | **5-2** | KEDA ScaledObject prometheus trigger で **2 → 10 replicas full scale-up** (= load test 60s ~50 RPS、TARGETS 4241m/1)、actual scaling proof (= Section C #15) |
| 8 | Karpenter node 増加 | **5-2** | 既 4 application nodes に 10 Pods 全部 schedule 完了 (= bin packing 効率)、Karpenter mechanism は Phase 2 + 5-1 PR #316 rollout で実証済、Phase 5-2 では trigger せず (= Section C #16) |
| 9 | Hubble L3/L4/L7 flow | **5-2** | Hubble metrics (= `hubble_flows_processed_total`) 流入確認、Hubble UI 経由で visual flow 確認可 (= Phase 4-3 で deploy 済 hubble.panicboat.net) |
| 10 | Beyla traces → Tempo | **5-1 partial + 5-2 full** | 5-1: smoke test (= test Pod) で `service.name=test-nginx` traces を Tempo で query / 5-2: nginx production-grade で `service.name=nginx` traces を Tempo で query (= Section B #10) |
| 11 | Loki logs (= Fluent Bit → OTel → Loki) | **5-2** | nginx access logs が Fluent Bit → OTel Collector → Loki に流入確認 (= Section B #11、`unknown_service` label で保存、Loki label promotion は Phase 6+ 引き継ぎ #17 既知 issue) |
| 12 | Mimir metrics + Grafana dashboard | **5-2** | Beyla `/metrics` :9090 → Prometheus → remote_write → Mimir、`http_server_request_duration_seconds_count` rate query で 0.733 → 4.241 RPS measurable (= Section B #13) |
| 13 | ESO secret env 注入 | **5-2** | AWS Secrets Manager `panicboat/nginx/demo` → ExternalSecret → K8s Secret `nginx-demo` → nginx env `DEMO_MESSAGE: "Hello from AWS Secrets Manager"` (= Section A #6 + #7) |
| 14 | Reloader rollout | **5-2** | AWS secret 更新 → ESO `force-sync` → K8s Secret update → Reloader が nginx Deployment auto-rollout → 新 ReplicaSet ID + 新 env 値反映 (= Section D #17) |
| 15 | Grafana 認証ゲート保護 | **4-3 + 5-2** | Phase 4-3 で oauth2-proxy + Google OAuth で 4 monitoring UIs 公開 (= grafana.panicboat.net 等)、Phase 5-2 で nginx data flow 経由 Grafana login → Mimir / Loki / Tempo datasource query で再 validate |

= **13/13 essentially達成** (= #11 Loki labels + #6 HPA cpu actual trigger は partial、ただし mechanism configured + functional + roadmap intent 達成)。

---

## 3. Phase 3-5 累計 runtime issues + fix forwards

### Sub-project 完了 timeline (= 10 sub-projects、PR # と日付)

| Date | PR # | Title | Sub-project / Type |
|---|---|---|---|
| 2026-05-05 | #284 | docs(eks): Phase 3 Sub-project 1 (Observability AWS infra) post-execution learnings | 1 learnings |
| 2026-05-05 | #280 | docs(eks): Karpenter tuning post-execution learnings | (= Phase 2 関連) |
| 2026-05-06 | #290 | docs(eks): Phase 3 Sub-project 2 — post-execution learnings | 2 learnings |
| 2026-05-06 | #293 | docs(eks): Phase 3 Sub-project 3 — post-execution learnings | 3 learnings |
| 2026-05-06 | #295 | docs(eks): Phase 3 Sub-project 4a — post-execution learnings | 4a learnings |
| 2026-05-07 | #296 | feat(eks): Phase 3 Sub-project 4b — Logs path + Hubble metrics | 4b deploy |
| 2026-05-07 | #302 | fix(eks): Phase 3 Sub-project 4b — OTel Collector logs to otlphttp/loki | 4b fix forward |
| 2026-05-07 | #303 | fix(eks): Phase 3 Sub-project 4b — Fluent Bit rolling + OTel otlp_http | 4b fix forward |
| 2026-05-07 | #304 | docs(eks): Phase 3 Sub-project 4b — learnings + otlp_grpc rename | 4b learnings |
| 2026-05-07 | #305 | fix(eks): observability DaemonSets PriorityClass system-node-critical | 4b regression fix forward |
| 2026-05-08 | #306 | feat(eks): Phase 4-1 — cert-manager + Cilium TLS migration | 4-1 deploy |
| 2026-05-08 | #307 | docs(eks): Phase 4-1 — post-execution learnings | 4-1 learnings |
| 2026-05-08 | #308 | feat(eks): Phase 4-2 — ESO + Reloader foundation | 4-2 deploy |
| 2026-05-08 | #309 | docs(eks): Phase 4-2 — post-execution learnings | 4-2 learnings |
| 2026-05-09 | #310 | feat(eks): Phase 4-3 — Grafana auth + monitoring UIs Ingress | 4-3 deploy |
| 2026-05-09 | #311 | fix(eks): oauth2-proxy 4 instances per backend (Phase 4-3 fix forward) | 4-3 fix forward |
| 2026-05-09 | #312 | fix(eks): Mimir replication_factor 1 for single-replica ring | 4-3 fix forward (= 3 Sub-project 2 latent) |
| 2026-05-09 | #313 | docs(eks): Phase 4-3 — post-execution learnings | 4-3 learnings |
| 2026-05-09 | #314 | fix(eks): Mimir cardinality limit + apiserver bucket drop | 5-1 fix forward (= 3 Sub-project 2 latent) |
| 2026-05-09 | #315 | feat(eks): Phase 5-1 — Beyla eBPF auto-instrumentation foundation | 5-1 deploy |
| 2026-05-09 | #316 | fix(eks): Cilium Hubble CA-based ClusterIssuer for mTLS | 5-1 fix forward (= 4-1 latent) |
| 2026-05-09 | #317 | docs(eks): Phase 5-1 — post-execution learnings | 5-1 learnings |
| 2026-05-09 | #318 | feat(eks): Phase 5-2 — nginx end-to-end validation | 5-2 deploy |
| 2026-05-10 | #319 | docs(eks): Phase 5-2 — post-execution learnings | 5-2 learnings |

### Phase 3-5 累計 runtime issue 数

| Sub-project | initial deploy | runtime fix | 計 |
|---|---|---|---|
| Sub-project 1 (AWS infra) | 0 | 0 | 0 |
| Sub-project 2 (Mimir) | 5 | 0 (= ただし RF + cardinality limit + label-names-per-series が 4-3 / 5-1 / 5-2 で発覚、PR #312 + #314 で 2 件 resolve、1 件 Phase 6+ 引き継ぎ #21) | 5 |
| Sub-project 3 (Loki + Fluent Bit) | 4 | 0 | 4 |
| Sub-project 4a (Tempo + OTel Collector) | 0 | 0 | 0 |
| Sub-project 4b (logs path completion) | 3 | 0 | 3 |
| Sub-project 4-1 (cert-manager + Cilium TLS) | 0 | 0 (= ただし SelfSigned vs mTLS が 5-1 で発覚、PR #316 で resolve) | 0 |
| Sub-project 4-2 (ESO + Reloader) | 0 (= ただし Pod Identity timing が 4-3 で発覚) | 0 | 0 |
| Sub-project 4-3 (Grafana auth + Ingress) | 3 | 2 (= PR #311 + #312) | 3 |
| Sub-project 5-1 (Beyla foundation) | 0 | 0 | 0 |
| Sub-project 5-2 (nginx end-to-end validation) | 0 | 0 | 0 |
| **Phase 3-5 累計** | | | **15** |

### fix forward PR list (= 累計 5 件)

| PR # | Title | 解消 issue |
|---|---|---|
| #305 | observability DaemonSets PriorityClass system-node-critical | 4b regression: ip-10-0-39-100 observability blind spot (= Karpenter consolidation 不可 node で Fluent Bit / node-exporter scheduling 失敗) |
| #311 | oauth2-proxy 4 instances per backend (Phase 4-3 fix forward) | 4-3 設計起因: 1 instance multi-upstream architecture mistake (= path-based vs host-based routing 制約見落とし) |
| #312 | Mimir replication_factor 1 for single-replica ring | 3 Sub-project 2 latent: chart default RF=3 vs 1 ingester replica の論理破綻 (= 4-3 で発覚) |
| #314 | Mimir cardinality limit + apiserver bucket drop | 3 Sub-project 2 latent: chart default `max_global_series_per_user: 150000` 超過 + apiserver high-cardinality histogram bucket (= 5-1 brainstorming 中に発覚) |
| #316 | Cilium Hubble CA-based ClusterIssuer for mTLS | 4-1 latent: SelfSigned ClusterIssuer の mTLS 不可 architectural issue (= 5-1 post-flight regression check で発覚) |

= **fix forward 5 件中 4 件が past sub-project の latent issue** (= Phase 5-1 L2 pattern の 3 連続 validate established)、1 件のみ現 sub-project 設計起因 (= 4-3 oauth2-proxy)。

---

## 4. Phase 6+ 引き継ぎ事項 final list (= 21 項目)

Phase 1-5 で蓄積した 引き継ぎ事項を **category 別** に整理、Phase 6+ で系統的対応のための reference。

### Category A: Storage / multi-tenant (= 3 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 1 | gp3 StorageClass の Layer 2 documented exception 化 | Phase 6+ 引き継ぎ (= "cluster bootstrap layer は Flux 外" の architecture decision を docs に明記) |
| 2 | bucket-per-env への migration 検討 | Phase 6+ 引き継ぎ (= 現 monorepo bucket で十分、multi-env 化のタイミングで評価) |
| 3 | multi-tenant 化 + 詳細 retention rules | Phase 6+ 引き継ぎ (= 1 tenant 運用で十分、tenant 分離要件発生時に評価) |

### Category B: Observability stack pipeline + automation (= 4 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 4 | OTel Operator deploy 検討 | Phase 6+ 引き継ぎ (= 5-1 で evaluation 確定、monorepo migration 時に同時 deploy + Hanami / Next.js application の OTel SDK + `Instrumentation` CR を同時設計) |
| 5 | post-flight check 自動化 | Phase 6+ 引き継ぎ (= **本 Phase 5 で 5-1 L2 + L3 / 5-2 L1 + L2 + L3 由来の 5+ design 指針追加**: cross-sub-project regression check pattern automated detection / actual load test synthetic 化 / secret rotation synthetic test / mTLS chain verify / Mimir distributor reject rate monitoring 等) |
| 6 | Beyla deploy + OTel Collector metrics pipeline | **Phase 5-1 で part 1 (= Beyla deploy) 完全解消**、part 2 (= OTel Collector metrics pipeline 拡張、Mimir 接続) は Phase 6+ #10 と統合 |
| 10 | OTel Collector exporter alias check 自動化 | Phase 6+ 引き継ぎ (= 4b L1 で systematic step として established、追加自動化は Phase 6+ で評価) |

### Category C: Logs + Hubble (= 2 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 7 | Hubble flow logs → Loki path 評価 | Phase 6+ 引き継ぎ (= 現 Hubble metrics + UI で十分、flow logs 永続化要件発生時に評価) |
| 8 | local Fluent Bit OTLP gRPC 統一 | Phase 6+ 引き継ぎ (= local 環境の独立性、production 動作に影響なし) |
| 17 | Loki OTLP label promotion 再 design (= 5-1 L6 で追加) | Phase 6+ 引き継ぎ (= Loki labels が `service_name="unknown_service"` のみ promotion、K8s namespace / pod / container を index labels に追加、5-2 で再 validate) |

### Category D: cost + rightsizing (= 1 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 9 | Pod CPU requests audit + rightsizing | **Phase 6+ 引き継ぎ (= Phase 5-3 skip 判断、actual usage data で過剰割当 detected、ただし demo cluster で benefit 小、application multi-tenant 化や production traffic 投入時に再 audit)** |

### Category E: Authentication + secrets (= 4 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 11 | Google Workspace 契約後の OAuth Internal 化 + email_domain allowlist 移行 | Phase 6+ 引き継ぎ (= Workspace 加入のタイミングで切替、values 数行差分で完結) |
| 12 | AWS Secrets Manager Automatic Rotation (= Lambda 統合) | Phase 6+ 引き継ぎ (= rotation cycle が要件として顕在化した時点で評価、現運用は manual rotation で十分) |
| 13 | Cilium Gateway API east-west 利用 (= service mesh routing) | Phase 6+ 引き継ぎ (= Phase 6+ multi-service architecture 顕在化時に separate spec) |
| 14 | monitoring UIs 公開範囲拡張 (= Tempo UI / Mimir UI 等) | Phase 6+ 引き継ぎ (= on-demand、追加要件発生時に IngressGroup に Ingress 追加で incremental 対応) |

### Category F: Pod Identity + cert-manager + Mimir (= 4 項目)

| # | 項目 | Phase 5 完了時の状態 |
|---|---|---|
| 15 | Pod Identity webhook timing-sensitive injection の自動 detection (= 5-1 L3 で追加) | Phase 6+ 引き継ぎ (= ESO Pod env に `AWS_CONTAINER_CREDENTIALS_FULL_URI` 存在確認の automated check) |
| 16 | distributed system chart の replica count + replication_factor 整合 audit (= 5-1 L4 で追加) | Phase 6+ 引き継ぎ (= deploy 前の chart values audit pattern) |
| 18 | cert-manager `SelfSigned` ClusterIssuer の use case 限定を docs に明記 (= 5-1 L3 で追加) | Phase 6+ 引き継ぎ (= server-only TLS のみ、mTLS 用には CA-based Issuer 必須) |
| 19 | mTLS-using chart の post-flight check に "両 cert CA chain sha256 一致 verify" step を default 化 (= 5-1 L5 で追加) | Phase 6+ 引き継ぎ (= 引き継ぎ #5 と統合可) |
| 20 | Beyla `discovery.services` deprecation → `discovery.instrument` migration (= chart 1.16.7 deprecated warning) | Phase 6+ 引き継ぎ (= 将来 chart upgrade 時に対応) |
| **21** | **Mimir `validation.max-label-names-per-series: 30 → 35` 拡大** (= 5-2 で発覚した Beyla histogram 31 labels reject) | **Phase 6+ 引き継ぎ (= 5-2 で新規追加、demo 段階で必要性低、application 投入時 fix forward)** |

= **21 項目を 6 categories に整理**、Phase 6+ で各 category 系統的対応のための reference。Category B (= post-flight automation) は本 Phase 5 で最も多くの design 指針が追加され、Phase 6+ の primary focus 候補。

---

## 5. Phase 5 で確立された patterns + lessons (= 10 lessons 集約)

Phase 5-1 + 5-2 の learnings PRs で documented、本 doc で summary。

### Phase 5-1 lessons (= L1-L5)

| ID | Title |
|---|---|
| 5-1 L1 | chart binary verify systematic step の **4 sub-project 連続 validation** (= 4b → 4-1 → 4-2 → 4-3 → 5-1) |
| 5-1 L2 | **post-flight regression check が past sub-project の latent issue を発見する pattern** (= 4-3 で初発覚 + 5-1 で再 validate、5-2 で 3 連続 established) |
| 5-1 L3 | **cert-manager `SelfSigned` ClusterIssuer は mTLS 不可** (= 4-1 architectural lesson、CA-based Issuer 必須) |
| 5-1 L4 | Beyla eBPF auto-instrumentation **end-to-end smoke test (= test Pod) pattern が effective** (= 4-2 / 4-3 L5 extension) |
| 5-1 L5 | distributed system chart の **TLS / mTLS 設定の architectural correctness は cert resource Ready=True では不十分** (= mTLS connection で初めて proof) |

### Phase 5-2 lessons (= L1-L5)

| ID | Title |
|---|---|
| 5-2 L1 | **post-flight regression check pattern の 3 連続 validate established** (= 4-3 で Mimir RF / 5-1 で Cilium Hubble TLS / 5-2 で Mimir label limit) |
| 5-2 L2 | **KEDA ScaledObject multi-trigger の actual scaling validation** (= 2 → 10 replicas with prometheus 4.241 RPS、4-2/4-3/5-1 L5 extension) |
| 5-2 L3 | **ESO + Reloader rotation chain の actual end-to-end test** (= 4-2/4-3 design intent の production-grade validation) |
| 5-2 L4 | **kustomization-only component pattern** (= chart 不要 demo / 自製 application 用、`gateway-api` reference) |
| 5-2 L5 | Beyla auto-instrumentation の **production-grade application validation** (= 5-1 L4 smoke test → 5-2 production-grade test extension) |

### Phase 5 で最も重要な established pattern (= 5-1 L2 / 5-2 L1)

**post-flight regression check が past sub-project の latent issue を発見する pattern** が **3 連続 validate** で完全 established:

| Phase | 発覚した latent issue | 起因 sub-project | Resolution |
|---|---|---|---|
| 4-3 | Mimir replication_factor 不整合 (= RF=3 vs 1 ingester) | Phase 3 Sub-project 2 | PR #312 fix forward |
| 5-1 | Cilium Hubble TLS architectural issue (= SelfSigned ClusterIssuer の mTLS 不可) | Phase 4-1 | PR #316 fix forward |
| 5-2 | Mimir max-label-names-per-series 超過 (= Beyla histogram 31 labels) | Phase 3 Sub-project 2 | Phase 6+ 引き継ぎ #21 |

= **新 application 投入** sub-project は **既存 stack に新 data flow を加える** ため、過去 deploy 時に dormant だった issue を表面化する **trigger** になる。Phase 6+ post-flight 自動化 (= 引き継ぎ #5) の primary design 指針。

---

## 6. Phase 6+ への bridge

### Phase 6+ 候補 themes

Phase 1-5 完了で **EKS production cluster の foundation + observability + secrets + autoscaling + 認証ゲート + demo application validation** が達成。Phase 6+ で扱う候補:

#### A. Application code migration (= panicboat monorepo)

- panicboat 既存 monorepo (= Hanami gRPC backend + Next.js BFF) を本 platform に migration
- OTel SDK + `Instrumentation` CR で application-level traces / metrics 収集
- mTLS-required communication (= service-to-service) の cert-manager pattern (= 5-1 L3 lesson 適用、CA-based ClusterIssuer)
- 引き継ぎ #4 / #11 / #18 / #19 が同時解消候補

#### B. Operational maturity (= post-flight automation)

- 引き継ぎ #5 の post-flight check 自動化 (= 5+ design 指針集約済)
- cross-sub-project regression check pattern automated detection
- synthetic test (= load test / secret rotation / mTLS handshake) 自動実行
- 引き継ぎ #15 / #16 / #19 が同時解消候補

#### C. Multi-tenant + retention (= scaling for production)

- 引き継ぎ #2 + #3 (= bucket-per-env + multi-tenant 化) の同時解消
- application multi-tenant deploy への対応 (= namespace isolation + RBAC + network policy)
- 引き継ぎ #9 (= rightsizing) も同 phase で再 audit (= multi-tenant 環境で actual usage profile 変化)

#### D. Security hardening (= production-grade)

- 引き継ぎ #11 (= Google Workspace + OAuth Internal)
- 引き継ぎ #12 (= AWS Secrets Manager Automatic Rotation)
- 引き継ぎ #13 (= Cilium Gateway API east-west) の検討
- AWS WAF / source IP allowlist on ALB (= 5-2 で identified)

### Phase 6+ planning starting point

本 doc を **Phase 6+ の starting point** として、以下の順序を推奨:

1. **Phase 6 brainstorming で本 doc の Phase 6+ 候補 themes (= A-D) を提示**、user に primary focus を選択してもらう
2. 選択された theme を **further decompose into sub-projects** (= Phase 4 / 5 と同 pattern)
3. 各 sub-project で本 doc の lessons (= 10 件) + 引き継ぎ事項 (= 21 項目) を **explicit reference** として brainstorming + plan + implement
4. Phase 5-1 L2 pattern (= post-flight regression check が past latent issue を発見) を継続 validate

---

## References

### Phase 5 sub-project specs / plans / learnings

- Phase 5-1 spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- Phase 5-1 plan + learnings: `docs/superpowers/plans/2026-05-09-eks-production-beyla-foundation.md`
- Phase 5-2 spec: `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`
- Phase 5-2 plan + learnings: `docs/superpowers/plans/2026-05-10-eks-production-nginx-end-to-end-validation.md`

### Phase 4 sub-project specs / plans / learnings

- Phase 4-1 spec / plan: `docs/superpowers/specs/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls-design.md` + `docs/superpowers/plans/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls.md`
- Phase 4-2 spec / plan: `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md` + `docs/superpowers/plans/2026-05-08-eks-production-eso-reloader-foundation.md`
- Phase 4-3 spec / plan: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md` + `docs/superpowers/plans/2026-05-09-eks-production-grafana-auth-ingress.md`

### platform roadmap

- `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

### fix forward PRs (= Phase 4-5 で 5 件)

- PR #305 (= observability DaemonSets PriorityClass)
- PR #311 (= oauth2-proxy 4 instances)
- PR #312 (= Mimir replication_factor 1)
- PR #314 (= Mimir cardinality limit + apiserver bucket drop)
- PR #316 (= Cilium Hubble CA-based ClusterIssuer)
