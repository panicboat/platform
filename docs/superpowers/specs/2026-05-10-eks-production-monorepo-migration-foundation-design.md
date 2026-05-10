# EKS Production Phase 6-1: Monorepo Migration Foundation (= Cilium Gateway API + Flux GitRepository + OTel Operator)

> **Phase**: roadmap Phase 6 (= application migration theme) の **第 1 sub-project (= Foundation)**
>
> **Nature**: prerequisite component deploy (= application 投入前の platform 拡張)、Phase 1-5 既存 component に **3 件 platform 拡張** + **1 件 monorepo 修正** を追加
>
> **Goal**: panicboat monorepo (= Hanami + Next.js + reverse-proxy 3 services) migration の prerequisite として、Cilium Gateway API enable / Flux GitRepository monorepo 追加 / OTel Operator chart deploy を実施。Phase 6-2 で application services を deploy 可能な platform foundation を整える。

---

## 1. Phase 6 overview + 6-1 position

### Phase 6 theme (= closure doc Phase 6+ candidate A 採用)

panicboat monorepo (= Hanami gRPC backend + Next.js BFF + reverse-proxy) を eks-production cluster に migration。Phase 5 で確立した demo nginx end-to-end validation pattern を **production-grade application で extend**。

closure doc (= `docs/superpowers/specs/2026-05-10-eks-production-phase-5-closure-design.md`) の Phase 6+ candidate themes A-D から **A. Application code migration** を primary focus として採用。scope は最小限に絞り、引き継ぎ事項のうち以下のみ対応:

- **#4 OTel Operator + Instrumentation CR**: 完全採用 (= L1 application code OTel SDK + L2 K8s auto-injection 両方)
- **#13 Cilium Gateway API east-west 利用**: 本 6-1 で対応 (= monorepo 既存設計が Cilium Gateway 前提)
- **#21 Mimir max-label-names-per-series 30 → 35**: application 投入時に reject 発生したら 6-2 / 6-3 で fix forward

非対応:

- **#18 cert-manager SelfSigned use case 限定 docs** (= memory file で代替)
- **#19 mTLS chain verify default 化** (= Hanami ↔ Next.js は mTLS 不採用、Cilium WireGuard で transport encrypt)
- **B 全般 (= post-flight automation)** (= individual issue 発生時に都度対応)
- **C 全般 (= multi-tenant + retention)** (= 1 environment + 1 application 前提と矛盾)
- **D 全般 (= security hardening)** (= incremental 対応で十分)

### Phase 6 sub-projects + 6-1 position

| Sub-project | Scope | Status |
|---|---|---|
| **6-1 Foundation** | Cilium Gateway API enable + Flux GitRepository monorepo + OTel Operator chart deploy + monorepo nginx 削除 (= 並行 PR) | 本 spec の対象 |
| 6-2 Application deploy | monolith + frontend + reverse-proxy deploy + RDS provision (= terragrunt) + OTel SDK init + Instrumentation CR | 6-1 完了後に brainstorming |
| 6-3 End-to-end validation + post-flight regression check | 3-layer observability (= Beyla + Hubble + OTel) + DNS / ACM + Phase 5-2 nginx 13 checklist application 化 | 6-2 完了後に brainstorming |

---

## 2. 6-1 Foundation scope (= 5 components A-E)

### Component A: Cilium Gateway API enable

#### Goal

Cilium Gateway API を enable し、application 側の HTTPRoute resource (= monorepo `services/reverse-proxy/kubernetes/base/httproute.yaml`、parentRef `cilium-gateway` namespace `default`) を 6-2 で reconcile 可能にする。

#### Implementation

- platform 既 deploy 済 Cilium chart の `values.yaml.gotmpl` に Gateway API enable 設定を追加
- Cilium 1.16+ で Gateway API CRD (= `gateway.networking.k8s.io/v1` Gateway / HTTPRoute / GRPCRoute) 自動 install
- GatewayClass `cilium` が auto-provision (= Cilium 自身が Gateway controller として function)
- 既 enable 済 Cilium 機能 (= chaining mode, WireGuard transparent encryption, Hubble L7 visibility) との conflict なし、coexist

具体的な values 修正は plan 段階で確定 (= chart version + 既 values 構造を見て決定)。

#### Architecture position

```
External (= ALB Ingress, 北南、既)
   ↓
ClusterIP Services (= L3/L4 routing, 既)
   ↓
Cilium L3/L4 + WireGuard + Hubble (= 既)
   ↓
Cilium Gateway API (= 6-1 で enable、L7 east-west routing 機能)
   ↓ 6-2 で利用
HTTPRoute / Gateway (= application 側 manifests、6-2 で monorepo cascading deploy)
```

