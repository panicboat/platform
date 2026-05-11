# EKS Production Phase 6-3: Application End-to-end Validation (= F1 migration + F2 OTel + F4 terragrunt + DNS + nginx delete + 3-layer observability + 13 checklist application 化)

> **Phase**: roadmap Phase 6 (= application migration theme) の **第 3 sub-project (= End-to-end validation)**
>
> **Nature**: Phase 6-2 で deploy した application stack を actual production-grade で動作確認、 latent issue (= migration / OTel / DNS / terragrunt design) 解消、 Phase 5-2 で確立した 13 checklist を application 化、 5-1 L2 / 5-2 L1 pattern 7 連続 validate 達成
>
> **Goal**: Phase 6-2 で deploy 済 application (= monolith + frontend + reverse-proxy) を **production-grade end-to-end traffic** で動作確認、 develop env (= develop.panicboat.net 公開) で 13 checklist application 化、 引き継ぎ事項 #28 / #32 解消 + 新規 F4 (= terragrunt module 設計修正) で develop env code quality 向上、 Phase 6 全体 closure 達成。

---

## 1. Phase 6 overview + 6-3 position

### Phase 6 theme

panicboat monorepo (= Hanami gRPC backend + Next.js BFF + reverse-proxy) を eks-production cluster に migration、 Phase 5 で確立した demo nginx end-to-end validation pattern を **production-grade application で extend**。

### Phase 6 sub-projects + 6-3 position

