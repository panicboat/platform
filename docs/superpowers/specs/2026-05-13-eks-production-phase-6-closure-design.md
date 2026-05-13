# EKS Production: Phase 6 Closure (= Monorepo migration 完了 + Phase 7+ 引き継ぎ整理)

> **Phase**: roadmap Phase 6 (= Application migration) の **closure document**
>
> **Nature**: 集約 doc (= deploy 不要、 CI / cluster 影響なし)、 過去 sub-project specs / plans / implementations の summary + Phase 7+ planning の starting point
>
> **Goal**: Phase 6 (= 6-1 Foundation + 6-2 Application deploy + 6-3 End-to-end validation) の closing。 panicboat monorepo (= Hanami gRPC backend + Next.js BFF + reverse-proxy) の eks-production cluster への migration 完了、 Phase 5 で確立した 13 checklist の application 化、 Phase 1-6 で蓄積した 引き継ぎ事項 final list (= 24 件) を Phase 7+ に handoff、 Phase 6 で確立された patterns + lessons を集約。

---

## 1. Phase 6 overview

### Phase 6 goal

panicboat monorepo を eks-production cluster に migration、 Phase 5 で確立した demo nginx end-to-end validation pattern を **production-grade application で extend**。 develop env (= develop.panicboat.net) で 13 checklist application 化、 引き継ぎ事項 #25 / #28 / #32 / #34 解消 + 新規 F4 (= terragrunt module 設計修正) で develop env code quality 向上、 Phase 6 全体 closure 達成。

### Phase 6 sub-projects + status