#### Validation

- `kubectl get gatewayclass cilium` → `Accepted=True`
- `kubectl get crd | grep gateway.networking.k8s.io` で Gateway API CRD 存在確認
- 既 Cilium 機能 (= Hubble metrics 流入継続, WireGuard tunnel 確立継続, chaining mode で Pod IP 割当継続) regression なし

---

### Component B: Cilium Gateway resource (= kustomization-only pattern)

#### Goal

monorepo の HTTPRoute (= `parentRefs.name: cilium-gateway`, `namespace: default`) が attach する Gateway resource を deploy。

#### Implementation

- Location: `kubernetes/clusters/eks-production/components/cilium-gateway/`
- Pattern: kustomization-only (= Phase 5-2 L4 lesson 適用、`gateway-api` / `nginx-sample` reference)
- Files:
  - `kustomization.yaml`
  - `gateway.yaml` (= Gateway resource 1 つ)

#### Gateway resource content (= 期待値)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

(= application 側 HTTPRoute は `default` namespace から attach 想定。allowedRoutes の namespace 範囲は plan 段階で確定)

#### Validation

- `kubectl get gateway -n default cilium-gateway` → `Accepted=True, Programmed=True`
- `kubectl describe gateway -n default cilium-gateway` で listener `http` Ready

---

### Component C: Flux GitRepository monorepo + cluster Kustomization

#### Goal

panicboat monorepo を platform Flux 管理対象に追加、6-2 で各 service Kustomization (= monorepo `clusters/develop/services/{service}/service.yaml` 内蔵) を resume 可能な状態にする。

#### Implementation strategy

monorepo の **Option A** (= `clusters/develop` cascading 参照) を採用。platform 側に GitRepository + cluster Kustomization 1 つ追加で、cascading で全 services Flux Kustomization が deploy される構造。

ただし 6-1 完了時点では application services を deploy しない方針のため、**cluster Kustomization の `spec.suspend: true`** で suspend 状態で deploy。6-2 で resume して各 service deploy 開始。

#### Resource location

- Location: platform 既 Flux config directory (= `kubernetes/clusters/eks-production/flux-config/` 等、既存 pattern を確認後 plan で確定)
- Files:
  - `gitrepository-monorepo.yaml`
  - `kustomization-monorepo-cluster.yaml`

#### GitRepository content

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: monorepo
  namespace: flux-system
spec:
  url: https://github.com/panicboat/monorepo
  ref:
    branch: main
  interval: 5m
```

(= public repo なので secretRef 不要)

#### Kustomization content

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monorepo-cluster
  namespace: flux-system
spec:
  interval: 5m0s
  path: "./clusters/develop"
  prune: true
  sourceRef:
    kind: GitRepository
    name: monorepo
  suspend: true  # 6-2 で resume
```

#### Parallel monorepo PR (= "(b) 並行 merge")

monorepo に以下 PR を並行 merge:

- 削除対象:
  - `services/nginx/` ディレクトリ
  - `clusters/develop/services/nginx/` ディレクトリ
  - `clusters/develop/services/kustomization.yaml` から `nginx` 行
- 並行 merge 完了で `clusters/develop/services/kustomization.yaml` の `resources` が `monolith / frontend / reverse-proxy` の 3 services に絞られる
- monorepo PR は platform 6-1 PR と **同日 merge** (= order constraint なし、両方 main に取り込み)

#### Validation

- `kubectl get gitrepository -n flux-system monorepo` → `Ready=True, Conditions[Fetched]=True`
- `kubectl get kustomization -n flux-system monorepo-cluster` → `Suspended=True` (= 6-1 では suspend 状態想定)
- monorepo PR merge 後に `clusters/develop/services/kustomization.yaml` から nginx 削除済を確認 (= GitRepository が最新 commit を fetch している)

---

### Component D: OTel Operator chart deploy

#### Goal

OTel Operator + Instrumentation CR の base infrastructure を 6-2 application deploy 前に ready にする。Instrumentation CR 自体は 6-2 で application namespace (= `default`) に追加。

#### Implementation

- Location: `kubernetes/clusters/eks-production/components/opentelemetry-operator/`
- Pattern: helmfile + values.yaml.gotmpl (= Phase 1-5 確立 pattern)
- Files:
  - `kustomization.yaml`
  - `helmfile.yaml.gotmpl`
  - `values.yaml.gotmpl`

#### Helm chart

