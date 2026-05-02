# EKS Production Cilium Chaining Mode Design

## Overview

EKS production cluster `eks-production`（`ap-northeast-1`）に Cilium を chaining mode で導入し、VPC CNI と共存させた状態で Kube-Proxy Replacement (KPR) / Gateway Controller / 独立 Envoy DaemonSet / Hubble を有効化する。本 spec は **Plan 1b** として、Phase 1 Foundation の 3 plan のうち 2 つ目を扱う。

ロードマップ spec（`2026-05-02-eks-production-platform-roadmap-design.md`）の Decision 2 (chaining mode) と Decision 4 (Pattern B-Full) を継承する。新規 architectural decision は本 spec では生じず、**設定実装と Open Questions の実機検証**が主スコープ。

## Goals

1. Cilium 1.18.x を chaining mode（VPC CNI と共存）で `eks-production` に導入する
2. ロードマップ spec の Open Questions 1-4 を実機検証で解消する
3. Plan 1c 以降が依存する L7 Envoy / Gateway Controller / Hubble の動作基盤を作る
4. Cilium components を Flux GitOps の管理下に置き、以後の更新は GitOps 経由に統一する
5. Cilium 用に `kubernetes/components/cilium/production/` を新設し、`make hydrate ENV=production` の env-aware 化も合わせて行う

## Non-goals (Out of scope, with explicit follow-up tracking)

以下は本 spec で扱わない。各項目は明示的に follow-up 先を記録する。

- **Hubble UI の外部公開** → Phase 4 で oauth2-proxy / ALB OIDC を含めた認証ゲートと一括設計（Plan 4-x として別 spec で扱う）。本 spec 期間中は port-forward のみで運用
- **HTTPRoute / CiliumEnvoyConfig による monorepo 認証実装** → monorepo K8s 移行 spec
- **Cilium Cluster Mesh / Egress Gateway** → Future Specs（必要発生時に別 spec）
- **`endpointRoutes.enabled = false` の検証** → 本 spec 期間の検証で `true` が機能すれば再評価不要、Future Specs として記録
- **EKS CNI 戦略見直し（chaining → ENI mode 移行）** → ロードマップ spec の Future Specs を継承

## Architecture decisions

ロードマップ spec の決定を継承するのみ。本 spec で新規追加する決定はない。

| 継承元 | 内容 |
|---|---|
| Roadmap Decision 2 | CNI は chaining mode（VPC CNI primary + Cilium secondary） |
| Roadmap Decision 4 | 東西は Pattern B-Full（Cilium GW + HTTPRoute + CEC で JWT 検証） |

## Open Questions resolution（spec 確定値）

ロードマップ spec で未確定だった 4 項目について、本 spec で値を確定する。実機検証の手順は Verification セクションを参照。

| # | Question | 確定値 | 根拠 |
|---|---|---|---|
| Q1 | chaining + KPR + Gateway + CEC が EKS 1.35 / AL2023 ARM64 で動作するか | **直接検証で確認**。失敗時は逐次対処、最終フォールバックはロードマップ spec の Future Specs（ENI mode 移行）に escalate | AWS 公式 blog で chaining + KPR + L7 機能の事例があるが、EKS minor version / AMI / Cilium version の固有組み合わせは検証必須 |
| Q2 | KPR `true` (full) vs `partial` | **`true`（full）** | AWS 公式 blog の事例が full mode、Cilium 公式 chaining セットアップ手順も full mode で記述。`partial` は kube-proxy と Cilium の併存で挙動が読みづらい |
| Q3 | `endpointRoutes.enabled` の値 | **`true`** | chaining mode で Cilium 側に endpoint route を持たせると Hubble / NetworkPolicy が確実に機能する。`false` だと Cilium が endpoint を見えなくなる場合がある |
| Q4 | `envoy.enabled` を独立 DaemonSet vs agent 内蔵 | **`true`（独立 DaemonSet）** | Pattern B-Full で L7 proxy がクリティカルパスに入るため、agent crash / restart の影響を proxy から切り離す。Cilium 1.16+ の推奨パターン |

