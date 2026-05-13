# EKS Production Phase 7-0: LB Hardening (= AWS LB Controller SG 重複 fix + Cilium upgrade + Cilium Gateway hostNetwork mode + ALB IngressGroup migration)

> **Phase**: roadmap Phase 7 (= Multi-environment + release process foundation) の **第 0 sub-project (= LB hardening prerequisite)**
>
> **Nature**: cluster LB architecture re-org、 panicboat の architecture spec (= "north-south は ALB Controller、 east-west は cilium-gateway") に LB layer を整合、 multi-env active 化 (= 引き継ぎ #29 / #33) の LB provision blocking 解消
>
> **Goal**: Phase 6 closure で identify した 引き継ぎ事項 **#37 / #39** を 1 sub-project で systematic 解消。 #37 (= AWS LB Controller SG 重複 panic loop) で multi-env LB provision blocking 解消、 #39 (= Cilium Gateway hostNetwork mode + ALB IngressGroup migration) で reverse-proxy 廃止 + monthly ~$79 cost 削減 + architectural drift 解消 + Gateway 層 JWT validation 採用余地確保。

---

## 1. Phase 7-0 overview

### Phase 7-0 goal

panicboat current の LB architecture は 3 NLB 並立 (= reverse-proxy NLB + cilium-gateway NLB + monitoring-uis ALB) + classic ELB recreate cycle = architectural drift。 これを panicboat 設計 spec (= "north-south は ALB Controller、 east-west は cilium-gateway") に re-align、 1 ALB (= application IngressGroup) + Cilium Gateway hostNetwork mode で完結。

### Sub-project scope + 順序

1. **#37 fix** (= AWS LB Controller SG 重複 reconcile error 解消、 multi-env LB provision の prerequisite)
2. **Cilium upgrade** (= 1.18.6 → 1.19+ / 1.20+、 hostNetwork mode 改善期待)
3. **#39 migration** (= Cilium Gateway hostNetwork mode + ALB IngressGroup + reverse-proxy 廃止)
4. **Fallback** (= #39 fail 時 #40 bridge revival + 7-0 partial completion)

### 完了条件 (= "(c) panicboat の PR 手戻り最小化 + best effort + partial fallback")

- **strict completion**: #37 fix + #39 success
  - reverse-proxy 廃止 + cilium-gateway NLB 削除 + ALB IngressGroup 経由 develop.panicboat.net 公開 + Cilium Gateway 経由 全 ingress traffic + Gateway 層 JWT validation 余地確保
  - monthly cost ~$79 削減
- **partial completion** (= #39 fail 時): #37 fix + Cilium upgrade + #40 bridge revival
  - classic ELB recreate cycle 防止 + monthly cost ~$10-20 削減
  - reverse-proxy 構成維持、 #39 を Phase 8+ 引き継ぎに persist

### 作業中の cluster impact 許容

- cluster traffic 一時停止 OK (= maintenance window 設定不要、 user 許容)
- AWS resource cost 増は **NG** (= 試行錯誤で LB / RDS / etc を作りっぱなしにしない)
- 試行錯誤 / revert / retry を許容

---

## 2. 7-0 scope (= 3 components + 1 fallback)

### Component A: #37 AWS LB Controller SG 重複 fix

#### 現状

`aws/eks/modules/main.tf` (= terraform-aws-modules/eks/aws v21.20.0 経由) で **node SG** が `kubernetes.io/cluster/eks-production: owned` tag を持つ (= 直近 PR #355-#358 の module update で追加)。 EKS cluster SG (= `eks-cluster-sg-...`) と 2 重 tag、 AWS LB Controller の "1 SG expectation" で panic loop。

panic log:
```
"expected exactly one securityGroup tagged with kubernetes.io/cluster/eks-production for eni eni-..., got: [sg-06a911469ce77dc76 sg-0c5888ca990469b88]"
```

影響: 既 register 済 LB target は healthy 維持、 ただし **新規 LoadBalancer / Ingress 作成で reconcile fail** (= 例: #39 で新規 ALB Ingress 作成必要、 そこで blocking)。

#### 修正方針

terragrunt eks module の `node_security_group_tags` variable (= module spec 次第、 implementation で actual variable structure 確認) で cluster tag override / 除去。 EKS cluster SG のみが cluster tag を維持 → AWS LB Controller の SG identification が 1 SG に確定。

option (= module variable 仕様による、 implementation で確定):
- (a) `node_security_group_tags = {}` (= 全 default tag 除去、 影響範囲広い、 risk あり)
- (b) cluster tag のみ override 削除 (= 最小変更、 推奨)

#### 影響評価

| 利用 system | cluster tag 利用? | 影響 |
|---|---|---|
| AWS LB Controller | ✓ (= panic 原因) | tag 除去で 正常化 |
| EBS CSI driver | ✗ (= IRSA 経由 IAM) | 影響なし |
| VPC CNI | ✗ (= ENI tag 別 axis) | 影響なし |
| Karpenter | ✗ (= cluster identification は別 tag + annotation) | 影響なし |

#### Validation

- `terragrunt plan` で **diff = node SG の tag 1 個除去のみ** 確認 (= no resource recreation、 in-place tag update)
- apply 後 AWS LB Controller log で panic loop 停止確認
- 新規 test LoadBalancer Service / Ingress 作成で TargetGroupBinding reconcile success 確認

#### Risk + mitigation

- **risk**: `node_security_group_tags` variable で cluster tag を override できない module 仕様の可能性 (= module-internal hardcoded tag)
- **mitigation**: 確認後 override 不可なら module を fork / inline copy で対処、 もしくは AWS CLI で manual tag 削除 + terragrunt state 整合性確保

### Component B: Cilium upgrade (= 1.18.6 → 1.19+ / 1.20+)

#### 現状

Cilium 1.18.6 (= Phase 4-1 deploy)。 panicboat 設定:
- chaining mode (= aws-cni 経由 IPAM / datapath、 Cilium は L7 / policy / observability 担当)
- Gateway API enabled
- L7 Proxy 独立 DaemonSet (= cilium-envoy)
- socketLB + Hubble + dnsProxy + Prometheus + ServiceMonitor

#### Upgrade target

**1.19.x or 1.20.x** (= 公式 release notes で hostNetwork mode の CEC CR migration logic 改善が含まれた earliest version を implementation 段階で確定)。 panicboat の "minimal change" 原則で earliest version 優先。

#### Upgrade 戦略

1. **helmfile.yaml で chart version bump** (= 1.18.6 → 1.19.x / 1.20.x)
2. **values.yaml.gotmpl で compatibility 確認**: deprecated values 確認 + migration (= 例: `attributes.kubernetes.enable` の syntax 変更可能性、 helm values の rename / removal)
3. **CRD update**: `cilium-cli` or `kubectl apply` で新 version の CRDs (= CiliumEnvoyConfig / Gateway API extension / etc) install
4. **pre-flight check**: cluster health snapshot (= Pod / Service / CRD 全 list + 既 fix forward state 記録、 fail 時 reapply 用)
5. **DaemonSet rollout**: cilium-operator → cilium-envoy → cilium の順序 (= ordered)、 panicboat 4 nodes で sequential ~2-3 min cluster traffic 一時停止
6. **post-upgrade smoke test**: 既 fix forward (= Beyla attributes.select / Prometheus nameValidationScheme / Theme B 全般) regression 確認

#### Breaking change 想定 risk

| 影響範囲 | risk | mitigation |
|---|---|---|
| helm values rename / removal | medium (= 例: `attributes.*` の syntax 変更) | implementation で公式 upgrade guide 精読、 deprecated values list を check |
| CRD structure 変更 | medium (= 例: CiliumEnvoyConfig listener field 変更で 既 deploy CEC への影響) | pre-flight で 既 CEC CR state snapshot、 必要なら delete → recreate |
| Phase 6-3 Theme B fix forward への regression | low-medium (= Beyla / Prometheus 設定は cilium core と独立、 ただし cilium-envoy 経由 OTLP export 経路で間接影響) | post-upgrade で Mimir reject rate / Tempo trace 流入 / Beyla `/metrics` content を Theme B fix forward と同 method で再 verify |
| chaining mode + socketLB | low (= 1.18 → 1.19 / 1.20 で chaining + socketLB 互換性 stable 想定) | post-upgrade で application pod-to-pod traffic 確認 (= frontend ↔ coredns 等 hubble observe) |

#### Rollout 戦略 (= user 許容 cluster downtime 前提)

- maintenance window 設定不要 (= 作業中 traffic 停止 OK)
- pre-upgrade snapshot: cluster state full backup (= `kubectl get all -A -o yaml` 等)
- chart upgrade `helmfile sync` で apply
- DaemonSet rollout sequential、 各 node ~30s 一時停止
- post-flight regression check (= Theme B fix forward + 13 checklist 再 validate)

#### Fallback

- chart upgrade で deploy error / cluster recover 不能 (= 例: CRD migration logic で stuck) なら **helmfile revert (= 1.18.6)** で復旧
- CRD downgrade は backward compat 不確実 (= 1.20 で deploy した CRD resource を 1.18 で 解釈不可可能性)、 必要なら CRD resource 手動 delete + 1.18 で recreate
- user 許容 cluster downtime で trial-and-error 進められる

### Component C: #39 Cilium Gateway hostNetwork mode + ALB IngressGroup migration

#### Architecture target

```
client (= internet)
  → ALB (= application IngressGroup、 443 ACM TLS termination)
  → cilium-gateway-cilium-gateway Service:8080 (= ClusterIP、 target-type=ip で hostNetwork Pod IPs = node IPs)
  → Cilium Gateway (= Envoy on host port 8080)
  → HTTPRoute (= frontend HTTPRoute、 parentRef cilium-gateway、 hostname develop.panicboat.net)
  → frontend Service:80 (= ClusterIP、 直接 backend)
```

#### Platform side changes (= panicboat/platform)

**1. `kubernetes/components/cilium/production/values.yaml.gotmpl`**:
```yaml
gatewayAPI:
  enabled: true
  hostNetwork:
    enabled: true
```

**2. `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml`** (= listener port 80 → 8080):
```yaml
listeners:
  - name: http
    port: 8080
    protocol: HTTP
```

理由:
- eks-pod-identity-agent が hostNetwork で port 80 を占有 (= cluster validate で確認済)
- 1024 未満特権 port 回避で NET_BIND_SERVICE capability 不要

**3. 新 ALB Ingress** (= 場所: `kubernetes/components/cilium/production/kustomization/` 配下、 もしくは 新 `kubernetes/components/application-ingress/` component、 implementation で確定):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: application
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: application
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    external-dns.alpha.kubernetes.io/hostname: develop.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: develop.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cilium-gateway-cilium-gateway
                port:
                  number: 8080
```

panicboat の `monitoring-uis` IngressGroup pattern を踏襲 (= ACM cert auto-discovery で `*.panicboat.net` wildcard 自動 attach、 TLS 1.3 policy、 HTTP → HTTPS redirect)。

#### Monorepo side changes (= panicboat/monorepo)

**1. `services/reverse-proxy/` 全 directory 削除** (= service.yaml / deployment.yaml / httproute.yaml / config/conf.d/*.conf / kustomization.yaml)

**2. `services/frontend/kubernetes/base/httproute.yaml` 新規**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: default
spec:
  parentRefs:
    - name: cilium-gateway
      namespace: default
  hostnames:
    - develop.panicboat.net
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
```

#### Deploy 順序

1. **platform PR merge** 先 (= cilium values + Gateway port 8080 + ALB Ingress)
2. **ExternalDNS が新 ALB Ingress を pick up** → Route53 record を ALB hostname に切替 (= 旧 reverse-proxy NLB hostname と一時並立、 ExternalDNS TXT owner record で source 識別、 latest update が winner)
3. **monorepo PR merge** (= reverse-proxy 削除 + frontend HTTPRoute 追加)
4. **旧 reverse-proxy NLB + cilium-gateway NLB が auto-delete** (= Service / Pod 不在で AWS LB Controller cleanup)
5. **ExternalDNS が旧 source TXT record cleanup**

#### Validation

- ALB provision active 確認
- `dig develop.panicboat.net` で 新 ALB hostname resolve 確認
- `curl https://develop.panicboat.net/` で 200 OK + TLS verify pass
- 旧 NLB 2 個 auto-delete 確認 (= cost ~$79/month 削減 verify)
- Hubble L7 flow visualize for ingress traffic (= 新規 functionality、 cilium-gateway 経由 traffic を hubble observe で 観測可、 architecture diagram 上の ingress L7 visibility 復活)

### Fallback (= #39 fail 時 #40 bridge revival)

#### Trigger 条件

Cilium 1.19 / 1.20 upgrade 後でも:
- hostNetwork mode の CEC CR migration logic 動作不能
- ALB → cilium-envoy backend 不健全 (= target health check fail 持続)
- 他 unexpected issue で migration 完遂不可

#### Fallback path

1. **platform side revert** (= cilium values の hostNetwork.enabled false に戻す、 cilium-gateway.yaml port 80 に戻す、 ALB Ingress 削除)
2. **Cilium 1.18 へ downgrade** (= upgrade で発生した issue が原因なら) **or upgrade version 維持で hostNetwork 不採用継続**
3. **#40 bridge revival** (= `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` に `loadBalancerClass: service.k8s.aws/nlb` default 設定追加)
4. **reverse-proxy 構成維持** (= monorepo PR は 7-0 fail で merge せず、 reverse-proxy NLB 経由 internet 公開 持続)

#### Fallback completion

- cost 削減: ~$10-20/month (= classic ELB のみ防止、 ~$79 削減は未達)
- #39 を **Phase 8+ 引き継ぎ** に persist (= 別 Cilium version で再試行 or 別 approach)
- Phase 7-0 を partial completion で closure (= panic loop 解消 + Cilium upgrade + classic ELB cycle 防止)

---

## 3. PR structure

### Platform PRs

**PR 1: #37 fix (= terragrunt eks module node SG tag 除去)**

Title: `fix(aws/eks): remove kubernetes.io/cluster/X tag from node SG (= AWS LB Controller SG 重複解消)`

Scope:
- `aws/eks/modules/main.tf` (= `node_security_group_tags` variable で cluster tag override 除去)
- 必要なら `aws/eks/modules/variables.tf` (= variable 追加 / 修正)
- `aws/eks/envs/production/terragrunt.hcl` (= inputs で値確定、 必要時)

**PR 2: Cilium upgrade (= 1.18.6 → 1.19.x / 1.20.x)**

Title: `chore(eks/cilium): upgrade Cilium 1.18.6 → 1.x.y (= hostNetwork mode 改善期待)`

Scope:
- `kubernetes/components/cilium/production/helmfile.yaml` (= chart version bump)
- `kubernetes/components/cilium/production/values.yaml.gotmpl` (= deprecated values migration、 必要時)
- hydrate

**PR 3: #39 Cilium Gateway hostNetwork mode + ALB IngressGroup (= platform 側)**

Title: `feat(eks): Cilium Gateway hostNetwork mode + ALB IngressGroup (= reverse-proxy 廃止経路確立)`

Scope:
- `kubernetes/components/cilium/production/values.yaml.gotmpl` (= `gatewayAPI.hostNetwork.enabled: true`)
- `kubernetes/components/cilium/production/kustomization/cilium-gateway.yaml` (= listener port 80 → 8080)
- 新 ALB Ingress yaml (= application IngressGroup、 場所は implementation で確定)
- hydrate

### Monorepo PR

**PR 4: reverse-proxy 廃止 + frontend HTTPRoute**

Title: `feat: reverse-proxy 廃止 + frontend HTTPRoute (= Cilium Gateway 経由 direct routing)`

Scope:
- `services/reverse-proxy/` 全 directory 削除
- `services/frontend/kubernetes/base/httproute.yaml` 新規
- `services/frontend/kubernetes/base/kustomization.yaml` (= httproute.yaml 追加)

### Fallback PR (= #39 fail 時)

**PR F1: cilium revert + #40 bridge (= 7-0 partial completion)**

Title: `fix(eks): revert Cilium Gateway hostNetwork + AWS LB Controller default loadBalancerClass`

Scope:
- platform PR 3 の revert (= cilium values + cilium-gateway.yaml + ALB Ingress)
- `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` で `loadBalancerClass: service.k8s.aws/nlb` default 設定
- AWS Console / CLI で 既 orphan classic ELB delete

---

## 4. Phase 6 lessons applied

- **5-1 L2 / 5-2 L1 (= post-flight regression check pattern)**: Cilium upgrade 後の既 fix forward (= Theme B Beyla / Prometheus 設定) regression check を post-flight で systematic 実施、 detection panicboat の 7 連続 validate pattern を 8 連続に extend
- **6-3 (= Flux suspend + ローカル apply + 試行錯誤)**: #39 試行は cluster impact 大 (= cilium DaemonSet rollout)、 ただし user 許容 cluster downtime で trial-and-error 進められる、 panic 発生時 immediate revert path 確保
- **6-3 Theme B (= root cause fix + best practice 採用)**: 雑対応 (= AWS LB Controller annotation で SG specify 等) を避け、 root cause (= node SG cluster tag 除去) で fix forward
- **6-3 (= panicboat の "PR 手戻り最小化" 哲学)**: 7-0 完了条件を (c) (= partial fallback 許容) で確定、 panic 発生時 即 revert + 引き継ぎ持ち越しで 7-0 closure 可

---

## 5. 引き継ぎ事項解消

| # | 項目 | 7-0 対応 |
|---|---|---|
| #37 | AWS LB Controller SG 重複 reconcile error | **解消** (= Component A) |
| #39 | Cilium Gateway hostNetwork mode + ALB IngressGroup migration | **解消** (= Component C、 ただし fail 時 partial に persist) |
| #40 | panicboat AWS LB Controller helm values で loadBalancerClass default 設定 | **内包解消** (= Component C success で副次解消)、 fail 時 fallback で必要部分のみ実施 |

### 7-0 で新規追加引き継ぎ事項候補 (= 想定)

- #39 fail 時、 別 Cilium version or 別 approach での再試行を **Phase 8+ 引き継ぎ** に persist
- Cilium upgrade で発覚した想定外 regression が あれば fix forward PR + 引き継ぎ事項追加

---

## 6. Phase 8+ への bridge

7-0 完了後、 Phase 7 の他 sub-projects (= 7-1 OTel Operator upgrade、 7-2 base / overlays re-org、 7-3 Pod Identity injection detection、 7-4 Platform consolidation) に進む。 加えて 7-0 で persist された #39 fail 残作業 (= 別 Cilium version 等での再試行) を Phase 8+ で systematic 検討。

---

## 7. Out of scope

以下は対応しない (= 7-0 scope 外):

- **#33 multi-env active 化** (= Phase 7-2 base / overlays re-org 完了後 + 別 sub-project)
- **#5 post-flight check 自動化** (= "やりたいけど今じゃない")
- **#10 OTel Collector exporter alias check 自動化** (= 同上)
- **Cilium upgrade に伴う Theme B fix forward regression が発生した場合** (= 7-0 内 fix forward で対応、 ただし新規 framework 化は scope 外)
- **dystopia.city 公開** (= #33 と統合、 Phase 7+)

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| #37 fix で terraform-aws-modules/eks/aws v21.20.0 の `node_security_group_tags` variable が cluster tag override 不可な仕様 | implementation 段階で variable structure 確認、 override 不可なら module fork / AWS CLI manual + state 整合性確保 |
| Cilium upgrade で既 fix forward への regression (= Beyla / Prometheus / Theme B 全般) | pre-flight で fix forward state snapshot、 post-upgrade で regression check + 即 fix forward PR |
| Cilium upgrade で CRD downgrade 不能 (= 1.20 で deploy CRD を 1.18 で解釈不可) で chart revert 不能 | pre-upgrade で CRD resource snapshot、 必要なら CRD resource 手動 delete + 旧 version で recreate |
| #39 試行で cilium-gateway-cilium-gateway Service が hostNetwork mode で ClusterIP 化されず LoadBalancer 維持 | classic ELB recreate cycle 発生、 即 revert + #40 bridge fallback |
| ALB → cilium-envoy hostNetwork backend で target health check fail (= /  endpoint が cilium-envoy で responding しない) | healthcheck-path を `/` から `/healthz` 等の cilium-envoy 標準 endpoint に変更、 もしくは TCP health check に切替 |
| Phase 7-0 全体完了に時間かかる場合 (= 試行錯誤 / fail / revert / retry chain) | (c) 完了条件で partial closure 可、 #39 fail 部分を Phase 8+ 引き継ぎに persist |

---

## 9. Validation checklist (= 7-0 完了条件)

### strict completion (= #39 success 時)

- [ ] #37 fix: AWS LB Controller log で panic loop 停止確認 + 新規 LB provision 復活確認
- [ ] Cilium upgrade: cilium-cli `cilium status` で 1.19+ / 1.20+ 確認、 全 DaemonSet rollout success
- [ ] 既 fix forward regression なし (= Mimir reject 0 件 / Beyla `/metrics` Theme B 設定 active / Prometheus nameValidationScheme legacy)
- [ ] #39 migration: dig develop.panicboat.net で 新 ALB hostname resolve、 curl HTTPS 200 OK、 旧 NLB 2 個 auto-delete、 cost ~$79/month 削減 verify
- [ ] Hubble L7 flow ingress visibility 確認 (= 新規 functionality、 cilium-gateway 経由 traffic を hubble observe で 観測可)

### partial completion (= #39 fail 時)

- [ ] #37 fix: panic loop 停止確認 + 新規 LB provision 復活
- [ ] Cilium upgrade: success or skip (= 必要なら downgrade)
- [ ] #40 bridge revival: AWS LB Controller default loadBalancerClass 設定 + 既 orphan classic ELB delete + cost ~$10-20/month 削減 verify
- [ ] reverse-proxy 構成維持、 develop.panicboat.net 経由 internet 公開 functional
- [ ] #39 を Phase 8+ 引き継ぎ事項として記録