- Repo: `open-telemetry` (= https://open-telemetry.github.io/opentelemetry-helm-charts)
- Chart: `opentelemetry-operator`
- Latest stable version 利用 (= chart version は plan 段階で確定 + 5-1 L1 chart binary verify systematic step 適用)
- Namespace: `opentelemetry-operator-system`

#### Values (= minimal)

```yaml
admissionWebhooks:
  certManager:
    enabled: true  # 既 deploy 済 cert-manager 利用、自前 cert generate を回避
manager:
  collectorImage:
    repository: ""  # Instrumentation CR で個別指定するため、Operator default 不要
```

(= 詳細 values は plan 段階で chart version に応じて確定)

#### Validation

- OTel Operator Pod (= `opentelemetry-operator-system` namespace) Running + Ready
- `kubectl get crd | grep opentelemetry.io` で `instrumentations.opentelemetry.io`, `opentelemetrycollectors.opentelemetry.io` 等 CRD 存在
- cert-manager 経由 admission webhook cert ready (= 5-1 L3 lesson 適用、SelfSigned 不採用、CA-based ClusterIssuer 利用)

---

### Component E: Post-flight regression check (= Phase 5 L2 / 5-2 L1 pattern 4 連続 validate 機会)

#### Goal

6-1 deploy 後に Phase 1-5 既存 component の regression / latent issue を検出。Phase 5 で 3 連続 validate established の pattern を **4 連続** に拡張。

#### Check sections

##### Section 1: 既 deploy 済 component health

- ALB Ingress (= aws-load-balancer-controller): all Ingress healthy
- Cilium L3/L4 (= chaining mode): all node Cilium agent Ready, WireGuard tunnel 確立継続
- Cilium Hubble: metrics 流入継続, hubble.panicboat.net access OK
- Monitoring stack:
  - Prometheus / Mimir / Loki / Tempo / Grafana の Pod Ready
  - Grafana 4 UI (= grafana / hubble / prometheus / alertmanager) OAuth gate 動作継続
  - Mimir distributor reject rate 0 (= 既 #314 fix forward 状態維持、application 投入前なので reject 急増は想定外)
- ESO + Reloader: ExternalSecret sync 継続
- cert-manager: 既存 Certificate Ready

##### Section 2: 既 deploy 済 application 継続動作

- demo nginx (= Phase 5-2 deploy 分): nginx.panicboat.net HTTPS 200 + ESO 経由 secret env 維持

##### Section 3: 6-1 追加 component 自体の health

- Cilium Gateway API: GatewayClass + Gateway Accepted + Programmed
- GitRepository monorepo: Ready
- monorepo-cluster Kustomization: Suspended (= 6-2 で resume 待ち)
- OTel Operator: Pod Running + CRD installed + admission webhook cert ready

##### Section 4: latent issue 検出 (= 5-1 L2 / 5-2 L1 pattern 4 連続 validate)

- Cilium chart values 修正後の rollout で発覚する設定 conflict (= 例: gatewayAPI と既 enable 機能の interference)
- monorepo Flux Kustomization suspend 状態の Reconcile loop で発覚する設定不整合
- OTel Operator chart deploy で発覚する admission webhook 設定 (= cert-manager との integration、namespace 関連、5-1 L3 lesson の SelfSigned 不採用 verify)
- 検出時は fix forward PR で resolve

#### Validation

- 全 check item PASS
- 既 deploy 済 component の Pod restart 数増加なし
- Phase 1-5 既知 issue 以外の new issue 検出 0 (= 検出した場合は fix forward + learnings 記録)

---

## 3. Phase 5 lessons 適用

### Lessons applied

| Lesson | 適用箇所 |
|---|---|
| 5-1 L1 (= chart binary verify systematic step) | OTel Operator chart deploy + 必要時 Cilium chart upgrade で binary verify (= 5 連続 validate 機会) |
| 5-1 L2 / 5-2 L1 (= post-flight regression check) | Component E で 4 連続 validate |
| 5-2 L4 (= kustomization-only component pattern) | Component B (= Cilium Gateway resource) |
| 5-1 L3 (= cert-manager SelfSigned mTLS 不可) | OTel Operator admission webhook で CA-based ClusterIssuer 確認 (= SelfSigned 回避) |

### New lesson 候補 (= 6-1 deploy で観察対象)

- 6-1 deploy で Phase 1-5 の latent issue を **4 連続 validate** で検出した場合: 5-1 L2 / 5-2 L1 pattern の継続性確認 + new latent issue category の整理
- Cilium chart values 修正の **既機能 regression** 観察 (= chaining mode / WireGuard / Hubble の動作継続性) → "in-place chart values 変更時の既機能 baseline 比較" pattern の lesson 候補

---

## 4. 引き継ぎ事項解消

| # | 項目 | 6-1 での対応 |
|---|---|---|
| #13 | Cilium Gateway API east-west 利用 | **解消** (= Component A + B で enable + Gateway resource deploy) |

(他 引き継ぎ事項は 6-2 / 6-3 で対応、または incremental)

---

## 5. Out of scope

以下は 6-2 / 6-3 で対応:

- application services (= monolith / frontend / reverse-proxy) の deploy → 6-2
- AWS RDS provision (= terragrunt) → 6-2
- application code 側 OTel SDK init (= L1) → 6-2
- Instrumentation CR application namespace 配置 (= L2) → 6-2
- HTTPRoute / Service (= application 側 routing) → 6-2 で monorepo 既存 manifests 利用
- DNS / ACM の application domain 公開 → 6-3
- 3-layer observability validation (= Beyla + Hubble + OTel 同 trace_id 結合) → 6-3
- Phase 5-2 nginx 13 checklist の application 化 → 6-3

以下は対応しない (= 引き継ぎ事項に明示記録、incremental 対応):

- post-flight automation framework 化 (= 引き継ぎ #5)
- multi-tenant + retention (= 引き継ぎ #2 / #3)
- security hardening framework (= 引き継ぎ #11 / #12 等)

---

## 6. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Cilium chart values 修正で既機能 regression (= chaining mode / WireGuard / Hubble) | rollout 前に既機能 健全性 baseline 取得、rollout 後比較 (= Component E Section 1) |
| GitRepository public repo access 失敗 (= rate limit / network) | GitHub public repo の 5 min interval は問題なし、必要時 PAT secret 追加 |
| OTel Operator admission webhook の cert-manager integration 失敗 (= 5-1 L3 lesson 関連) | CA-based ClusterIssuer 既 deploy 済 (= Phase 4-1 + 5-1 PR #316) を利用、SelfSigned 回避を values で確認 |
| monorepo PR 並行 merge timing 不整合 (= platform PR merge 後 monorepo PR 未 merge で nginx Pod cascading deploy) | Kustomization suspend 状態で deploy するため cascading なし、6-1 完了 = suspend 状態で nginx も deploy されない |
| Cilium 1.16+ 未満 で Gateway API 機能不足 | 既 deploy version を plan 段階で確認、必要時 chart upgrade を 6-1 scope に追加 (= 5-1 L1 binary verify 適用) |
| OTel Operator chart 1.x で API 変更 | plan 段階で chart latest stable + values 構造確認、必要時 version pin |

---

## 7. Validation checklist (= 6-1 完了条件)

- [ ] Cilium chart values 修正 deploy 完了 + GatewayClass `cilium` Accepted
- [ ] Gateway `cilium-gateway` (= namespace default) Accepted + Programmed
- [ ] GitRepository `monorepo` Ready + Fetched
- [ ] Kustomization `monorepo-cluster` Suspended (= 6-2 で resume 想定)
- [ ] monorepo PR (= nginx 削除) merge 完了 + GitRepository が最新 commit を fetch
- [ ] OTel Operator Pod Running + CRD installed + admission webhook cert ready
- [ ] Phase 1-5 既存 component regression なし (= post-flight Section 1 + 2 全 PASS)
- [ ] 6-1 追加 component health (= post-flight Section 3 全 PASS)
- [ ] latent issue 検出時 fix forward PR で resolve (= 5-1 L2 pattern 4 連続 validate established 確認)
- [ ] post-execution learnings doc 作成

---

## References

### Phase 5 sub-project specs / plans / learnings

- Phase 5 closure doc: `docs/superpowers/specs/2026-05-10-eks-production-phase-5-closure-design.md`
- Phase 5-1 spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- Phase 5-2 spec: `docs/superpowers/specs/2026-05-10-eks-production-nginx-end-to-end-validation-design.md`

### platform roadmap

- `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`

### Phase 4 sub-project specs

- Phase 4-1 (= cert-manager + Cilium TLS): `docs/superpowers/specs/2026-05-08-eks-production-cert-manager-foundation-and-cilium-tls-design.md`
- Phase 4-2 (= ESO + Reloader): `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md`
- Phase 4-3 (= Grafana auth): `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md`

### Component reference

- monorepo: https://github.com/panicboat/monorepo
- monorepo CLAUDE.md: 各 service workspace README
- OTel Operator chart: `open-telemetry/opentelemetry-operator` (= https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-operator)
- Cilium Gateway API doc: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