## Cilium production values

`kubernetes/components/cilium/production/values.yaml` の最終形：

```yaml
# =============================================================================
# CNI Chaining Mode（VPC CNI が IPAM/datapath を担当、Cilium は L7/policy/observability）
# =============================================================================
cni:
  chainingMode: aws-cni
  exclusive: false

# =============================================================================
# Routing & Masquerade
# =============================================================================
routingMode: native
endpointRoutes:
  enabled: true
enableIPv4Masquerade: false
ipv6:
  enabled: false

# =============================================================================
# Kube Proxy Replacement: 完全置換
# =============================================================================
kubeProxyReplacement: true
k8sServiceHost: <eks-api-endpoint>     # helmfile gotmpl で .Values.cluster.eksApiEndpoint から差し込み
k8sServicePort: 443

# =============================================================================
# Operator: HA
# =============================================================================
operator:
  replicas: 2
  rollOutPods: true

# =============================================================================
# L7 Proxy: 独立 DaemonSet
# =============================================================================
envoy:
  enabled: true

# =============================================================================
# Gateway API（東西用、北南は ALB Controller）
# =============================================================================
gatewayAPI:
  enabled: true

# =============================================================================
# Socket-level LB（Beyla / hostNetwork Pod が ClusterIP に到達するため）
# =============================================================================
socketLB:
  enabled: true

# =============================================================================
# Hubble（UI は port-forward only、Phase 4 で Ingress 公開）
# =============================================================================
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - icmp
      - http
    serviceMonitor:
      enabled: false                  # Phase 3 で prometheus-operator 導入後に true へ切り替え

# =============================================================================
# DNS Proxy（hostNetwork Pod の DNS resolution に必要）
# =============================================================================
dnsProxy:
  enabled: true

# =============================================================================
# Prometheus Metrics
# =============================================================================
prometheus:
  enabled: false                      # Phase 3 で prometheus-operator 導入後に true へ切り替え
```

local 環境（`kubernetes/components/cilium/local/values.yaml`）からの主な差分：

- `cni.chainingMode: aws-cni` + `cni.exclusive: false`（chaining 化）
- `ipam.operator.clusterPoolIPv4PodCIDRList` を削除（VPC CNI が IPAM 担当）
- `routingMode: native` を追加
- `endpointRoutes.enabled: true` を追加
- `enableIPv4Masquerade: false` に変更（local は true）
- `k8sServiceHost / k8sServicePort` を EKS API endpoint / 443 に変更（local は k3d server / 6443）
- `operator.replicas: 2` に変更（local は 1）
- `envoy.enabled: true` を追加（local 未指定）
- `hubble.metrics.serviceMonitor.enabled: false`（Phase 3 まで）
- `prometheus.enabled: false`（Phase 3 まで）

## Components 変更マトリクス

| File / Resource | 種別 | 内容 |
|---|---|---|
| `kubernetes/components/cilium/production/helmfile.yaml.gotmpl` | create | production env 用 helmfile。`k8sServiceHost` を `.Values.cluster.eksApiEndpoint` から差し込み |
| `kubernetes/components/cilium/production/values.yaml` | create | 上記 production values（gotmpl 置換あり） |
| `kubernetes/helmfile.yaml.gotmpl` | modify | `production` env block に `cluster.eksApiEndpoint` を追加 |
| `kubernetes/Makefile` | modify | `hydrate-index` を **env-aware** に変更（`find components/*/$(ENV)/namespace.yaml` で env 限定） |
| `kubernetes/manifests/production/` | regenerate | `make hydrate ENV=production` で `cilium/` と `00-namespaces/`（cilium namespace のみ）を再生成 |
| `aws/eks/modules/addons.tf` | modify | `kube-proxy` addon を **削除**（KPR=true で不要） |
| `aws/eks/envs/production/.terraform.lock.hcl` | regenerate | terragrunt apply で再生成 |

`kubernetes/components/cilium/production/namespace.yaml` は **作成しない**（Cilium は `kube-system` を使用、既存 namespace のため）。