| Sub-project | Scope | Status | PRs |
|---|---|---|---|
| **6-1 Foundation** | Cilium shared Gateway + Flux GitRepository monorepo + OTel Operator chart deploy + monorepo nginx 削除 | ✅ **完了** | #323 (= deploy)、 #324 / #325 / #327 (= fix forward)、 別途 learnings worktree |
| **6-2 Application deploy** | AWS RDS + 3 services deploy (= monolith + frontend + reverse-proxy) + OTel SDK L1+L2 + Flux Image Update Automation + ExternalSecret + Reloader + post-flight 6 連続 validate | ✅ **完了** | monorepo 側 application code PR + platform 側 terragrunt PR + fix forward chain (= #601 等) |
| **6-3 End-to-end validation** | application traffic + DNS / ACM (= develop.panicboat.net 公開) + 3-layer observability + Phase 5-2 13 checklist application 化 + Theme B monitoring stack hardening fix forward + 引き継ぎ #28 / #32 / #34 解消 + F4 terragrunt 設計修正 + post-flight 7 連続 validate | ✅ **完了** | platform #361 (= Theme B Pre PR)、 platform #367 (= nginx-sample 削除)、 monorepo #604 (= F1 + F2 revert + D2 + DNS)、 monorepo #606 (= monolith OTel env vars fix forward) |

### Phase 6-3 Theme B monitoring stack hardening (= 6-3 内で追加 fix forward)

6-3 brainstorming で application traffic 投入前提として **monitoring stack の reject 0 件状態確立** を Pre PR で fix forward。 全 fix が **アプリケーション無視 (= infrastructure 層) で完結**、 root cause + best practice 採用 (= 雑対応回避):

| 問題 | Root cause | Fix |
|---|---|---|
| Mimir `err-mimir-max-label-names-per-series` (= Beyla series 31 labels > limit 30) | Beyla `attributes.kubernetes.enable: true` で全 k8s_* decorator 出力 + ServiceMonitor scrape meta + exported_* 二重化 | Beyla `attributes.select.'*'.exclude` で不要 K8s decorator (= k8s_container_name / k8s_kind / k8s_owner_name / k8s_pod_start_time / k8s_pod_uid / k8s_replicaset_name) を drop、 forward-compatible 設計 |
| Mimir `err-mimir-label-invalid` (= OTel Collector self-metric の dotted label `server.address` 等) | OTel Collector v0.151.0 の Prometheus 3.0 scraper が dotted name (= UTF-8) を pass-through、 Mimir 2.x 互換 strict validator で reject | Prometheus `nameValidationScheme: Legacy` で入口 escape、 Mimir downstream の能力に uniform 整合 |
| Beyla traces 片肺 (= nginx のみ Tempo 到達、 monolith / frontend / reverse-proxy 0 traces) | Beyla 3.x の Ruby/gRPC 非対応 (= design limitation) + Beyla 設定不在、 旧 spec の "Beyla 復活 investigation" 概念が誤認 | `discovery.exclude_instrument: monolith` で monolith を Beyla 対象外 (= OTel SDK L1+L2 担当)、 discovery 3.x syntax migration (= `services` → `instrument`)、 frontend / reverse-proxy は application traffic 投入後 reactive validate |

**Result**: Mimir distributor reject 17 件 / 1min → **0 件** / 1min。

---

## 2. roadmap Phase 6 完了条件 application 化 達成 status

Phase 5 closure Section 2 と同 13 checklist を application stack (= monolith + frontend + reverse-proxy) で再 validate。 Phase 6-3 cluster validate (= 2026-05-13、 develop.panicboat.net 公開後):

| # | Checklist | 達成 sub-project | Status / Evidence |
|---|---|---|---|
| 1 | Pod 起動 + Cilium chaining mode IP | 6-2 / 6-3 | ✅ 全 Pods Running、 10.0.x.x IP 割当 |
| 2 | ClusterIP Service DNS resolution | 6-2 / 6-3 | ✅ `monolith.default.svc.cluster.local → 172.20.253.7` resolve OK |
| 3 | Ingress → NLB / ALB | 6-3 (= NLB internet-facing 経由) | ✅ NLB active + EXTERNAL-IP assign |
| 4 | external-dns → Route53 | 6-3 | ✅ record auto-create、 cloudflare で `54.95.222.148` resolve |
| 5 | ACM HTTPS | 6-3 | ✅ TLS 1.2、 cert `*.panicboat.net` SAN match `develop.panicboat.net` verify pass |
| 6 | HPA cpu 50% scale | (未 deploy) | ❌ **HPA application stack に未 deploy** (= 引き継ぎ #36) |
| 7 | KEDA ScaledObject Prometheus scale | (未 deploy) | ❌ **ScaledObject 未 deploy** (= 引き継ぎ #35) |
| 8 | Karpenter node 増加 | (mechanism 確認) | ✅ 既 deploy 済 mechanism、 Phase 5-2 で実証済 |
| 9 | Hubble L3/L4/L7 flow | 6-3 | ✅ Hubble flow visualize 機能、 frontend ↔ coredns / port 80 flow 観測 |
| 10 | Beyla traces → Tempo | 6-3 Theme B | ✅ frontend 9 / reverse-proxy 7 / nginx 10 traces 流入、 monolith は Beyla 対象外 (= design limitation、 OTel SDK L1+L2 担当) |
| 11 | Loki logs | 6-3 | ✅ monolith / frontend / reverse-proxy 全 stream、 `service_name` label 抽出済 |
| 12 | Mimir metrics + Grafana dashboard | 6-3 (= 3 service)、 monolith ⚠️ | ⚠️ frontend / reverse-proxy / nginx 流入 ✅、 monolith は env vars fix 済 (= PR #606)、 ただし actual traffic 流入経路要 (= 引き継ぎ #38) |
| 13 | ESO secret env 注入 | 6-2 | ✅ AWS Secrets Manager `panicboat/monolith/database` → ExternalSecret → K8s Secret → monolith env 注入 |
| 14 | Reloader rollout | 6-2 / 6-3 | ✅ annotation `reloader.stakater.com/auto: "true"` 確認、 secret rotation で auto-rollout 設計 |
| 15 | Grafana 認証ゲート | 4-3 既達成 | ✅ Phase 4-3 で oauth2-proxy + Google OAuth、 monitoring-uis ALB IngressGroup 経由 |

= **11/15 ✅、 1 ⚠️ (#12 monolith metric)、 3 ❌ (#6 HPA / #7 KEDA / 加えて 6-3 で発覚 latent #36-#39)** (= roadmap intent essentially 達成、 ただし application 化で新規 latent 4 件 検出)。

---

## 3. Phase 6 累計 runtime issues + fix forwards

### Sub-project 完了 timeline (= 6-1 / 6-2 / 6-3 PR list)

| Date | PR # | Repo | Title | Sub-project / Type |
|---|---|---|---|---|
| 2026-05-10 | #320 周辺 | platform | feat(eks): Phase 6-1 — monorepo migration foundation | 6-1 deploy |
| 2026-05-10 | #321-#322 周辺 | platform | docs(eks): Phase 6-1 — post-execution learnings | 6-1 learnings |
| 2026-05-10 | #323 | platform | feat(eks): Phase 6-1 — monorepo migration foundation | 6-1 deploy |
| 2026-05-10 | #324 | platform | feat(eks-{logs,metrics,traces}): add force_destroy to S3 buckets | 6-1 fix forward |
| 2026-05-11 | #325 | platform | refactor(ci): pass pr-number from caller to deploy reusables | 6-1 fix forward |
| 2026-05-11 | #327 | platform | fix(eks): disable OTel Operator metrics auth (= 6-1 fix forward) | 6-1 fix forward |
| 2026-05-11 | #344 | monorepo | fix: OTel Operator Instrumentation CR spec.ruby schema (= 6-2 fix forward) | 6-2 fix forward |
| 2026-05-11 | #601 | monorepo | fix(monolith): inject-ruby annotation 削除 + env vars hardcode (= 6-2 fix forward) | 6-2 fix forward |
| 2026-05-11 | #602 | monorepo | fix: ImagePolicy interval required | 6-2 fix forward |
| 2026-05-11 | #603 | monorepo | fix: ImageUpdateAutomation `.Updated` deprecation → `.Changed.Changes` | 6-2 fix forward |
| 2026-05-11 | #361 | platform | fix(eks/monitoring): Phase 6-3 Theme B monitoring stack hardening (= Pre PR) | 6-3 Theme B fix forward |
| 2026-05-12 | #367 | platform | feat(eks): Phase 6-3 application end-to-end validation companion (= nginx-sample 削除) | 6-3 platform deploy |
| 2026-05-12 | #604 | monorepo | feat: Phase 6-3 application end-to-end validation (= migration + DNS + terragrunt) | 6-3 monorepo deploy |
| 2026-05-13 | #606 | monorepo | fix(monolith): add OTel exporter / propagator env vars (= 6-3 fix forward) | 6-3 fix forward |

(= PR 番号は actual 値、 timeline 順)

### Phase 6 累計 runtime issue 数

| Sub-project | initial deploy | runtime fix | 計 |
|---|---|---|---|
| 6-1 Foundation | 0 (= deploy time issue なし) | 3 (= #324 S3 force_destroy、 #325 CI pr-number、 #327 OTel Operator metrics auth) | 3 |
| 6-2 Application deploy | 0 (= deploy time issue なし、 ただし fix forward chain) | 4 (= #344 Instrumentation CR、 #601 inject-ruby、 #602 ImagePolicy interval、 #603 ImageUpdateAutomation `.Updated` deprecation) | 4 |
| 6-3 End-to-end validation | 0 (= deploy time issue なし) | 2 (= #361 Theme B Pre PR、 #606 monolith OTel env vars) | 2 |
| **Phase 6 累計** | | | **9** |

### fix forward PR list

| PR # | Repo | Title | 解消 issue |
|---|---|---|---|
| #324 | platform | S3 buckets force_destroy | 6-1 latent: terragrunt destroy で bucket non-empty error |
| #325 | platform | CI pr-number from caller | 6-1 latent: deploy reusable workflow の context 不足 |
| #327 | platform | OTel Operator metrics auth disable | 6-1 latent: chart 0.112.1 の metrics auth が cilium-envoy webhook と conflict |
| #344 | monorepo | Instrumentation CR spec.ruby schema fix | 6-2 latent: chart 0.112.1 が spec.ruby schema 非対応 (= 引き継ぎ #25 origin) |
| #601 | monorepo | inject-ruby annotation 削除 + env vars hardcode | 6-2 latent: 同上 (= 引き継ぎ #25 / #38 origin) |
| #602 | monorepo | ImagePolicy interval required | 6-2 latent: Flux ImagePolicy CRD で interval が required field |
| #603 | monorepo | ImageUpdateAutomation `.Updated` deprecation → `.Changed.Changes` | 6-2 latent: Flux Image Update v1.1+ で template syntax 変更 |
| #361 | platform | Phase 6-3 Theme B monitoring stack hardening | 6-2 latent + 6-3 で発覚: Mimir reject 17 件 / min (= 引き継ぎ #21 解消 + 新規発見) |
| #606 | monorepo | monolith OTel exporter / propagator env vars | 6-3 latent: 6-2 env vars hardcode 不足 (= 2 個のみ、 必要 6 個) |

= **fix forward 9 件中 8 件が 当 sub-project の latent issue** (= deploy 時点で発覚せず、 post-flight / 続 sub-project で発覚)、 1 件 (= #324) は terragrunt destroy 時の発覚で別 axis。 panicboat の "post-flight 7 連続 validate" pattern (= 5-1 L2 / 5-2 L1 由来) が Phase 6 内で持続。

---

## 4. 引き継ぎ事項 update

### Phase 6 で解消 (= 13 件)

#### Phase 5 closure 由来解消 (= 7 件)

| # | 項目 | 解消 sub-project |
|---|---|---|
| #4 | OTel Operator deploy 検討 | 6-1 (= chart 0.112.1 deploy) + 6-2 (= L1 application SDK init + L2 Instrumentation CR)、 ただし Ruby auto-injection 非対応で #25 残存 |
| #6 | Beyla deploy + OTel Collector metrics pipeline | 5-1 で part 1 既解消、 6-3 Theme B で part 2 (= OTel Collector metrics pipeline 改善、 self-metric dotted label 解消) 完了 |
| #13 | Cilium Gateway API east-west 利用 | 6-1 (= shared Gateway deploy、 reverse-proxy HTTPRoute parentRef 接続)、 ただし north-south 統一は #39 で未完 |
| #17 | Loki OTLP label promotion 再 design | 6-3 Theme B で本 closure session で確認、 `service_name` label が monolith / frontend / reverse-proxy / nginx 全て promotion 済 |
| #18 | cert-manager SelfSigned ClusterIssuer use case 限定 docs 化 | 6-1 で memory file (= `mimir-mode-knowledge.md` 等の pattern) で代替 |
| #20 | Beyla discovery.services deprecation → discovery.instrument migration | 6-3 Theme B (= chart 1.16.7 で migration、 deprecation warning 消失) |
| #21 | Mimir max-label-names-per-series 30 → 35 拡大 | 6-3 Theme B で root cause fix (= Beyla `attributes.select.'*'.exclude` で label 数削減、 30 limit に対し margin 7 確保、 雑な 35 拡大回避) |

#### Phase 6 新規解消 (= 6 件)

| # | 項目 | 解消 sub-project |
|---|---|---|
| #22 | Makefile hydrate-component の kube-version 固定 | 6-2 で re-diagnosed root cause = subagent aqua-pinned helm 未利用、 subagent dispatch instruction で aqua install + aqua-pinned helm / helmfile / kustomize 利用 明示で解消、 Makefile 修正不要 |
| #23 | monorepo README documentation drift | 6-2 (= monorepo PR scope 内で更新) |
| #28 | monolith Hanami migration failure investigation | 6-3 F1 (= 24 migration の `Sequel.lit("uuidv7()")` / `Sequel.function(:uuidv7)` 削除、 17 repository + 13 seeds に `SecureRandom.uuid_v7` 明示) |
| #31 | Beyla 復活 investigation | 6-3 Theme B で 概念 update (= "Beyla 復活" は Phase 6-1 期の誤認、 Beyla 3.x の Ruby/gRPC 非対応の design limitation を明示認識、 `exclude_instrument: monolith` で対象外明示) |
| #32 | application identity domain | 6-3 DNS (= develop.panicboat.net 公開、 既 `*.panicboat.net` wildcard ACM cert + Route53 zone + ExternalDNS 統合)、 production 化時 dystopia.city への migration は #33 に persist |
| #34 | AWS Secrets Manager `panicboat/nginx/demo` 削除 | 6-3 closure phase で manual 実施 (= aws secretsmanager delete-secret --force-delete-without-recovery、 nginx-sample 削除に伴う AWS 側 cleanup) |

---

### Phase 7+ 残 (= 24 件、 体験 / architecture impact 中心、 self-contained context)

各項目は **Phase 7+ session で何も覚えていない前提**、 phase history は最小限。 各項目に: 現在の体験 / 問題点 / 改善後の体験 + architecture impact / Phase 7+ task / priority。

#### Category A: Storage / multi-tenant (= 3 件)

**#1 gp3 StorageClass の Layer 2 documented exception 化**

- 現在: panicboat の architecture は 2 layer 設計 (= "cluster bootstrap layer は Flux 外、 Day-1+ は Flux 管理")、 ただし `gp3` StorageClass は bootstrap layer の dependency (= Mimir / Loki / Tempo / Prometheus 等の StatefulSet PVC が gp3 を要求) で Flux 内 manifest として存在 = architectural exception
- 体験 / impact: doc clarity の問題のみ、 functional 影響なし。 reader が "なぜ gp3 が Flux 内なのか" を理解できず混乱
- **Repo**: platform (= docs / README / memory file)
- Phase 7+ task: README / memory file に architectural exception を明記
- priority: low

**#2 bucket-per-env への migration**

- 現在: S3 1 bucket で全 env の Mimir / Loki / Tempo data 統合保存 (= develop only 前提)
- 体験 / impact: staging / production 追加時、 同 bucket で env data 混在 → cost 分離 / IAM 分離 / blast radius 分離 不可。 migration 後は env 別 bucket で **multi-env operation 安全性 大幅向上** (= 例: develop bucket bug で production data 影響なし)
- **Repo**: platform (= `aws/eks-{logs,metrics,traces}/` terragrunt + `kubernetes/components/{mimir,loki,tempo}/` chart values)
- Phase 7+ task: staging / production active 化 (= #33) と並行で bucket-per-env migration
- priority: medium (= #33 blocking)

**#3 multi-tenant 化 + 詳細 retention rules**

- 現在: Mimir / Loki / Tempo は `anonymous` 1 tenant、 retention は chart default
- 体験 / impact: multi-application / production traffic で **tenant 分離が不在** → 1 application の noisy neighbor が全 tenant に影響、 retention default で long-term data の cost 線形増加。 改善後 tenant 別 quota / rate limit / retention で cost 制御 + isolation
- **Repo**: platform (= `kubernetes/components/{mimir,loki,tempo}/production/values.yaml.gotmpl`)
- Phase 7+ task: multi-application / production traffic 投入時に tenant 分離 + retention policy 詳細化
- priority: low (= 発生時 reactive)

#### Category B: Observability automation (= 2 件)

**#5 post-flight check 自動化**

- 現在: 各 sub-project deploy 後、 "deploy 内容 + 既存 component への regression + 過去 phase の latent issue" を **手動 で 30-60 分 kubectl + log inspection** で verify。 5+ design 指針が定型化 (= cross-sub-project regression / actual load test synthetic / secret rotation synthetic / mTLS chain verify / Mimir distributor reject rate monitoring)
- 体験 / impact: deploy 毎に human time + verify 抜け risk + alert 経路不在。 自動化後 → deploy → synthetic test framework auto-run → fail 時 自動 alert (= Slack / PagerDuty)。 architecture diagram 上 "deploy → wait & verify" loop が CI/CD pipeline に組み込まれ、 **production deploy 信頼度 + 手動工数削減**
- **Repo**: platform (= 新 `scripts/post-flight/` or `.github/workflows/` or 新 `kubernetes/components/post-flight-checker/` component)
- Phase 7+ task: framework 選定 (= Argo Workflows / Tekton 等) + 5+ design 指針を test codify + alert 経路設定
- priority: medium

**#10 OTel Collector exporter alias check 自動化**

- 現在: OTel Collector の exporter alias (= `otlp/loki` / `otlp_grpc/tempo` 等) を manual review、 typo / 不整合で trace 流入 fail の latent issue を deploy 後に発覚 pattern
- 体験 / impact: deploy で 発覚 → fix forward の手間。 自動化後 → CI で kustomize lint + exporter alias 整合性 check → PR 段階で fail、 **deploy 前に防止**
- **Repo**: platform (= `.github/workflows/` + `kubernetes/components/opentelemetry-collector/`)
- Phase 7+ task: kustomize-aware lint / CI check
- priority: low (= 既 systematic step で防げる)

#### Category C: Logs + Hubble (= 2 件)

**#7 Hubble flow logs → Loki path**

- 現在: Hubble は flow event を memory ring buffer のみで保持、 永続化なし、 `hubble observe` で realtime 観測のみ
- 体験 / impact: 過去 flow の forensic investigation 不可 (= incident 後の "何分前 から どの pod 通信していたか" の 遡及 不可)。 改善後 Loki に persisted → Grafana で 日時 range で flow query、 **incident response 能力 大幅向上**、 ただし volume が膨大で cost / storage 影響評価必要
- **Repo**: platform (= `kubernetes/components/cilium/` + `kubernetes/components/loki/`)
- Phase 7+ task: flow logs を Loki export、 cost / storage 影響評価
- priority: low (= 現要件で十分、 forensic investigation 必要時)

**#8 local Fluent Bit OTLP gRPC 統一**

- 現在: local k3d / kind の Fluent Bit は OTLP HTTP、 production は OTLP gRPC (= protocol drift)
- 体験 / impact: local で動作するが production で fail のような protocol-level edge case を local で repro 不可。 改善後 local も gRPC 統一で **production parity**、 local 動作確認の信頼度 向上
- **Repo**: platform (= `kubernetes/components/fluent-bit/local/` or 既 PR #369 等で local 環境削除で自動解消)
- Phase 7+ task: local も OTLP gRPC 統一、 もしくは local 環境自体削除
- priority: low (= local 環境 deprecation で自動解消)

#### Category D: cost + rightsizing (= 1 件)

**#9 Pod CPU requests audit + rightsizing**

- 現在: 全 Pod が cpu requests を大幅に下回る usage (= 例: Loki 500m requests vs 6.7m actual = 1.3% utilization)。 Karpenter consolidation が追随済 のため cluster size 影響なし
- 体験 / impact: 現状 cost 影響軽微 (= panicboat 個人運用 cluster)。 production traffic 投入 / application multi-tenant 化時、 requests の過剰 設定で scheduler が node を不必要 拡張 → cost 線形増加。 改善後 actual usage 基準の requests で **cluster size 最適 + cost 削減**
- **Repo**: platform (= `kubernetes/components/*/production/values.yaml.gotmpl`) + monorepo (= `services/*/kubernetes/base/deployment.yaml`)
- Phase 7+ task: production traffic 投入 / application multi-tenant 化時に再 audit
- priority: low (= 現 cluster size で benefit 小)

#### Category E: Authentication + secrets (= 3 件)

**#11 Google Workspace 契約後の OAuth Internal 化**

- 現在: monitoring UIs の oauth2-proxy は Google personal account (= External) + email_domain allowlist で string match
- 体験 / impact: 任意の Google account holder が email_domain match すれば access 可、 attacker が 同 domain account 作成で侵入 risk。 改善後 Workspace Internal mode で **panicboat Workspace 所属 user のみ access**、 IdP-driven access control で security 向上
- **Repo**: platform (= `kubernetes/components/oauth2-proxy/production/values.yaml.gotmpl`)
- Phase 7+ task: panicboat の Workspace 契約後に values 数行差分で切替
- priority: low (= contract dependent)

**#12 AWS Secrets Manager Automatic Rotation**

- 現在: secrets (= grafana admin / monolith database / 等) は manual rotation 想定
- 体験 / impact: rotation 頻度低 (= 個人運用) で functional、 ただし secret 漏洩時の対応が manual → rotation 工数。 改善後 Lambda + Secrets Manager Automatic Rotation で **自動 rotation cycle + 漏洩時の MTTR 短縮**、 compliance 要件 (= SOC2 等) にも対応
- **Repo**: platform (= 新 `aws/secrets-rotation/modules/` terragrunt + Lambda function code) + monorepo (= `services/monolith/terragrunt/` で rotation Lambda 参照)
- Phase 7+ task: Lambda + Secrets Manager Automatic Rotation 統合 (= production traffic 投入 / compliance 要件発生時)
- priority: low (= 発生時 reactive)

**#14 monitoring UIs 公開範囲拡張**

- 現在: oauth2-proxy 経由公開は grafana / hubble / alertmanager / prometheus の 4 UIs、 Tempo / Mimir / Loki UIs は port-forward
- 体験 / impact: dev 用 UI (= Tempo direct UI 等) に port-forward 必須 → 手間。 改善後 IngressGroup `monitoring-uis` に Ingress 追加で 同 oauth2-proxy 経由 access、 **port-forward 工数削減 + dev 体験向上**
- **Repo**: platform (= `kubernetes/components/oauth2-proxy/production/kustomization/ingress-monitoring-uis.yaml` に Ingress 追加)
- Phase 7+ task: 追加要件発生時に IngressGroup に Ingress 追加で incremental 対応
- priority: low (= on-demand)

#### Category F: Pod Identity + cert-manager + Mimir (= 3 件)

**#15 Pod Identity webhook timing-sensitive injection の自動 detection**

- 現在: Pod Identity webhook が ESO Pod 等に `AWS_CONTAINER_CREDENTIALS_FULL_URI` env を inject、 ただし timing race で injection fail する case あり (= manual verify で env 存在 確認)
- 体験 / impact: rotation / pod recreate 時に env injection fail なら ESO が AWS access 不可 → secret sync 停止 → application Pod が secret 取得できず crash。 改善後 automated check で **injection fail 即時検出 + 自動 retry / alert**
- **Repo**: platform (= post-flight framework の一部、 #5 と統合)
- Phase 7+ task: automated check (= Pod env で `AWS_CONTAINER_CREDENTIALS_FULL_URI` 存在 probe)
- priority: medium (= rotation / pod recreate 時に repro 可能性)

**#16 distributed system chart の replica + replication_factor 整合 audit**

- 現在: Mimir / Loki / Tempo で audit 済 (= Phase 4-3 で Mimir `replication_factor: 3` vs ingester `replicas: 1` の論理破綻 fix forward)、 ただし new chart 追加時に repro 可能性
- 体験 / impact: 新 distributed system chart 追加で chart default の replicas vs RF 不整合 → deploy 後 silent fail (= 1 replica で RF=3 必要 → quorum 不成立 → write fail)。 改善後 CI lint で deploy 前 防止
- **Repo**: platform (= `.github/workflows/` + `scripts/chart-audit/`)
- Phase 7+ task: deploy 前 chart values audit pattern を CI lint 化
- priority: low (= 新 chart 追加頻度低)

**#19 mTLS chain verify default 化**

- 現在: cert-manager + Cilium TLS で mTLS using chart (= 例: Hubble Relay) の server cert + client cert の CA chain 一致を manual verify、 mismatch で mTLS fail (= 過去発覚 + fix forward 実績あり)
- 体験 / impact: 新 mTLS chart deploy で CA chain mismatch なら mTLS handshake fail → traffic 通らず silent fail。 改善後 post-flight check に "両 cert CA chain sha256 一致 verify" step が default → deploy 後即検出
- **Repo**: platform (= post-flight framework の一部、 #5 と統合)
- Phase 7+ task: post-flight check に CA chain verify step 追加 (= #5 と統合)
- priority: medium

#### Category G: Platform tool / docs cleanup (= 3 件)

**#24 Platform tool version 統一 (= mise / aqua 統一)**

- 現在: panicboat monorepo は **mise**、 platform は **aqua** で tool version 管理、 同 helm / kustomize / helmfile を別 manager で版管理
- 体験 / impact: repo 切替時に tool version 差分発生 → "monorepo では成功するが platform では fail" の type の race。 改善後 single source of truth で **repo 切替の認知負荷削減 + version drift 防止**
- **Repo**: 両方 (= platform `.aqua/aqua.yaml` + monorepo `mise.toml` / `.tool-versions`、 どちらかに統一)
- Phase 7+ task: monorepo / platform 双方を aqua / mise どちらかに統一
- priority: medium

**#26 commit comments / docs の "when" / "future" 記述 systematic cleanup**

- 現在: 既 commit comments / docs に "Phase N で導入" / "PR #N で撤去予定" 等の historical noise 累積、 CLAUDE.md Documentation rule (= "when" / "future" 禁止) と矛盾。 partial cleanup 実施済も monorepo / 古い platform code に残存
- 体験 / impact: reader が doc を読むたびに過去 / 未来 phase reference を理解する必要 → 認知負荷 + doc が時間軸で stale 化。 改善後 "現在の状態" のみ docs → reader が **時間軸 context なしで読める**、 maintenance cost ↓
- **Repo**: 両方 (= 全 codebase の comments / docs)
- Phase 7+ task: 全 codebase で "when" / "future" comments cleanup
- priority: low (= 累積 maintenance cost)

**#29 base / overlays 設計再評価**

- 現在: monorepo の K8s manifest は base / overlays/develop pattern、 ただし env-specific 値 (= 例: monolith deployment.yaml の OTel env vars hardcode) を base に混入、 overlays に移譲すべき内容が base に
- 体験 / impact: multi-env 化時、 base が env-agnostic でないため staging / production overlay で base 値を打ち消す patch が大量発生 → maintenance hell。 改善後 base = env-agnostic / overlays = env-specific の正規 pattern で **multi-env 追加が overlay 1 dir 作成のみ**、 base 触らず
- **Repo**: monorepo (= `services/*/kubernetes/base/` + `services/*/kubernetes/overlays/{develop,staging,production}/`)
- Phase 7+ task: base / overlays re-org (= Theme A multi-env と並行)
- priority: high (= Theme A blocking)

#### Category H: Application + production grade (= 5 件)

**#25 OTel Operator chart upgrade (= Ruby auto-injection native support)**

- 現在: OTel Operator chart 0.112.1 は `spec.ruby` schema 非対応、 workaround として monolith Pod に env vars 6 個 hardcode (= ENDPOINT / RESOURCE_ATTRIBUTES / TRACES_EXPORTER / METRICS_EXPORTER / LOGS_EXPORTER / PROPAGATORS)
- 体験 / impact: 新 Ruby service 追加で 同じ env vars hardcode 6 個を deployment.yaml に手動 copy 必要 → toil。 改善後 chart 0.155+ upgrade で `inject-ruby: "true"` annotation 1 行に置換 → **新 Ruby service 追加コスト 大幅削減**、 architecture 整合 (= "OTel Operator が auto-inject" 設計に復帰)
- **Repo**: platform (= `kubernetes/components/otel-operator/production/` chart version upgrade) + monorepo (= `services/monolith/kubernetes/base/deployment.yaml` の env vars hardcode 撤去 + annotation 復活)
- Phase 7+ task: OTel Operator chart 0.155+ upgrade、 env vars hardcode 撤去 + annotation 復活
- priority: medium (= #38 と関連)

**#33 panicboat staging / production env active 化 + release-please + dystopia.city** (= Phase 7 Theme A primary focus)

- 現在: develop active のみ、 staging / production overlays 不在 or dormant、 release-please 未統合、 dystopia.city Route53 zone 不在 (= develop.panicboat.net で internet 公開)
- 体験 / impact:
  - dev が develop で work → そのまま production に reflect、 staging で **release 候補の事前検証** 不可
  - release が manual (= image tag 手 bump)、 release notes も manual → traceability 弱
  - production 用 domain (= dystopia.city) が internet 不在 → user facing public service として立ち上がっていない
  - 改善後: **3 env で release pipeline 確立** (= develop `latest` / staging `release-pr-*` / production semver tag)、 release-please で auto release PR + change log、 dystopia.city public 公開 で **panicboat が production grade SaaS として user 受け入れ準備完了**
- **Repo**: 両方
  - platform (= `kubernetes/clusters/` で multi-env Flux 設定 + `aws/route53/` で dystopia.city zone + `aws/acm/` 等)
  - monorepo (= `services/*/kubernetes/overlays/{develop,staging,production}/` + `services/*/terragrunt/envs/{develop,staging,production}/` + `.github/workflows/` で release-please + container-builder semver tag + ImagePolicy multi-env pattern)
- Phase 7+ task: overlays / terragrunt envs 整備 + release-please integration + container-builder semver tag + ImagePolicy multi-env pattern + dystopia.city Route53 / ACM / ExternalDNS + K8s namespace 分離 + 3 RDS instance
- priority: **high (= Phase 7 primary focus 推奨)**

**#35 KEDA ScaledObject for application**

- 現在: application stack (= monolith / frontend / reverse-proxy) に KEDA ScaledObject 未設定 (= Prometheus query 駆動 auto-scale 不可)
- 体験 / impact: traffic 急増時 manual replica 増加が必要 → response time 劣化。 改善後 Prometheus metric 駆動で **request rate / latency 自動 scale-up**、 traffic spike 対応 + cost 効率 (= idle 時 scale-down)
- **Repo**: monorepo (= `services/*/kubernetes/base/scaled-object.yaml` 新規 or `overlays/develop/`)
- Phase 7+ task: application 3 services に ScaledObject、 traffic profile 確定後に threshold tune
- priority: medium (= production traffic 投入時必須)

**#36 HPA application 化**

- 現在: application stack に HPA 未 deploy (= cpu 50% trigger 不在)
- 体験 / impact: KEDA (= #35) と並行する **基礎 auto-scale 機構が不在**。 KEDA は Prometheus 駆動、 HPA は cpu / memory 駆動、 両者で異なる scale trigger を cover。 改善後 cpu spike (= sudden load) に HPA で即対応、 sustained load に KEDA で計画的 scale
- **Repo**: monorepo (= `services/*/kubernetes/base/hpa.yaml` 新規 or `overlays/develop/`)
- Phase 7+ task: HPA (= cpu 50% trigger) 設定、 KEDA と統合
- priority: medium (= #35 と統合)

**#38 monolith trace / metric actual emit verify**

- 現在: monolith OTel SDK + env vars 設定済 ✓、 ただし frontend SSR cache HIT で monolith に actual traffic 来ない → Tempo / Mimir に span / metric 0 件流入、 actual emit verify 未達
- 体験 / impact: production traffic 投入時に monolith が actually OTel data 出すか **未検証**、 deploy 後 silent fail risk。 改善後 traffic 投入経路設立 → Tempo で `service.name=monolith` trace 流入確認 + Mimir で `rpc_server_*` / `db_client_*` metrics 流入確認 → **monolith observability の baseline 確立**、 incident response 時に actually trace で見える
- **Repo**: monorepo (= `services/monolith/` の test runner / `proto/` 経由 grpcurl 等) + post-deployment observation
- Phase 7+ task: traffic 投入経路設立 (= grpcurl + proto file / SSR cache miss / 実 user traffic 等) + emit verify
- priority: medium (= production 化前に必須)

#### Category I: Infrastructure + gateway (= 3 件)

**#37 AWS LB Controller SG 重複 reconcile error**

- 現在: cluster の AWS LB Controller log が panic loop (= "expected exactly one securityGroup tagged with kubernetes.io/cluster/X, got: [sg-A, sg-B]")、 直近 eks/modules + aws provider update で node SG にも `kubernetes.io/cluster/X: owned` tag 追加され EKS cluster SG と重複
- 体験 / impact: 既 register 済 LB target は healthy 維持、 ただし **新規 LoadBalancer Service / Ingress 作成で panic loop により LB provision fail**。 panicboat の next deploy (= 例 staging / production 追加、 #33) で新 ALB / NLB が必要、 そこで blocking。 改善後 SG 重複解消で **新規 LB provision 復活**
- **Repo**: platform (= `aws/eks/modules/` terragrunt で node SG tag 除去 もしくは `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` で controller args 調整)
- Phase 7+ task: terragrunt eks module で node SG の `kubernetes.io/cluster/X` tag 除去 (= node identification は別 tag 代替) もしくは Service annotation で SG specify
- priority: high (= #33 multi-env active 化と blocking)

**#39 Cilium Gateway hostNetwork mode + ALB IngressGroup migration**

- 現在: panicboat の internet 公開は **reverse-proxy nginx → NLB** 経路 (= 6-3 で deploy)、 加えて cilium-gateway 自身も NLB を持つ (= cluster-internal east-west routing 用)。 計 NLB 2 個 (= ~$48 + ~$31 = monthly ~$79)
- 体験 / impact:
  - **architecture 不一致**: panicboat の設計は "north-south は ALB Controller、 east-west は cilium-gateway"、 ただし reverse-proxy が独自 NLB + cilium-gateway が独自 NLB (= over-spec)
  - **Gateway 層 JWT 検証 採用予定** (= user の auth strategy)、 ただし current architecture で Cilium Gateway が internet 経路にない → JWT 検証経路の前提 不在
  - 改善後: Cilium Gateway hostNetwork mode で LoadBalancer Service auto-create disable + ALB IngressGroup で internet 公開 → reverse-proxy 廃止 + cilium-gateway NLB 削除 = **monthly ~$79 cost 削減 + Cilium Gateway 単一 entry で JWT validation 設定可能 + reverse-proxy nginx config maintenance 不要**
  - 6-3 で試行 → Cilium 1.18.6 の internal logic で listener port migration 不完全 → revert
- **Repo**: 両方
  - platform (= `kubernetes/components/cilium/production/values.yaml.gotmpl` で hostNetwork.enabled + `kustomization/cilium-gateway.yaml` で listener port + 新 ALB Ingress component)
  - monorepo (= `services/reverse-proxy/` 全削除 + `services/frontend/kubernetes/base/httproute.yaml` 新規追加)
- Phase 7+ task:
  - Cilium 1.19+ upgrade で hostNetwork mode 改善 verify、 もしくは
  - 別 approach (= CiliumEnvoyConfig CR の listener port を 手動 update mechanism、 Cilium support 経由)、 もしくは
  - panicboat の auth strategy 再評価 (= Gateway 層 JWT 採用 → app-level JWT に persist で current architecture 維持)
- priority: medium (= cost 削減 + auth strategy enablement)

**#40 panicboat AWS LB Controller helm values で `loadBalancerClass: service.k8s.aws/nlb` default 設定**

- 現在: cilium-gateway Service が `type=LoadBalancer` で **loadBalancerClass annotation 不在** (= Cilium operator auto-create) → in-tree Cloud Provider が pick up + classic ELB recreate cycle、 architecture 完全 drift (= panicboat は AWS LB Controller 設計、 classic ELB は どの category にも該当しない)。 cost ~$10-20/month の dead weight LB
- 体験 / impact: orphan classic ELB が cost 発生中、 dev が AWS Console で確認時に "なぜこの LB が存在するか" 不明 → 認知負荷。 改善後 AWS LB Controller の `--default-load-balancer-class` flag で **loadBalancerClass 不在 Service も AWS LB Controller 経由化** → Cloud Provider skip → classic ELB recreate 防止
- **Repo**: platform (= `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl`)
- Phase 7+ task:
  - panicboat `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` に `loadBalancerClass: service.k8s.aws/nlb` 追加
  - 既 orphan classic ELB delete
  - **complete fix**: #39 hostNetwork mode 採用で LoadBalancer Service 自体 disable → classic ELB / NLB 両方の drift 完全解消
- priority: medium (= cost small だが恒久 leak、 #39 と並行 systematic 解消が筋)

---

## 5. Phase 6 lessons aggregated

### 6-1 Foundation lessons

- **Cilium shared Gateway pattern**: YAGNI で per-service Gateway を避け、 1 shared Gateway (= `default/cilium-gateway`) で全 service の east-west L7 routing 統一。 将来 multi-application で per-service Gateway 必要なら再評価。
- **OTel Operator chart 0.112.1 の Ruby auto-injection 非対応** (= `spec.ruby` schema unsupported) を 6-1 deploy 時に発覚、 6-2 で workaround として env vars hardcode に切替。 chart upgrade (= 引き継ぎ #25) で systematic 解決予定。
- **S3 buckets force_destroy** (= PR #324) は terragrunt destroy 時 bucket non-empty error 回避、 develop env 前提の設定。 production env では `force_destroy: false` に切替必要。
- **CI reusable workflow の context 不足** (= PR #325) で pr-number が caller から渡されない、 deploy reusable に明示 input 追加。

### 6-2 Application deploy lessons

- **OTel Operator chart 0.112.1 + Ruby workaround pattern**: `inject-ruby: "true"` annotation 削除 + Pod env vars hardcode (= PR #601)、 ただし当初 hardcode が 2 個のみで不足、 6-3 で 4 個追加 (= PR #606)。 hardcode は全 env vars (= ENDPOINT / RESOURCE_ATTRIBUTES / TRACES_EXPORTER / METRICS_EXPORTER / LOGS_EXPORTER / PROPAGATORS) を網羅必要、 chart upgrade で auto-injection 復活が systematic 解。
- **Flux Image Update Automation の CRD updates**:
  - `ImagePolicy.interval` が required (= PR #602)、 chart default 設定で省略すると reconcile fail
  - `ImageUpdateAutomation` の template syntax で `.Updated` deprecation → `.Changed.Changes` + `.NewValue` (= PR #603、 Flux v1.1+)
- **terragrunt secret_version の AccessDenied issue** (= 6-2 で `secretsmanager:GetSecretValue` 権限不足で plan fail)、 `lifecycle.ignore_changes` ineffective (= state refresh が skip されない) のため secret_version resource 全削除 + manual put-secret-value で対応 (= "secret value IaC 外で manage" pattern)。
- **PR #336 KUBE_VERSION mismatch** で merge close、 root cause = subagent が aqua-pinned helm を使わず host helm を利用 (= 引き継ぎ #22 re-diagnose)、 6-2 plan の Task 0 で subagent dispatch instruction に aqua install + aqua-pinned tool 利用 明示で解消。
- **subagent dispatch instruction の制度化**: 各 task で aqua install (= `aqua install`) + aqua-pinned `helm` / `helmfile` / `kustomize` 利用を明示、 host tool の偶発利用を防ぐ。

### 6-3 End-to-end validation + Theme B monitoring hardening lessons

- **Theme B monitoring stack hardening fix forward pattern**:
  - 3 problem (= Mimir max-label / dotted label / Beyla 片肺) を root cause 解析 + best practice 採用で systematic 解決、 雑対応 (= limit 引き上げ / metric_relabel drop) 回避
  - Beyla `attributes.select` で **`include` 方式 → `exclude` 方式** に切替 (= service 拡張に platform 変更不要の forward-compatible 構成、 anti-pattern 回避)
  - Prometheus `nameValidationScheme: Legacy` で入口 escape、 OTel Collector v0.120.0+ の dotted name 仕様変更に対応
  - Beyla 3.x の Ruby/gRPC 非対応を design limitation として明示認識、 `exclude_instrument: monolith` で対象外、 OTel SDK L1+L2 に persist
- **Flux suspend + ローカル apply + 試行錯誤 pattern**:
  - PR 手戻りを避けるため、 cluster で先に動作確認してから PR 化
  - 7 step flow: (1) flux suspend → (2) values 編集 + hydrate → (3) kubectl apply -k → (4) 観測 → (5) fix loop → (6) commit + PR → (7) merge 後 flux resume + reconcile
  - 適用 unit は HelmRelease 単位ではなく Kustomization 単位 (= panicboat の "kustomize+helmfile で hydrate → plain manifest commit → Flux Kustomization apply" architecture 起因)
- **Cilium 1.18.6 hostNetwork mode の migration logic 不完全** (= (γ-a) 試行失敗の lesson):
  - LoadBalancer Service と hostNetwork mode は mutual exclusive、 ただし切替時に CiliumEnvoyConfig CR の listener port が Gateway CR の port update を反映しない (= cilium operator の migration logic 未対応)
  - Service finalizer (= `service.k8s.aws/resources`) が AWS LB Controller panic で stuck、 force cleanup で 解消可、 ただし cilium operator が Service auto-recreate
  - revert path: values 切戻し + ConfigMap force apply + cilium DaemonSet 再起動 で 元 LoadBalancer mode 復活、 clean revert pattern 確立
  - 教訓: cilium internal の挙動 deep dive で時間消費過大時、 revert + 引き継ぎ事項化 が pragmatic (= #39)
- **AWS LB Controller の SG 重複 reconcile error**:
  - eks/modules v21.20.0 + aws v6.44.0 update で node SG に `kubernetes.io/cluster/X: owned` tag 追加、 EKS cluster SG と 2 つに同 tag → "1 SG expectation" panic loop
  - 既 register 済 target は healthy 維持、 新規 deploy 影響あるが current functional
- **AWS credentials role differentiation**:
  - eks-admin-production role は EKS cluster access のみ (= kubectl OK、 EC2 / Route53 / ELB describe 不可)
  - IAM user `panicboat` (= local default profile) は full admin (= AWS resource describe 可)
  - debug 時に role 切替 (= `unset AWS_*; aws/CLI default profile`) 活用、 ただし通常運用は assumed role 経由
- **monolith に traffic を投入する method の制約**:
  - frontend SSR は Next.js cache HIT で monolith call をスキップ、 monolith に actual traffic 来ない
  - gRPC reflection API は monolith で disable、 grpcurl で reflection list 不可
  - proto file 必要、 monorepo 内 `./proto/` に存在、 debug pod に mount or copy 必要
  - 引き継ぎ #38 で post-deployment observation として persist
- **panicboat の develop active 方針**:
  - 6-3 brainstorming で当初 "production 環境なので overlays/production が正そう" → 後 "develop active 維持" で確定
  - staging / production active 化は Phase 7 Theme A primary focus
  - "develop = `latest` tag auto deploy、 staging = release-please branch、 production = semver tag" の 3 env active pattern

---

## 6. Phase 7+ への bridge

### Phase 7 primary focus 推奨

**Theme A. Multi-environment + release process** (= 引き継ぎ #29 + #33 統合)

panicboat application が **user-facing になる重要 phase**、 production grade release process 確立。 staging / production active 化 + release-please integration + dystopia.city public 公開 + ImagePolicy multi-env pattern を 1 theme で systematic 対応。

scope:
- monorepo `services/*/kubernetes/overlays/{develop,staging,production}/` 整備 (= 引き継ぎ #29 base / overlays 設計再評価 を 統合)
- monorepo `services/*/terragrunt/envs/{develop,staging,production}/` 整備
- googleapis/release-please-action 統合 (= conventional commits + auto version bump + release PR)
- container-builder workflow に semver tag push 設定追加 (= `type=semver,pattern={{version}}`)
- service 単位 ImagePolicy multi-env pattern (= develop `^latest$` / staging `^release-pr-` / production `^v\d+\.\d+\.\d+$`)
- dystopia.city public 公開 (= Route53 zone + ACM cert + ExternalDNS config + reverse-proxy host header)
- K8s namespace 分離 (= namespace `develop` / `staging` / `production`、 1 cluster で並立)
- 3 RDS instance (= monolith-{develop,staging,production}、 cost ~$45/month)

### Phase 7 secondary themes

- **Theme B. Monitoring stack hardening watch** (= 6-3 Theme B で主要 fix forward 解消、 Phase 7 では watch のみ):
  - Beyla 公式 Ruby gRPC support 動向 watch (= 対応されれば monolith の `exclude_instrument` 撤去 + Beyla 経由 distributed trace 取得可能)
  - Mimir UTF-8 label name 対応 watch (= 対応されれば Prometheus `nameValidationScheme` を UTF8 default に戻し native dotted attribute 直送可能)
- **Theme C. Platform tool version 統一 + cleanup** (= 引き継ぎ #24 + #26):
  - panicboat 全 repo (= monorepo + platform) で tool version manager 統一 (= mise / aqua いずれか single source of truth)
  - 既 commit comments / docs の "when" / "future" 記述 systematic cleanup
- **Theme D. OTel Operator chart upgrade** (= 引き継ぎ #25、 #38 と統合可能性):
  - chart 0.155.0+ (= Ruby auto-injection native support 想定 version) upgrade
  - monolith deployment.yaml の env vars hardcode 撤去 + `inject-ruby` annotation 復活
  - L2 ruby auto-injection native 利用
  - monolith actual trace / metric emit verify (= #38 を統合解決)
- **Theme E. Infrastructure + gateway hardening** (= 引き継ぎ #37 + #39 + #40):
  - AWS LB Controller SG 重複 reconcile error fix (= node SG tag 除去 もしくは Service annotation で SG specify)
  - Cilium Gateway hostNetwork mode + ALB IngressGroup migration 再試行 (= Cilium 1.19+ upgrade or CEC CR migration logic 改善)
  - AWS LB Controller default loadBalancerClass 設定 (= Cloud Provider 経由 classic ELB recreate 防止、 #39 と並行 systematic)
- **Theme F. Minor improvements** (= 残 Phase 5 closure 由来 + minor):
  - Storage / multi-tenant (= #1 / #2 / #3、 multi-env 化と並行)
  - Observability automation (= #5 / #10、 post-flight automation framework 化)
  - Logs + Hubble (= #7 / #8)
  - cost + rightsizing (= #9、 production traffic 投入後)
  - Authentication + secrets (= #11 / #12 / #14)
  - Pod Identity + cert-manager (= #15 / #16 / #19)
  - KEDA / HPA application 化 (= #35 / #36、 Theme A と並行)

### panicboat roadmap の dynamic 拡張 nature

panicboat の roadmap (= 2026-05-02 design doc) は Phase 1-5 のみ static defined、 **Phase 6 / 7 / 8+ は closure doc で動的拡張**。 Phase 7 が "最後" という定義はなく、 panicboat の想定 milestone は:

- **Phase 7 Theme A** で **panicboat application が user-facing になる、 production-grade release process 確立** (= 6-3 spec L41-49 で 言及)
- **Phase 8+** は production operation phases (= incident response / DR / cost optimization / security hardening) が implicit、 docs に明示なし、 panicboat application の actual production traffic 投入後に reactive で定義

### Phase 6 累計 statistics

- Phase 6 sub-projects: 3 (= 6-1 / 6-2 / 6-3) + 1 fix forward Pre PR (= 6-3 Theme B)
- Phase 6 PRs (= deploy + fix forward + closure): 14
- Phase 6 累計 runtime issue 数: 9 (= fix forward 9 件 で 解消)
- Phase 6 解消 引き継ぎ事項: 13 件 (= 7 件 Phase 5 closure 由来 + 6 件 Phase 6 新規)
- Phase 7+ 残 引き継ぎ事項: 24 件 (= 14 件 Phase 5 closure 由来 持ち越し + 10 件 Phase 6 新規)
- post-flight 連続 validate 達成: **7 連続** (= 4-3 / 5-1 / 5-2 / 6-1 / 6-2 / 6-2 fix forward chain / 6-3)