| Sub-project | Scope | Status |
|---|---|---|
| 6-1 Foundation | Cilium 共有 Gateway + Flux GitRepository monorepo + OTel Operator + monorepo nginx 削除 | ✅ closure |
| 6-2 Application deploy | AWS RDS + 3 services deploy + OTel SDK L1+L2 + Flux Image Update Automation + ExternalSecret + Reloader + post-flight 6 連続 validate | ✅ closure |
| **6-3 End-to-end validation** | application traffic + DNS / ACM (= develop.panicboat.net) + 3-layer observability + Phase 5-2 13 checklist application 化 + 引き継ぎ事項解消 (#28, #32) + F4 terragrunt 設計修正 + post-flight 7 連続 validate | **本 spec の対象** |

### 6-2 closure 後の状態 + smoke test 知見

Phase 6-2 closure 後の post-flight smoke test (= Task 11 + 追加 smoke test) で latent issue 検出:

| Issue | 6-3 対処 |
|---|---|
| C1 monolith migration failure (= `uuidv7()` function 不在、 業務 table 0 個、 application 機能未動作) | F1 で対処 |
| H1 monolith OTel trace / metric 完全不在 (= gruf instrumentation 不在) | F2 で対処 |
| M1 NLB scheme = internal (= external access 不可) | DNS develop.panicboat.net 公開 + NLB internet-facing 化で対処 |
| M2 reverse-proxy port 8080 (= 慣例 80 と不整合) | D2 で対処 |
| (新) terragrunt module 設計 anti-pattern (= modules 内に env 文字列 hardcode) | F4 で対処 |
| (新) Phase 5-2 demo nginx (= nginx.panicboat.net) 残存、 application identity 確立で不要 | nginx delete で対処 |

引き継ぎ事項 #28 (= monolith Hanami migration failure)、 #32 (= application identity domain) を 6-3 で解消。

### 最終形 (= Phase 7+ への bridge)

panicboat monorepo の最終形:

- **develop** = `latest` tag auto deploy (= main merge → image push → auto reconcile) ※ **本 6-3 で active 維持**
- **production** = `googleapis/release-please-action` で service 単位 semver release (= 例 `monolith-v1.2.3` / `frontend-v0.5.1`)、 dystopia.city public 公開
- **staging** = release-please で生成された branch を deploy (= service 単位 pre-release validation)

6-3 では develop active 維持、 staging + production active 化 + release-please integration + dystopia.city public 公開は **Phase 7 で systematic 対応** (= 引き継ぎ #33)。

---

## 2. 6-3 scope (= 9 components)

### Component F1: monolith migration fix (= Ruby UUIDv7)

#### Goal

monolith Hanami の database migration failure (= `function uuidv7() does not exist`、 業務 table 0 個) を解消、 application 機能 unblock。 root cause: RDS PostgreSQL 17.4 で `uuidv7()` function 不在、 migration の `default :uuidv7` で fail。

#### Implementation

application code 側で UUIDv7 生成、 DB default 削除 (= panicboat の "secret value IaC 外で manage" pattern と整合的に、 ID 生成も application 側で manage)。

- `services/monolith/workspace/Gemfile`: `gem "uuid7"` (= Ruby UUIDv7 library) 追加
- `services/monolith/workspace/config/db/migrate/*.rb`: 既 migration file の `column :id, :uuid, default: Sequel.function(:uuidv7), primary_key: true` を `column :id, :uuid, primary_key: true` (= default 削除) に修正
- `services/monolith/workspace/lib/types.rb` or 適切な application code: Hanami entity / repository で id 生成時に `UUID7.generate` 呼出 (= 設計詳細は plan 段階で確定)

#### Validation

- post-merge で monolith Pod migration 成功確認 (= application log で `Sequel migrator: applied migration` 等)
- `kubectl exec monolith -- psql $DATABASE_URL -c "\dt"` で業務 table list 確認 (= 例 `identity.users` 等)
- application traffic (= ConnectRPC call) で id 生成 + DB query success

### Component F2: monolith OTel trace (= custom gruf interceptor)

#### Goal

monolith OTel trace / metric が Tempo / Prometheus に 0 件流入 (= 引き継ぎ #28 smoke test 知見) を解消。 root cause: `opentelemetry-instrumentation-all` gem に gruf (= gRPC server) instrumentation 不在。

#### Implementation

`Gruf::Interceptors::Base` subclass で custom OTel interceptor 実装、 既 `AccessLogInterceptor` と並列 registration。

- `services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb` 新規:
  - `OpenTelemetry.tracer_provider.tracer("gruf-server")` から tracer 取得
  - 各 incoming RPC で `tracer.in_span("gruf.{rpc method}", kind: :server) do |span| ... end` で span 生成
  - span attributes (= rpc.system="grpc", rpc.service, rpc.method, rpc.grpc.status_code) 付与
  - W3C tracecontext propagator で incoming gRPC metadata から trace context 抽出 + child span 生成
- `services/monolith/workspace/config/initializers/gruf.rb` (= or 既 gruf config 箇所): interceptor registration

#### Validation

- post-merge で monolith application が Tempo に span 流入 (= `service.name=monolith` で query 可能)
- monolith は Beyla 3.x の Ruby/gRPC 非対応により Beyla 経由観測対象外 (= Beyla discovery で `exclude_instrument` 済)、 OTel SDK L1+L2 が単独 trace 担当

### Component F4: terragrunt module 設計修正 (= 環境名 modules 除外)

#### Goal

`services/monolith/terragrunt/modules/main.tf` の anti-pattern (= module 内に `monolith-${var.environment}` 等 env 文字列 hardcode) を解消、 module の **environment 概念からの完全独立** を確立。 将来 staging / production env active 化時の reuse 性を担保。

#### Implementation

module は explicit resource name variables を受け取り、 envs/{env}/terragrunt.hcl で inputs として確定:

- `services/monolith/terragrunt/modules/variables.tf`: explicit resource name variables 追加
  - `db_identifier` (= 例 `monolith-develop`)
  - `db_subnet_group_name`
  - `security_group_name`
  - `secret_name`
- `services/monolith/terragrunt/modules/main.tf`: `monolith-${var.environment}` 等を `var.db_identifier` 等 variable 参照に置換
- `services/monolith/terragrunt/envs/develop/terragrunt.hcl`: inputs で resource name 確定 (= `db_identifier = "monolith-develop"` 等)

#### AWS resource 影響

既 develop env の RDS / Secrets Manager / Security Group / Subnet Group の **name 不変** (= terragrunt apply で diff 0)、 destroy + create 不要。

#### Validation

- `terragrunt plan` で diff 0 確認 (= module 内 string concatenation 削除 + variables.tf 追加 + terragrunt.hcl inputs 追加で resource name 同等)
- 既 develop env application 動作継続

### Component DNS: develop.panicboat.net 公開

#### Goal

reverse-proxy LoadBalancer Service を **internet-facing** で外部公開、 `develop.panicboat.net` で 13 checklist application 化を完全 cover。 既 panicboat.net wildcard ACM cert + Route53 zone を utilize、 ExternalDNS で record auto-create。

#### Implementation

- **NLB scheme = internet-facing**:
  - monorepo `services/reverse-proxy/kubernetes/base/service.yaml` に annotation 追加:
    - `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing`
    - `service.beta.kubernetes.io/aws-load-balancer-type: external`
    - `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip` (= 必要時)
- **DNS / ACM 公開**:
  - reverse-proxy Service annotation で `external-dns.alpha.kubernetes.io/hostname: develop.panicboat.net` (= ExternalDNS auto-create Route53 record)
  - ACM `*.panicboat.net` wildcard cert 既 Phase 4-3 で deploy 済、 ALB Ingress や NLB は ACM cert 紐付け mechanism 異なる:
    - Option (a): reverse-proxy Service annotation で ACM cert ARN 直接指定 (= `service.beta.kubernetes.io/aws-load-balancer-ssl-cert: <arn>`、 NLB TLS termination)
    - Option (b): cert-manager で develop.panicboat.net specific cert 取得 + nginx (= reverse-proxy Pod 内) で TLS termination
    - 採用: (a) NLB TLS termination (= simple、 既 ACM cert utilize、 Phase 4-3 で 4 monitoring UIs と同 pattern)
- **reverse-proxy nginx config**: `develop.panicboat.net` host header での routing (= 既 `frontend.local` 同 pattern で frontend backend に proxy)
- **HTTPRoute (= 既 reverse-proxy/kubernetes/base/httproute.yaml)**: hostnames 更新 (= `develop.panicboat.net` 追加)

#### Validation

- `dig develop.panicboat.net` で Route53 record 確認
- `curl -v https://develop.panicboat.net/` で HTTPS 200 + TLS verify success
- Phase 5-2 13 checklist application 化の各 item validation

### Component D2: reverse-proxy port 80 統一

#### Goal

reverse-proxy Service port = 8080 (= smoke test 知見) を 80 統一 (= 慣例整合、 DNS 公開時の standard port)。

#### Implementation

- monorepo `services/reverse-proxy/kubernetes/base/service.yaml`: Service `port: 8080 targetPort: 8080` → `port: 80 targetPort: 80`
- monorepo `services/reverse-proxy/kubernetes/base/config/conf.d/*.conf`: nginx `listen 8080` → `listen 80`
- monorepo `services/reverse-proxy/kubernetes/base/deployment.yaml`: containerPort `8080` → `80`
- monorepo `services/reverse-proxy/kubernetes/base/httproute.yaml`: parentRefs backendRefs port `8080` → `80`

#### Validation

- kustomize build で全 port 80 確認
- post-merge で reverse-proxy Pod listen 80 + Service port 80 + NLB target port 80 確認

### Component nginx delete: Phase 5-2 demo nginx 削除

#### Goal

Phase 5-2 で deploy 済 demo nginx (= `nginx.panicboat.net`) を削除、 panicboat.net identity の noise 除去、 application identity (= develop.panicboat.net) と分離。

#### Implementation

- **platform 側 削除**:
  - `kubernetes/components/nginx-sample/` directory 完全削除
  - `kubernetes/manifests/production/nginx-sample/` directory 完全削除 (= hydrate-index で auto-cleanup)
  - `kubernetes/manifests/production/kustomization.yaml` resources から `./nginx-sample` 削除 (= hydrate-index auto-cleanup)
- **AWS Secrets Manager 削除**:
  - `panicboat/nginx/demo` secret 削除 (= manual or platform terragrunt 修正、 ただし platform aws/eks-secrets/ は generic、 application secret は別 manage)
  - 引き継ぎ事項: AWS Secrets Manager の demo secret 削除 timing 確認、 manual operation 想定
- **ALB IngressGroup `monitoring-uis`**:
  - 既 nginx は ALB monitoring-uis IngressGroup join (= Phase 4-3 ALB shared)、 nginx 削除で IngressGroup から離脱、 ALB rule 自動削除 想定

#### Validation

- post-merge で `nginx.panicboat.net` HTTP 404 / no-resolve (= Route53 record 自動削除)
- nginx Pod 0 個 (= namespace default で nginx deployment 不存在)
- ALB rule 自動削除 (= IngressGroup 自動 reconcile)

### Component 3-layer observability validation

#### Goal

Beyla + Hubble + OTel SDK の **3-layer trace 同 trace_id 結合** を validation、 application traffic で end-to-end trace 確認。

#### Validation items

- **OTel SDK (= L1)**: monolith / frontend application code 内 span 生成、 Tempo で `service.name=monolith` / `service.name=frontend` query 可能
- **Beyla (= eBPF)**: monolith は Beyla 対象外 (= Ruby/gRPC 非対応のため `exclude_instrument` 済、 OTel SDK L1+L2 が担当)。 frontend / reverse-proxy / nginx は Beyla attach 済、 application traffic 投入で Beyla 由来 RED metrics (= Prometheus `http_server_request_duration_seconds`) + span (= Tempo) 確認
- **Hubble (= Cilium L7 flow)**: cluster 内 L7 flow visualize (= hubble.panicboat.net UI)、 application traffic で frontend → monolith ConnectRPC flow 確認
- **trace_id 結合**: 同 application request で 3 layer の span が同 trace_id で結合 (= Tempo / Grafana で 1 trace 内に 3 layer span 表示、 monolith は OTel SDK 由来のみで 2 layer)

#### Out of scope (= 6-3 内では partial cover)

- multi-cluster trace propagation (= panicboat 1 cluster のため不要)

### Component 13 checklist application 化

#### Goal

Phase 5-2 で nginx で達成した 13 checklist を application (= monolith + frontend + reverse-proxy) で再 validate、 production-grade application stack の end-to-end 動作確認。

#### Checklist (= Phase 5-2 closure doc Section 2 と同 pattern)

1. Pod 起動 + Cilium chaining mode IP (= application 3 Pods で確認)
2. ClusterIP Service DNS resolution (= frontend → monolith ConnectRPC)
3. Ingress → ALB (= 6-3 では NLB internet-facing、 別 pattern)
4. external-dns → Route53 (= `develop.panicboat.net` Route53 record auto-create)
5. ACM HTTPS (= `develop.panicboat.net` HTTPS 200 + TLS verify)
6. HPA cpu 50% scale (= application 投入で cpu usage 上昇 / KEDA cpu trigger、 ただし 6-3 では actual load test 不実施、 mechanism 確認のみ)
7. KEDA ScaledObject Prometheus scale (= application traffic 投入時に scale、 6-3 では mechanism 確認 + 引き継ぎ事項候補)
8. Karpenter node 増加 (= 既 4 nodes で十分、 mechanism 既 deploy 済)
9. Hubble L3/L4/L7 flow (= application traffic で flow 確認)
10. Beyla traces → Tempo (= frontend / reverse-proxy / nginx、 monolith は OTel SDK L1+L2 で別経路)
11. Loki logs (= OTel Collector → Loki、 `service_name` label 抽出済、 application 流入 validate)
12. Mimir metrics + Grafana dashboard (= application RED metrics 流入 + Grafana 表示)
13. ESO secret env 注入 (= 既 6-2 で monolith-database secret 動作確認)
14. Reloader rollout (= secret rotation で monolith Pod auto-rollout)
15. Grafana 認証ゲート (= 既 Phase 4-3 で deploy 済、 application traffic で再 validate)

### Component post-flight 7 連続 validate

#### Goal

5-1 L2 / 5-2 L1 pattern (= post-flight regression check で latent issue 検出) を **7 連続 validate** (= 4-3 / 5-1 / 5-2 / 6-1 / 6-2 + 6-2 fix forward chain + 6-3 で 7 連続)。

#### Validation sections

- Section 1: 既 deploy 済 component health (= Phase 1-5 + 6-1 + 6-2)
- Section 2: 既 deploy 済 application (= 6-3 で application が production-grade、 ただし 6-3 で demo nginx 削除のため Section 2 は 6-2 application が継続動作)
- Section 3: 6-3 追加 component health (= F1 / F2 / F4 / DNS / D2)
- Section 4: latent issue 検出

---

## 3. PR structure

### Platform PR (= Phase 6-3 本体)

**Title**: `feat(eks): Phase 6-3 — application end-to-end validation`

**Scope**:
- `kubernetes/components/nginx-sample/` 削除
- `kubernetes/manifests/production/` で nginx-sample 関連 hydrate cleanup (= make hydrate ENV=production)

### Pre PR (= Monitoring stack hardening)

**Title**: `fix(eks/monitoring): Phase 6-3 Theme B monitoring stack hardening`

**Scope**:
- `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` (= `nameValidationScheme: Legacy` で OTel Collector self-metric dotted label を Mimir 互換に escape)
- `kubernetes/components/beyla/production/values.yaml.gotmpl` (= `attributes.select.http_*` で label 数を 18→11 削減して Mimir limit 内、 `discovery.instrument` への 3.x syntax 移行、 `exclude_instrument: monolith` で Ruby/gRPC 非対応の対象外明示)
- `kubernetes/manifests/production/{prometheus-operator,beyla}/` hydrate
- `docs/superpowers/specs/2026-05-12-eks-production-monitoring-stack-hardening-investigation.md` (= root cause + best practice 選定の investigation doc)

**理由**: 13 checklist item 10 / 11 / 12 (= Beyla traces / Loki logs / Mimir metrics) の前提として monitoring stack の reject 0 件状態を確立。 Phase 7 Theme B の主要 work を 6-3 内で fix forward 完了。

### 並行 monorepo PR

**Title**: `feat: Phase 6-3 application end-to-end validation (= migration + OTel + DNS + terragrunt)`

**Scope**:

#### application code
- `services/monolith/workspace/Gemfile` + `uuid7` gem
- `services/monolith/workspace/config/db/migrate/*.rb` (= migration default `:uuidv7` 削除)
- `services/monolith/workspace/lib/types.rb` (= id 生成 UUID7 utilize) or 適切な箇所
- `services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb` (= F2 gruf custom interceptor)
- `services/monolith/workspace/config/initializers/gruf.rb` (= or 既 gruf config 箇所、 interceptor registration)

#### K8s manifests (= D2 + DNS)
- `services/reverse-proxy/kubernetes/base/{service.yaml, deployment.yaml, config/conf.d/*.conf, httproute.yaml}` (= D2 port 80 統一)
- `services/reverse-proxy/kubernetes/base/service.yaml` (= NLB internet-facing annotation + external-dns hostname + ACM cert ARN)
- `services/reverse-proxy/kubernetes/base/config/conf.d/*.conf` (= host header `develop.panicboat.net` での routing 追加)
- `services/reverse-proxy/kubernetes/base/httproute.yaml` (= hostnames `develop.panicboat.net` 追加)

#### terragrunt (= F4)
- `services/monolith/terragrunt/modules/variables.tf` (= explicit resource name variables 追加)
- `services/monolith/terragrunt/modules/main.tf` (= `monolith-${var.environment}` を variable 参照に置換)
- `services/monolith/terragrunt/envs/develop/terragrunt.hcl` (= inputs で resource name 確定)

---

## 4. Phase 5 + 6-1 + 6-2 lessons applied

- 5-1 L1 (= chart binary verify): platform 側 nginx-sample 削除に該当 chart 確認 (= chart 利用なし、 直接 manifest delete)
- 5-1 L2 / 5-2 L1 (= post-flight regression check): post-flight 7 連続 validate
- 5-2 L4 (= kustomization-only pattern): 該当なし (= application K8s manifests は monorepo 既 pattern 踏襲)
- 6-1 L1 (= chart actual structure verify): 該当なし (= 6-3 で chart 追加なし)
- 6-1 L3 (= post-flight issue category 整理): post-flight 7 連続 validate で category 別 record
- 6-1 L4 (= parallel PR scope に documentation 同期): 該当なし (= 6-3 で documentation update 軽微)
- 6-2 L1 (= chart actual structure verify CRD schema extension): 該当なし
- 6-2 L3 (= terragrunt state refresh と plan role 整合): F4 で同 pattern (= module 設計修正でも secret value IaC 外維持)
- 6-2 L5 (= post-flight 6 連続 validate): 7 連続 validate に extend

---

## 5. 引き継ぎ事項解消

| # | 項目 | 6-3 対応 |
|---|---|---|
| #28 | monolith Hanami migration failure investigation | **解消** (= F1 Ruby UUIDv7 生成) |
| #32 | application identity domain | **解消** (= develop.panicboat.net 公開、 production 化時に dystopia.city = 引き継ぎ #33 へ) |

### 6-3 で新規追加引き継ぎ事項候補

- **#34**: AWS Secrets Manager `panicboat/nginx/demo` secret manual 削除 (= nginx delete の manual operation)
- **#35**: KEDA ScaledObject for application (= 6-3 では mechanism 確認のみ、 actual scale-up validation は application traffic profile 確定後)

---

## 6. Phase 7+ への bridge

Phase 5 closure doc Phase 6+ candidate themes と同 pattern、 Phase 6 完了後の Phase 7+ candidate themes:

### Theme A. Multi-environment + release process (= 引き継ぎ #33 + #29、 primary focus 推奨)

panicboat monorepo の **最終形達成**:

- staging + production env active 化 (= workflow-config.yaml で 3 env active、 monorepo `clusters/{develop,staging,production}/` + `services/*/kubernetes/overlays/{develop,staging,production}/` + `services/*/terragrunt/envs/{develop,staging,production}/`)
- release-please integration (= service 単位 conventional commits + auto version bump + release PR)
- container-builder workflow に semver tag push 設定追加 (= `type=semver,pattern={{version}}`)
- service 単位 ImagePolicy multi-env pattern (= develop `^latest$` / staging `^release-pr-` / production `^v\d+\.\d+\.\d+$`)
- dystopia.city public 公開 (= Route53 zone + ACM cert + external-dns config + reverse-proxy host header)
- K8s namespace 分離 (= namespace `develop` / `staging` / `production`、 1 cluster で並立)
- 3 RDS instance (= monolith-{develop,staging,production}、 cost ~$45/month)

### Theme B. Monitoring stack hardening (= 6-3 Pre PR で fix forward 完了、 残 watch のみ)

- 6-3 Pre PR で 3 problem 全 fix 完了 (= investigation doc 参照):
  - Mimir `max-label-names-per-series` reject (= 引き継ぎ #21、 Beyla `attributes.select` で label 数 18→11 削減で解消)
  - OTel Collector self-metric dotted label reject (= Prometheus `nameValidationScheme: Legacy` で escape)
  - Beyla traces 片肺 (= 引き継ぎ #31、 monolith は Ruby/gRPC 非対応で exclude_instrument 済、 frontend / reverse-proxy は application traffic 投入で確認)
- 残 Phase 7+ watch:
  - Beyla 公式 Ruby gRPC support 動向 (= 対応されれば monolith の `exclude_instrument` 撤去 + Beyla 経由 distributed trace 取得可能)
  - Mimir UTF-8 label name 対応 (= 対応されれば Prometheus `nameValidationScheme` を default UTF8 に戻し native dotted attribute 直送可能)

### Theme C. Platform tool version 統一 + cleanup (= 引き継ぎ #24 + #26)

- panicboat 全 repo (= monorepo + platform) で tool version manager 統一 (= mise / aqua いずれか single source of truth)
- 既 commit comments の "when" / "future" 記述 systematic cleanup (= CLAUDE.md Documentation rule 遵守)

### Theme D. OTel Operator chart upgrade (= 引き継ぎ #25)

- chart 0.155.0+ (= Ruby auto-injection native support 想定 version) upgrade
- monolith deployment.yaml の env vars hardcode 撤去 + `inject-ruby` annotation 復活
- L2 ruby auto-injection native 利用

### Theme E. Other minor improvements

- 引き継ぎ #29 base / overlays 設計再評価 (= staging / production active 化時に併せ実施、 Theme A 内 cover)
- D4 frontend access log 有効化 (= 必要時)
- 残 minor items

### Phase 7 primary focus 推奨

**Theme A. Multi-environment + release process** (= panicboat application が user-facing になる重要 phase、 production grade release process 確立)。 引き継ぎ #29 / #33 を 1 theme で systematic 対応。

---

## 7. Out of scope

以下は本 6-3 で対応しない:

- **release-please integration** (= Theme A、 Phase 7 で systematic)
- **staging + production env active 化** (= Theme A、 Phase 7)
- **dystopia.city public 公開** (= Theme A、 Phase 7 で develop.panicboat.net から migrate)
- **OTel Operator chart upgrade** (= 引き継ぎ #25、 Theme D)
- **base / overlays 設計再評価** (= 引き継ぎ #29、 Theme A 内)
- **6-2 で base に修正した env-specific 内容を overlays/develop に migrate** (= 引き継ぎ #29 と同 axis、 Theme A 内)
- **Phase 6 closure doc 作成** (= Phase 5 closure pattern と同様、 6-3 完了後の別 PR で作成)

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| F1 Ruby UUIDv7 application code 修正で side effect (= 既 entity / repository code との互換性) | application code 修正前に panicboat monorepo の既 id 生成 pattern 確認、 plan 段階で実装範囲確定 |
| F2 gruf custom interceptor の OTel SDK との integration 不整合 (= initializer load order / tracer provider 未初期化) | Hanami boot order + Gruf.configure timing で OTel SDK init 確実に先行、 plan 段階で具体 implementation 確定 |
| DNS develop.panicboat.net 公開で NLB internet-facing + ACM cert 紐付け unsuccess | reverse-proxy Service annotation の AWS LB Controller 解釈確認 (= ACM cert ARN annotation の actual deploy 結果) |
| F4 terragrunt module 修正で AWS resource accidental destroy | `terragrunt plan` で diff 0 を必ず確認、 module 修正前後で resource name 不変 verify |
| nginx delete で ALB monitoring-uis IngressGroup 動作影響 | Phase 4-3 で 4 monitoring UIs と並立、 nginx 削除で 4 UIs は影響なし想定、 post-flight で再 validate |

---

## 9. Validation checklist (= 6-3 完了条件)

### Pre PR (= Monitoring stack hardening)
- [ ] Mimir distributor reject 0 件 / 1min (= invalid-label + max-label-names-per-series)
- [ ] Beyla `/metrics` の http_server_request_duration_seconds_bucket series が ≤ 12 labels
- [ ] Beyla DaemonSet 2/2 Running、 frontend + reverse-proxy + nginx attach 維持、 monolith 不 attach
- [ ] Prometheus scrape config に `metric_name_validation_scheme: legacy` 反映確認

### Platform PR + 並行 monorepo PR (= 同日 merge)

#### F1 monolith migration fix
- [ ] monolith Pod migration 成功 (= application log で `Sequel migrator: applied migration`)
- [ ] 業務 table create 確認 (= `\dt` で identity.users 等)
- [ ] application traffic で id 生成 + DB query success

#### F2 monolith OTel trace
- [ ] Tempo で `service.name=monolith` span 流入確認
- [ ] application traffic で gruf RPC ごと span 生成 + propagation 確認

#### F4 terragrunt module 修正
- [ ] `terragrunt plan` で diff 0 確認 (= resource name 不変)
- [ ] develop env AWS resource 既存維持、 application 動作継続

#### DNS develop.panicboat.net 公開
- [ ] `dig develop.panicboat.net` で Route53 record 確認
- [ ] `curl -v https://develop.panicboat.net/` で HTTPS 200 + TLS verify success
- [ ] external-dns log で record auto-create 確認

#### D2 reverse-proxy port 80
- [ ] reverse-proxy Pod listen 80 + Service port 80 + NLB target port 80

#### nginx delete
- [ ] `nginx.panicboat.net` HTTP 404 / no-resolve
- [ ] nginx Pod 0 個
- [ ] ALB rule 自動削除確認

#### 3-layer observability + 13 checklist application 化
- [ ] 13 checklist 全 item application 化 validate
- [ ] OTel SDK + Beyla + Hubble の 3 layer trace 結合 (= monolith は Beyla 対象外なので OTel SDK + Hubble の 2 layer)

#### post-flight 7 連続 validate
- [ ] Phase 1-5 + 6-1 + 6-2 既存 component zero regression
- [ ] 6-2 application stack 継続動作 (= 6-3 で 6-2 application stack に 修正 / 拡張)
- [ ] 6-3 追加 component all healthy
- [ ] latent issue 検出時 fix forward PR で resolve (= 5-1 L2 / 5-2 L1 pattern 7 連続)
- [ ] post-execution learnings doc 作成 (= 別 PR、 plan に section 追加)
- [ ] Phase 6 closure doc 作成 (= 6-3 完了後の別 PR、 Phase 5 closure pattern 踏襲)

---

## References

### Phase 6 sub-project specs / plans / learnings

- Phase 6-1 spec: `docs/superpowers/specs/2026-05-10-eks-production-monorepo-migration-foundation-design.md`
- Phase 6-1 plan + learnings: `docs/superpowers/plans/2026-05-10-eks-production-monorepo-migration-foundation.md`
- Phase 6-2 spec: `docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md`
- Phase 6-2 plan + learnings: `docs/superpowers/plans/2026-05-10-eks-production-monorepo-application-deploy.md`

### Phase 5 closure doc (= reference for Phase 6 closure doc 作成 pattern)

- `docs/superpowers/specs/2026-05-10-eks-production-phase-5-closure-design.md`

### platform roadmap

- `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

### Component reference

- panicboat monorepo: https://github.com/panicboat/monorepo
- AWS NLB Controller annotations: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/
- ExternalDNS service annotation: https://github.com/kubernetes-sigs/external-dns/blob/master/docs/sources/service.md
- googleapis/release-please-action: https://github.com/googleapis/release-please-action (= Phase 7 Theme A reference)
- Ruby `uuid7` gem: https://rubygems.org/gems/uuid7
- Gruf interceptor docs: https://github.com/bigcommerce/gruf#interceptors
- OpenTelemetry Ruby tracer API: https://opentelemetry.io/docs/instrumentation/ruby/manual/