### Makefile env-aware 化の方針

現状の `hydrate-index` は `find components -maxdepth 2 -name namespace.yaml` で全 component の namespace.yaml を env 非依存に収集している。これを「**`components/<comp>/<env>/` ディレクトリが存在する component のみ**」を対象にするロジックに変更する。

要件：

1. ある env 用の `make hydrate ENV=<env>` で生成される `manifests/<env>/00-namespaces/namespaces.yaml` には、その env で実際にデプロイされる component の namespace のみ含まれる
2. namespace.yaml の配置位置は **`components/<comp>/<env>/namespace.yaml`**（env-specific）と **`components/<comp>/namespace.yaml`**（env-non-specific）の両方をサポートする。env-specific が優先、なければ env-non-specific を fallback
3. 既存 local 環境の動作（opentelemetry / opentelemetry-collector / prometheus-operator の namespace が含まれる）を破壊しない後方互換性を維持

具体的な Makefile syntax は実装 plan で提示する。本 spec では **「env-aware かつ後方互換」** という設計要件のみを定める。

Phase 3 で全 component の namespace を `<comp>/<env>/namespace.yaml` 配下に移行した時点で、env-non-specific fallback path を削除する（Future Specs に記録）。

## Migration sequence

production cluster は現在 **kube-proxy DaemonSet（EKS managed addon）が動作中、Cilium 未 install** の状態。順序を間違えると Service routing が一時的に死ぬので、以下の順で実施する。

| Step | 内容 | 実行者 | Flux 状態 |
|---|---|---|---|
| 1 | production cluster の Flux Kustomization を suspend する: `flux suspend kustomization flux-system -n flux-system` | user | suspended |
| 2 | `kubernetes/components/cilium/production/` 一式 + Makefile env-aware 化 + `make hydrate ENV=production` 結果（`manifests/production/cilium/` + `manifests/production/00-namespaces/`）を 1 つの PR として main にマージ | controller (subagent) + user | suspended |
| 3 | operator が production cluster に `helm upgrade --install cilium cilium/cilium --version <ver> -n kube-system -f /path/to/rendered/values.yaml` で **手動 install**（Flux 経由ではない） | user | suspended |
| 4 | Verification checklist 完走（Q1-Q4 + Gateway API + connectivity test） | user | suspended |
| 5 | EKS の `kube-proxy` addon を terragrunt で削除（`aws/eks/modules/addons.tf` 修正 → PR → review → main merge → terragrunt apply） | user | suspended |
| 6 | kube-proxy 削除後の疎通再確認（Q2 の `kube-proxy NotFound` 含む） | user | suspended |
| 7 | `flux resume kustomization flux-system -n flux-system` で Flux 再開。Flux が既存の Helm release を adopt し、以後 GitOps 管理 | user | active |
| 8 | `flux reconcile kustomization flux-system -n flux-system` 後、Cilium が drift なしで sync 完了することを確認（冪等性） | user | active |

> **設計意図**: Step 1 で先に Flux を suspend してから Step 2-6 を実施することで、検証中の試行錯誤（`helm uninstall` → values 修正 → `helm install` 等）が GitOps と競合しない。Step 7 で Flux に adopt させる際、すでに正常動作している release が Helm 管理外から GitOps 管理に乗り換える形になる。

## Verification checklist

各 Open Question について、以下のコマンドが pass すれば解消とみなす。

### Q1: chaining + KPR + Gateway + CEC が EKS で動作

```bash
# Cilium 全体ステータス
cilium status                              # → "KubeProxyReplacement: True", "Gateway API: enabled"

# Cilium 公式の connectivity test（数分かかる）
cilium connectivity test --test '!check-log-errors'   # → all tests pass

# CiliumEnvoyConfig の動作確認（最小例）
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: smoke-test-cec
  namespace: kube-system
spec:
  services:
    - name: kubernetes
      namespace: default
  resources: []
EOF
kubectl get ciliumenvoyconfig smoke-test-cec -n kube-system -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}'   # → "True"
kubectl delete ciliumenvoyconfig smoke-test-cec -n kube-system
```

