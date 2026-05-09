# EKS Production: nginx End-to-end Validation (Phase 5-2) Design

> **Phase**: roadmap Phase 5 (End-to-end validation) の Sub-project 5-2 (= core sub-project)
>
> **Prerequisites**: Phase 4 完了 (= cert-manager + ESO + Reloader + Grafana 認証ゲート + 公開) + Phase 5-1 (= Beyla foundation) 完了 + 累計 fix forward 4 件 (= PR #311 oauth2-proxy 4 instances + PR #312 Mimir RF=1 + PR #314 cardinality limit + PR #316 Cilium Hubble CA-based ClusterIssuer)
>
> **Goal**: EKS production cluster (`eks-production`) に **demo nginx application** を deploy し、roadmap Phase 5 完了条件 13 checklist を **end-to-end validate** する。Phase 1-4 で構築した全 component (= Cilium chaining + ALB Controller + external-dns + ACM + cert-manager + ESO + Reloader + Beyla + KEDA + metrics-server + Mimir + Loki + Tempo + Hubble) を nginx 投入で actual data flow validation。Phase 5-1 で蓄積した L1-L5 (特に L2 post-flight regression check / L4 smoke test pattern / L5 application-level test) を意識的に適用。

---

## Context

### Phase 5-1 + 累計 fix forward 完了後の状況 (= 5-2 brainstorming 開始時の前提)

- ✅ cert-manager v1.20.2 + selfsigned-cluster-issuer + cilium-hubble-ca-issuer (= Phase 4-1 + PR #316 fix forward)
- ✅ External Secrets Operator + ClusterSecretStore `aws-secrets-manager` + Reloader (= Phase 4-2)
- ✅ oauth2-proxy 4 instances (= PR #311 fix forward) + 4 monitoring UIs 公開 + Grafana adminPassword ESO 化 (= Phase 4-3)
- ✅ Mimir replication_factor: 1 (= PR #312) + max_global_series_per_user: 500000 + apiserver bucket drop (= PR #314)
- ✅ Cilium Hubble TLS architectural fix (= PR #316、CA-based ClusterIssuer で mTLS 動作)
- ✅ Beyla DaemonSet (= Phase 5-1)、`default` namespace 配下の application Pod を eBPF auto-instrument
- ✅ KEDA + metrics-server (= Phase 1 で deploy 済、ScaledObject CRD ready)
- ✅ ALB Controller + external-dns (= Phase 1 foundation-addons-beta、IngressGroup `monitoring-uis` deploy 済)
- ✅ ACM wildcard cert `*.panicboat.net` (= `aws/alb/` で provision 済)
- 🔜 Phase 5-2 で nginx 投入 → 13 checklist end-to-end validation
- 🔜 Phase 5-3 で rightsizing audit + Phase 5 全体 closure

### Roadmap Phase 5 完了条件 (= 13 checklist) の 5-2 配分

| # | Checklist | 担当 sub-project |
|---|---|---|
| 1 | Pod 起動 + Cilium chaining mode IP | **5-2** |
| 2 | ClusterIP Service DNS resolution | **5-2** |
| 3 | Ingress → ALB | **5-2** |
| 4 | external-dns → Route53 | **5-2** |
| 5 | ACM HTTPS | **5-2** |
| 6 | HPA cpu 50% scale | **5-2 (= KEDA ScaledObject cpu trigger)** |
| 7 | KEDA ScaledObject Prometheus scale | **5-2 (= KEDA ScaledObject prometheus trigger、Beyla RED metrics)** |
| 8 | Karpenter node 増加 | **5-2 (= load test 中の node provisioning)** |
| 9 | Hubble L3/L4/L7 flow | **5-2 (= Phase 4-3 + PR #316 + 5-1 で確立した Hubble pipeline + nginx traffic)** |
| 10 | Beyla traces → Tempo | **5-1 partial (= smoke test) + 5-2 full (= nginx production-grade)** |
| 11 | Loki logs (= Fluent Bit → OTel → Loki) | **5-2 (= nginx access log)** |
| 12 | Mimir metrics + Grafana dashboard | **5-2 (= Beyla RED metrics 経由 Mimir)** |
| 13 | ESO secret env 注入 + Reloader rollout | **5-2 (= AWS Secrets Manager `panicboat/nginx/demo`)** |
| 15 (補助) | Grafana 認証ゲート保護 | **4-3 既達成、5-2 で nginx data flow 経由再 validate** |

= 5-2 完了で **13/13 達成** (= 5-1 で #10 partial validation 済)。

---

## Architecture

### High-level architecture

```
              Internet (public, port 443 only)
                        │
                        │ HTTPS (= ACM wildcard *.panicboat.net auto-discovery)
                        ▼
                AWS ALB (= Phase 4-3 deploy 済 ALB を共有)
                IngressGroup: monitoring-uis
                [Host-based routing]
                        │
        ┌───────────────┼─────────────────┬────────────┐
        ▼               ▼                 ▼            ▼
  grafana.        hubble.        alertmanager.   nginx.panicboat.net
  panicboat       panicboat      panicboat       (= 新規追加、本 sub-project)
  .net            .net           .net
  (= auth-gated)  (= auth-gated) (= auth-gated)  (= public、本 sub-project target)
        │               │                 │            │
        ▼               ▼                 ▼            ▼
   oauth2-proxy 4 instances (= Phase 4-3)         nginx Pod
                                                  (= 新規 default namespace)
                                                       │
                                                       │ HTTP request
                                                       ▼
                                              ┌──────────────────────┐
                                              │  nginx Deployment    │
                                              │  (= replicas: 2 init)│
                                              │  - env: DEMO_MESSAGE │
                                              │    (= ESO 由来)      │
                                              │  - reloader auto:true│
                                              └──────┬──────┬────────┘
                                                     │      │
                            ┌────────────────────────┘      │
                            │ eBPF probes (= Phase 5-1 Beyla)
                            ▼                              │
                  Beyla DaemonSet (= each node)            │
                            │                              │
                            ├─ OTLP gRPC :4317              │
                            │   → OTel Collector → Tempo   │
                            │   (= http_server_*_count 等  │
                            │      RED metrics + traces)   │
                            │                              │
                            └─ /metrics :9090               │
                                → ServiceMonitor            │
                                → Prometheus               │
                                → remote_write             │
                                → Mimir                    │
                                       │                   │
                                       │ Prometheus query  │
                                       ▼                   │
                                  KEDA ScaledObject        │
                                  (= multi-trigger:        │
                                   cpu + prometheus)       │
                                       │                   │
                                       │ scales            │
                                       ▼                   │
                          nginx Deployment ←───────────────┘
                          replicas (= 2 → N)
                                       │
                                       │ stdout
                                       ▼
                                  Fluent Bit (= DaemonSet)
                                       │
                                       ▼
                                  OTel Collector → Loki
                                       │
                                       │ Cilium Hubble L7 観測
                                       ▼
                                  Hubble UI / Hubble metrics → Mimir
```

### Data flow per checklist item (= 13 + 2 = 15 validation items)

| # | Checklist | Data flow |
|---|---|---|
| 1 | Pod 起動 + Cilium IP | nginx Pod schedules → Cilium chaining mode から Pod IP 割当 |
| 2 | ClusterIP DNS resolution | nginx Service (= ClusterIP) → CoreDNS が `nginx.default.svc.cluster.local` 解決 |
| 3 | Ingress → ALB | nginx Ingress → ALB Controller が `monitoring-uis` ALB に rule 追加 |
| 4 | external-dns → Route53 | Ingress annotation `external-dns.alpha.kubernetes.io/hostname: nginx.panicboat.net` → Route53 record 自動作成 |
| 5 | ACM HTTPS | ACM wildcard cert auto-discovery (= `*.panicboat.net`) → ALB に bind |
| 6 | HPA cpu 50% | KEDA ScaledObject の cpu trigger (= 50% threshold) で nginx Pod cpu 使用率 50% 超で scale-up |
| 7 | KEDA Prometheus query | KEDA ScaledObject の prometheus trigger (= Beyla RED metrics rate query) で 1 RPS 超で scale-up |
| 8 | Karpenter node 増加 | nginx replicas 増加で Pod 不在 (= scheduling unsatisfied) → Karpenter が node provision |
| 9 | Hubble L3/L4/L7 flow | Cilium agent が nginx Pod traffic 観測 → Hubble UI で表示 |
| 10 | Beyla traces | Beyla eBPF probe attach → OTLP gRPC → OTel Collector → Tempo |
| 11 | Loki logs | nginx stdout → Fluent Bit → OTel Collector → Loki |
| 12 | Mimir metrics | Beyla `/metrics` :9090 → ServiceMonitor → Prometheus → remote_write → Mimir |
| 13 | ESO secret 注入 | AWS Secrets Manager `panicboat/nginx/demo` → ExternalSecret → K8s Secret `nginx-demo` → nginx env `DEMO_MESSAGE` |
| 14 | Reloader rollout | AWS secret 変更 → ESO refresh → K8s Secret update → Reloader が nginx Deployment auto-rollout |
| 15 | Grafana 認証ゲート | Phase 4-3 で完了済、Phase 5-2 では nginx の各 datasource query で再 validate |

---

## Components & File Structure

### Component matrix

| Component | New / Modified | namespace | 役割 |
|---|---|---|---|
| **nginx-sample** | 新規 component (= kustomization-only、helmfile 不在) | `default` (= 既存 namespace 活用) | Phase 1-4 全 component end-to-end validation 用 demo nginx application |
| **AWS terragrunt stack** | **不要** | — | nginx は AWS access 不要 (= Phase 4-2 ESO IAM role 経由で AWS Secrets Manager から secret 取得、新規 IAM role 不要) |
| **chart binary verify** | **不要** | — | plain K8s manifests (= chart 不在)、L1 systematic step skip |

### File structure (= 新規作成 / 変更)

**新規 (= K8s component `nginx-sample`)**:

```
kubernetes/components/nginx-sample/
└── production/
    └── kustomization/
        ├── kustomization.yaml          # 全 resource roll-up
        ├── deployment.yaml             # nginx Deployment + env from ExternalSecret + Reloader annotation
        ├── service.yaml                # ClusterIP Service for nginx
        ├── ingress.yaml                # ALB Ingress (= monitoring-uis IngressGroup join)
        ├── scaled-object.yaml          # KEDA ScaledObject (= cpu + prometheus multi-trigger)
        └── external-secret.yaml        # ExternalSecret for AWS Secrets Manager → K8s Secret nginx-demo
```

**自動生成 (= production hydrate output)**:

```
kubernetes/manifests/production/nginx-sample/{kustomization.yaml, manifest.yaml}    # 新規
kubernetes/manifests/production/kustomization.yaml                                  # 修正 (= ./nginx-sample auto-insert)
```

**変更しないファイル**:

- `kubernetes/components/nginx-sample/namespace.yaml` (= **不要、`default` namespace 既存活用**)
- `aws/*` (= 全 terragrunt stack、AWS access は Phase 4-2 ESO IAM role を経由)
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= namespace 新規作成なし)
- 他 K8s components

### nginx-sample の各 manifest 概略

#### `deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: default
  annotations:
    reloader.stakater.com/auto: "true"   # Reloader watch (= Secret/ConfigMap 変更で auto-rollout)
spec:
  replicas: 2                             # initial replicas、KEDA で 2 → N に scale
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine        # 公式 nginx 最新 stable (= 実装時に確認)
          ports:
            - containerPort: 80
              name: http
          env:
            - name: DEMO_MESSAGE          # AWS Secrets Manager 由来 (= ESO 経由)
              valueFrom:
                secretKeyRef:
                  name: nginx-demo
                  key: message
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

#### `service.yaml`

ClusterIP Service、port 80 → targetPort http、label selector `app: nginx`。

#### `ingress.yaml`

```yaml
# nginx.panicboat.net で public access、monitoring-uis IngressGroup 共有
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: monitoring-uis     # ★ Phase 4-3 既 ALB 共有
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: nginx.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: nginx.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
```

#### `scaled-object.yaml`

```yaml
# KEDA ScaledObject with multi-trigger (= cpu 50% + prometheus query)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: nginx
  namespace: default
spec:
  scaleTargetRef:
    name: nginx                          # nginx Deployment 参照
  minReplicaCount: 2
  maxReplicaCount: 10
  triggers:
    - type: cpu
      metricType: Utilization
      metadata:
        value: "50"                      # cpu 50% threshold
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
        threshold: "1"                   # 1 RPS threshold
        query: |
          sum(rate(http_server_request_duration_seconds_count{service_name="nginx"}[1m]))
```

#### `external-secret.yaml`

```yaml
# AWS Secrets Manager panicboat/nginx/demo → K8s Secret nginx-demo
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nginx-demo
  namespace: default
spec:
  secretStoreRef:
    name: aws-secrets-manager           # Phase 4-2 deploy 済 ClusterSecretStore
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: nginx-demo
    creationPolicy: Owner
  data:
    - secretKey: message
      remoteRef:
        key: panicboat/nginx/demo
        property: message
```

#### `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - scaled-object.yaml
  - external-secret.yaml
```

### nginx 設定 (= demo content)

- **container**: `nginx:1.27-alpine` (= 実装時 latest stable 確認)、Welcome page (= nginx default `/usr/share/nginx/html/index.html`) を serve
- **custom HTML 不要**: env var `DEMO_MESSAGE` は kubectl exec で env 確認 (= visual HTML 化は overengineering)
- **ESO secret rotation 検証**: AWS Secrets Manager 更新 → ESO `force-sync` annotation → K8s Secret update → Reloader が Pod rollout → `kubectl exec` で新 env 値確認

---

## Decisions

8 件、brainstorming で確定:

| # | Decision | 採用 | 採用理由 |
|---|---|---|---|
| 1 | Phase 5-2 scope | single sub-project (= 13 checklist + 2 補助 = 15 items を nginx で end-to-end validate) | Phase 4-3 と同水準 complexity、decomposition 不要 |
| 2 | Deploy 方式 | Plain K8s manifests (= kustomization-only component、helmfile 不在) | roadmap literal text と整合、demo nginx に chart wrapping は overengineering、`gateway-api` component の reference pattern を踏襲 |
| 3 | Access control | Public access (= ALB direct → nginx、認証なし) | 13 checklist の direct ALB → nginx flow を最 cleanest に validate、demo content (= nginx Welcome page) で漏洩 risk 低 |
| 4 | Ingress topology | `monitoring-uis` IngressGroup 共有 (= 既 ALB 再利用) | cost optimal、Phase 4-3 で確立した IngressGroup pattern 踏襲 |
| 5 | HPA + KEDA 同居 | KEDA ScaledObject 1 つで multi-trigger (= cpu + prometheus、KEDA が内部 HPA 管理) | conflict 完全回避、KEDA の正統的使い方、roadmap 両項目を 1 resource で satisfy |
| 6 | KEDA Prometheus trigger | Beyla RED metrics (= `http_server_request_duration_seconds_count` rate) | Phase 5-1 Beyla deploy の actual end-to-end validation 兼ねる、roadmap "Beyla traces + KEDA Prometheus" を同時 validate |
| 7 | nginx hostname | `nginx.panicboat.net` (= ACM wildcard auto-discovery) | 既 ACM `*.panicboat.net` で cover、external-dns annotation で Route53 record 自動作成 |
| 8 | ExternalSecret demo content | 1 key `message` (= JSON `{"message": "..."}`) を nginx env `DEMO_MESSAGE` に注入 | minimal demo、kubectl exec で env 確認 + AWS secret 変更 → Reloader rollout で 13 checklist #13 + #14 を validate |

---

## Manual Setup (= panicboat 事前作業)

Phase 5-2 deploy 前に panicboat による手動 setup 1 件:

### AWS Secrets Manager に `panicboat/nginx/demo` を投入

```json
{
  "message": "Hello from AWS Secrets Manager"
}
```

- secret name: `panicboat/nginx/demo`
- region: `ap-northeast-1`
- 読取権限: Phase 4-2 で provision 済 ESO IAM role (= `eks-production-eso`、`secretsmanager:GetSecretValue` on `secret:*`) で auto access、新規 IAM 不要

= Phase 4-3 で `panicboat/grafana/admin` + `panicboat/oauth2-proxy/google` を投入した同 pattern、AWS terragrunt 新規 stack 不要。

### Manual setup 不要項目

- **Google OAuth client**: 不要 (= nginx は public access、認証なし)
- **AWS terragrunt apply**: 不要 (= ESO IAM role 流用)
- **Pod restart 順序 (= 5-1 L3 lesson)**: ESO Pod は Phase 4-2 deploy 済 + 4-3 で restart 済、Pod Identity injection 動作中、5-2 で再 restart 不要

---

## Post-flight Check

deploy 後 verify、~20 項目を 5 layer で実施:

### A. Infrastructure layer (= 5 分以内)

1. nginx Deployment `replicas == 2`、全 Pod Running、Cilium chaining mode で Pod IP 割当
2. nginx Service ClusterIP active、`nginx.default.svc.cluster.local:80` で内部 DNS 解決可
3. nginx Ingress provision (= ALB Controller が `monitoring-uis` IngressGroup 既 ALB に rule 追加)
4. external-dns で Route53 record `nginx.panicboat.net` 自動作成
5. ALB の rule 確認 (= `nginx.panicboat.net` host header → nginx Service backend)
6. ExternalSecret `nginx-demo` Status=Ready、K8s Secret `nginx-demo` created with key `message`
7. nginx Pod env vars に `DEMO_MESSAGE` (= ESO 由来 K8s Secret 経由) 反映

### B. Application layer (= 10 分以内)

8. **HTTPS test (= roadmap #5)**: `curl -v https://nginx.panicboat.net/` → 200 OK + Welcome page、ACM wildcard cert 適用確認
9. **DNS test (= roadmap #4)**: `dig nginx.panicboat.net` → ALB DNS に resolve
10. **Beyla instrumentation (= roadmap #10)**: nginx に curl 数回 → Beyla logs で `instrumenting process cmd=/usr/sbin/nginx`、Tempo に `service.name=nginx` traces 流入
11. **Hubble L7 flow (= roadmap #9)**: Hubble UI で nginx Pod の L3/L4/L7 flow 確認 (= Phase 4-3 で deploy 済 hubble.panicboat.net 経由)
12. **Loki logs (= roadmap #11)**: nginx access log が Fluent Bit → OTel Collector → Loki に流入、Grafana Explore で `service_name="nginx"` query
13. **Mimir metrics (= roadmap #12)**: Beyla `/metrics` :9090 → Prometheus → Mimir、Grafana で `http_server_request_duration_seconds_count` query

### C. Autoscaling layer (= 30 分以内、load test 必要)

14. **HPA cpu trigger (= roadmap #6)**: nginx に CPU 負荷 (= `kubectl exec` で `yes > /dev/null` or `apt install -y stress; stress -c 1`)、KEDA ScaledObject の cpu trigger で replicas 2 → N に scale
15. **KEDA Prometheus trigger (= roadmap #7)**: nginx に HTTP load (= `kubectl run -- ab -n 10000 -c 10 http://nginx.../`)、`http_server_request_duration_seconds_count` rate > 1 RPS で replicas scale
16. **Karpenter scale-up (= roadmap #8)**: nginx replicas が node 容量超え → Pod Pending → Karpenter が新 node provision (= NodeClaim 作成)

### D. Secret rotation layer (= 60 分以内)

17. **ESO + Reloader integration (= roadmap #14)**: AWS Secrets Manager で `panicboat/nginx/demo.message` 値変更 → `kubectl annotate externalsecret -n default nginx-demo force-sync=now` で manual force-sync → K8s Secret update → Reloader が nginx Deployment auto-rollout → 新 Pod env で更新値確認

### E. Regression check (= post-flight 必須、5-1 L2 適用)

18. 既 deploy 済 component 全部 Running 維持 (= cert-manager / ESO / Reloader / oauth2-proxy / Mimir / Loki / Tempo / OpenTelemetry Collector / Beyla / hubble-relay / Cilium agent)
19. Mimir cardinality 観測 (= Beyla RED metrics 流入で active_series 増加、500K limit 余裕確認)
20. Phase 5-1 L2 (= post-flight regression check が past sub-project の latent issue を発見) を意識、想定外 component の CrashLoop / restart spike が無いか確認

---

## Rollback Patterns

| Pattern | 適用条件 | 操作 |
|---|---|---|
| **A. Standard rollback** | Phase 5-2 全体を巻き戻したい | Flux suspend → 5-2 merge commit を revert PR → resume |
| **B. nginx delete (= chart 不在 = 個別 resource delete)** | nginx 自体を停止、Phase 5-2 demo 終了後に cleanup | `kubectl delete -k kubernetes/components/nginx-sample/production/kustomization` で全 resource 削除、または kustomization.yaml から `./nginx-sample` を removal して Flux apply |
| **C. KEDA scale disable** | autoscaling 暴走時の緊急 stop | ScaledObject 削除 → KEDA-managed HPA も自動削除、nginx Deployment は static replicas 維持 |

---

## Risks & Mitigations

| Risk | mitigation |
|---|---|
| **Public nginx の Internet expose** | demo content (= Welcome page) のみで漏洩 risk 低、Phase 5-3 完了後に nginx-sample を archive 検討、必要なら ALB SG で source IP allowlist 追加 |
| **KEDA + HPA conflict (= 想定外 controller 競合)** | KEDA ScaledObject 1 つで multi-trigger 採用 (= Decision 5)、内部 HPA は KEDA 管理のみ、standalone HPA 不在 |
| **Beyla RED metrics で Mimir cardinality 急増** | Phase 5-1 PR #314 で 500K limit 設定済、本 sub-project で nginx 由来 metrics は service_name 単一 + status_code 数値、cardinality 増加 limited |
| **load test 中の Karpenter cluster cost spike** | demo load test は短時間 (= 数分)、Karpenter consolidation で load 解除後 30 分以内に node 削減、cost spike 最小 |
| **AWS Secrets Manager の手動投入忘れ** | Phase 4-3 / 5-1 同 pattern、Task 0 pre-flight check で manual setup 確認 step を組込 |

---

## Out of Scope (= Phase 5-3 / Phase 6+ へ postpone)

### Phase 5-3 (= rightsizing audit) で扱う

| 項目 | Phase 5-3 で扱う理由 |
|---|---|
| **Pod CPU requests audit + rightsizing (= 引き継ぎ #9)** | 5-2 で nginx + 観測 burst 後に必要、actual traffic 観測 data が蓄積された状態で実施 |
| **Phase 5 closure** | 5-3 で Phase 5 全体 (= 5-1 + 5-2 + 5-3) を closing |

### Phase 6+ で扱う

| 項目 | Phase 6+ で扱う理由 |
|---|---|
| **nginx-sample の archive / 削除** | demo 完了後の cleanup、production state の minimal 化 |
| **multi-application support** (= 別 application 追加時の IngressGroup 拡張) | 現 monitoring-uis 共有で足りる、application 増加時に再 evaluate |
| **AWS WAF / source IP allowlist on ALB** | 現 demo expose で risk 低、production application 投入時に評価 |
| **nginx custom HTML / ConfigMap-driven content** | 現 default Welcome page で十分、application code 投入時に再 design |
| **Beyla discovery scope 拡張 (= multi-namespace)** | nginx は default namespace、Phase 5-1 で discovery 設定済、追加 application 増加時に拡張 |

---

## Phase 5 引き継ぎ事項 update (= 5-2 完了時想定)

| 項目 | 5-2 完了時の状態 |
|---|---|
| 9. Pod CPU requests audit + rightsizing | Phase 5-3 で扱う (= 5-2 で nginx + load test 観測後) |
| その他 17 項目 (= 5-1 完了時の集計) | Phase 6+ 引き継ぎ (= 不変) |

= 5-2 完了で **新規引き継ぎ事項追加なし** (= post-flight regression check で latent issue 発覚した場合は別途 fix forward)、Phase 5-3 で 引き継ぎ #9 を解消予定。

---

## Sub-project 1-5-1 learnings 適用

| Learning (= 由来 sub-project) | Phase 5-2 への適用 |
|---|---|
| **L1 (= chart binary verify、5 連続 validation)** | Plain K8s manifests で **L1 not applicable**、ただし KEDA ScaledObject CRD 構造 + ExternalSecret apiVersion を Plan の前段で確認 |
| **L2 (= chart capability assumption の限界、4-3 new)** | KEDA Prometheus trigger の query syntax + threshold 形式を **KEDA docs full read で裏付け** (= brainstorming で実施済)、Beyla RED metric name の actual exposition format を Phase 5-1 smoke test で verify 済 |
| **L3 (= Pod Identity webhook timing-sensitive injection、4-3 new)** | nginx は AWS access 不要、L3 直接適用なし、Phase 4-2 ESO Pod Identity 継続動作前提を Task 0 で verify |
| **L4 (= distributed system replica / RF 整合、4-3 new)** | nginx は distributed ring 構造なし、L4 not applicable |
| **L5 (= AWS direct verify AccessDenied → application-level indirect proof、4-2 / 4-3 / 5-1 extension)** | post-flight check で **HPA / KEDA / Karpenter の actual scaling test** を必須化、static "ScaledObject Ready=True" だけでなく **load test で actual replica scale** を proof |
| **L6 (= subagent-driven development cadence、5 連続 stable)** | Plan task 数を **kustomization-only deploy + hydrate + PR の 3 layer split** で踏襲 (= AWS terragrunt 不要、helmfile 不在で chart binary verify step も不要、minimum complexity) |
| **5-1 L2 (= post-flight regression check が past sub-project の latent issue を発見、4-3 + 5-1 で 2 連続 established)** | Phase 5-2 post-flight で **3 連続 validate を期待** (= 過去 sub-project の latent issue が Phase 5-2 で表面化する可能性を意識、Section "Post-flight Check" #20 で明示) |
| **5-1 L3 (= cert-manager SelfSigned ClusterIssuer は mTLS 不可)** | nginx Ingress は server-only TLS (= ALB ACM)、mTLS 不在で適用なし、ただし境界条件を spec で明示 |
| **5-1 L4 (= Beyla smoke test pattern が effective、4-2 / 4-3 L5 extension)** | Phase 5-1 では test Pod (= 一時) で Beyla pipeline 動作確認、5-2 で **nginx 正式投入 = full application-level validation**、smoke test → production-grade test に拡大 |
| **5-1 L5 (= TLS / mTLS architectural correctness は cert Ready=True では不十分)** | nginx は server-only TLS、mTLS 不在で適用なし |
| **4-1 L5 (= chart version placeholder pattern)** | nginx image tag は actual `1.27-alpine` 等で pinned (= 実装時 latest stable 確認) |

---

## Phase 5 全体 perspective (= 5-2 完了時想定)

| Sub-project | scope | 状態 |
|---|---|---|
| **5-1 Beyla foundation** | Beyla DaemonSet 1 chart deploy | ✅ 完了 (= 引き継ぎ #6 part 1 解消) |
| **5-2 nginx + Ingress + ESO + HPA + KEDA** (= 本 spec) | nginx Deployment / Service / Ingress (= ALB) / ExternalSecret / KEDA ScaledObject、roadmap 13 checklist + 2 補助 = 15 items を end-to-end validate | 🔄 brainstorming → implementation |
| **5-3 rightsizing audit** | Pod CPU requests audit、引き継ぎ #9 解消、Phase 5 全体 closure | 🔜 5-2 完了 + 数日 traffic 観測後 |

= 5-2 完了で **roadmap Phase 5 完了条件 13/13 達成**、Phase 5-3 は **closure + rightsizing 専用**。

---

## References

- Phase 5-1 spec: `docs/superpowers/specs/2026-05-09-eks-production-beyla-foundation-design.md`
- Phase 5-1 plan + learnings: `docs/superpowers/plans/2026-05-09-eks-production-beyla-foundation.md`
- Phase 4-3 spec: `docs/superpowers/specs/2026-05-09-eks-production-grafana-auth-ingress-design.md` (= IngressGroup `monitoring-uis` 由来)
- Phase 4-2 spec: `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md` (= ESO + Reloader pattern)
- platform roadmap: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- gateway-api kustomization-only pattern: `kubernetes/components/gateway-api/production/kustomization/`
- KEDA ScaledObject docs: <https://keda.sh/docs/2.x/concepts/scaling-deployments/>
- KEDA Prometheus scaler: <https://keda.sh/docs/2.x/scalers/prometheus/>
- KEDA CPU scaler: <https://keda.sh/docs/2.x/scalers/cpu/>
- AWS ALB Controller IngressGroup: <https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.13/guide/ingress/annotations/#ingressgroup>
- Beyla RED metrics: <https://grafana.com/docs/beyla/latest/metrics/>