### Q2: KPR=true（full）

```bash
cilium status | grep KubeProxyReplacement   # → "True"
# Step 4-5 完了後
kubectl get ds -n kube-system kube-proxy   # → NotFound
```

### Q3: endpointRoutes.enabled=true

```bash
# 任意の node にログインして
kubectl debug node/<node-name> -it --image=ubuntu -- ip route | grep cilium   # → cilium endpoint route が見える

# Pod レベルでも
cilium endpoint list                       # 全 endpoint が "Ready"
```

### Q4: envoy.enabled=true（独立 DaemonSet）

```bash
kubectl get ds -n kube-system cilium-envoy   # → DaemonSet 存在、各 node で Running
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg envoy status   # → reachable
```

### Gateway API 動作確認

```bash
# 内部 Gateway 1 個 + HTTPRoute 1 個で疎通
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: smoke-test-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
EOF
kubectl get gateway smoke-test-gateway -n default -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'   # → "True"
kubectl delete gateway smoke-test-gateway -n default
```

### Hubble 動作確認

```bash
cilium hubble enable    # 既に enabled なら no-op
hubble observe --last 10   # 直近 10 件のフローが見える
```

すべての項目が pass したら Migration sequence Step 5（kube-proxy addon 削除）に進む。Step 6 で Q2 の `kube-proxy NotFound` を再確認する。

## Rollback strategy

Migration sequence の各 step に対応した戻し方：

| 失敗フェーズ | 戻し方 |
|---|---|
| Step 3 (Cilium install 直後) | `helm uninstall cilium -n kube-system` → kube-proxy が引き続き動作、cluster は install 前の状態 |
| Step 4 (検証中に Open Question が pass しない) | values.yaml を調整 → `helm upgrade --install cilium ...` で再 apply。それでも動かなければ Step 3 と同じく uninstall |
| Step 5 (kube-proxy 削除後に問題発生) | terragrunt で `kube-proxy` addon を再追加 → terragrunt apply → kube-proxy 復活 |
| Step 7 (Flux 管理移管後に drift) | `flux suspend kustomization flux-system -n flux-system` → 手で修正 → `flux resume`。values の問題なら main へ修正 PR |

すべてのフェーズで **production にアプリ未投入のため業務影響なし**。失敗時は安全に戻せる。

## Future Specs（明示的に記録）

本 spec のスコープ外で、別 spec として追跡する：

- **Plan 4-x: Hubble UI 公開 + 認証ゲート連動**: Hubble UI を Grafana と並びで公開、oauth2-proxy or ALB OIDC で認証ゲート設置
- **monorepo K8s 移行**: HTTPRoute + CiliumEnvoyConfig + JWT filter で Pattern B-Full を本格運用
- **Cluster Mesh / Egress Gateway**: 必要発生時
- **EKS CNI 戦略見直し**（ロードマップ spec から継承）: chaining → ENI mode 移行検討
- **`endpointRoutes.enabled = false` 検証**: 本 spec の検証で `true` が機能すれば不要。問題発生時に再評価
- **`make hydrate-index` の env-non-specific path 完全廃止**: Phase 3 で全 component の namespace を env 配下に移行した時点で実施

## References

- ロードマップ spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- Plan 1a (Flux bootstrap): `docs/superpowers/plans/2026-05-02-eks-production-flux-bootstrap.md`（merged in PR #255）
- aws-eks-production spec: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- aws-eks-production plan: `docs/superpowers/plans/2026-05-01-aws-eks-production.md`
- monorepo authentication design: `panicboat/monorepo` の `docs/分散システム設計/AUTHENTICATION.md`
- AWS blog: "Getting started with Cilium service mesh on Amazon EKS" (`https://aws.amazon.com/jp/blogs/opensource/getting-started-with-cilium-service-mesh-on-amazon-eks/`)
- Cilium blog: "Installing Cilium on EKS in Overlay(BYOCNI) and CNI Chaining Mode" (2025-07-08, `https://cilium.io/blog/2025/07/08/byonci-overlay-install/`)
