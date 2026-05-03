# EKS Production Foundation Addons (alpha) Design

## Overview

Phase 1 Foundation の残り（Plan 1a / 1b に続く）のうち、**AWS 非依存の 3 コンポーネント** を production EKS cluster `eks-production` に導入する。Plan 1c-α として位置づけ、Plan 1c-β では AWS 連携のある残り 2 コンポーネント（AWS Load Balancer Controller、ExternalDNS）と IRSA / ACM 等を扱う。

本 spec のスコープ：

- **Gateway API CRDs**: 現状 Cilium が `gatewayAPI.enabled: true` で稼働しているが CRDs が未 install のため Gateway Controller が機能しない状態を解消
- **Metrics Server**: HPA の resource metrics provider
- **KEDA**: event-driven autoscaling foundation（Phase 5 で nginx の `ScaledObject` demo に使用）

ロードマップ spec（`2026-05-02-eks-production-platform-roadmap-design.md`）の **Decision 6**（Pod autoscaling foundation = Metrics Server + KEDA）と Phase 1 完了条件のうち、3 項目を本 spec で消化する。

## Goals

1. Gateway API v1.2.1 Standard channel の CRDs を production cluster に install する
2. Cilium Gateway Controller が GatewayClass `cilium` を register する状態を作る
3. Metrics Server を install し `kubectl top` が動作する状態を作る
4. KEDA controller / metrics-apiserver を install し `ScaledObject` リソースが reconcile される状態を作る
5. 上記 3 コンポーネントを Flux GitOps の管理下に置く

## Non-goals (Out of scope, with follow-up tracking)

- **AWS Load Balancer Controller** → Plan 1c-β
- **ExternalDNS** → Plan 1c-β
- **IRSA / ACM 証明書 / Route53 hosted zone 連携** → Plan 1c-β
- **実ワークロードでの HPA / ScaledObject 利用** → monorepo 移行 / Phase 5
- **Gateway API Experimental channel**（TCPRoute / TLSRoute / GRPCRoute experimental 機能） → Future Specs
- **KEDA AWS scaler の IRSA 設定**（SQS / EventBridge / DynamoDB Streams 等） → monorepo の async worker 投入時に別 spec
- **Hubble UI / Grafana の Gateway 経由公開** → Phase 4 spec

## Architecture decisions

ロードマップ spec の Decision を継承するのみ、本 spec で新規 architectural decision は発生しない。

| 継承元 | 内容 |
|---|---|
| Roadmap Decision 6 | Pod autoscaling foundation = Metrics Server + KEDA。KEDA は HPA を置き換えず HPA を内部生成する layer であり、Metrics Server は KEDA が作る HPA でも resource metrics 用に必要 |
| Roadmap Phase 1 完了条件 | "`kubectl top pods` が値を返す" "KEDA controller が起動し、`ScaledObject` リソースが作成可能" "Cilium Gateway Controller が `Gateway` リソースから cluster 内部 LB を立ち上げる（東西用、北南未使用）" |

## Component decisions

各コンポーネントの実装上の値を確定する。

### Gateway API CRDs

- **Channel**: **Standard**
  - Decision rationale: Pattern B-Full（HTTPRoute + CiliumEnvoyConfig による JWT 検証）は HTTPRoute のみで成立し、Standard channel に含まれる。Experimental の TCPRoute / TLSRoute / GRPCRoute / BackendTLSPolicy 等は本 spec の範囲では不要
  - Future Specs: 必要が出たら別 spec で Experimental に切り替え（Cilium Gateway Controller は Experimental も sustaining sup）
- **Version**: **v1.2.1**（local の `kubernetes/components/gateway-api/local/kustomization/` と同じ pin）
  - Renovate で local / production を同時 bump させる（環境差を作らない）
- **Install method**: upstream release URL を kustomize で参照（local と同型）
  - URL: `https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`

### Metrics Server

- **Helm chart**: `metrics-server/metrics-server`（Helm repo: `https://kubernetes-sigs.github.io/metrics-server`）
- **Version**: 最新 stable（v3.12.x 系を実装時点で固定、Renovate で追従）
- **Namespace**: `kube-system`
- **Args**: `--kubelet-preferred-address-types=InternalIP`（EKS の慣習。kubelet が node の InternalIP で待ち受けするため）
- **Replicas**: 1（軽量 component、HA は将来必要なら検討）
- **Resource requests**: 控えめに `cpu: 100m / memory: 200Mi`

### KEDA

- **Helm chart**: `kedacore/keda`（Helm repo: `https://kedacore.github.io/charts`）
- **Version**: 最新 stable（v2.16.x or v2.17.x 系を実装時点で固定、Renovate で追従）
- **Namespace**: `keda`（chart デフォルト）
  - 新規 namespace のため `kubernetes/components/keda/production/namespace.yaml` を別途用意し、env-aware hydrate-index に拾わせる
- **Components**: chart デフォルトで `keda-operator` + `keda-operator-metrics-apiserver` + 関連 RBAC / CRDs（ScaledObject / ScaledJob / TriggerAuthentication 等）
- **Resource requests**: chart デフォルト

## Components 変更マトリクス

| File / Resource | 種別 | 内容 |
|---|---|---|
| `kubernetes/components/gateway-api/production/kustomization/kustomization.yaml` | create | upstream Gateway API CRDs v1.2.1 standard-install.yaml を kustomize `resources` で参照（local と同型） |
| `kubernetes/components/metrics-server/production/helmfile.yaml` | create | Helm chart 参照、release in `kube-system` |
| `kubernetes/components/metrics-server/production/values.yaml` | create | `args` に `--kubelet-preferred-address-types=InternalIP` を追加、resource requests 設定 |
| `kubernetes/components/keda/production/helmfile.yaml` | create | Helm chart 参照、release in `keda` namespace |
| `kubernetes/components/keda/production/values.yaml` | create | デフォルト値中心 |
| `kubernetes/components/keda/production/namespace.yaml` | create | `keda` namespace 定義（env-aware hydrate-index で拾わせる） |
| `kubernetes/manifests/production/gateway-api/` | hydrated | `make hydrate ENV=production` 出力 |
| `kubernetes/manifests/production/metrics-server/` | hydrated | 同上 |
| `kubernetes/manifests/production/keda/` | hydrated | 同上 |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | regenerated | env-aware logic で keda の namespace.yaml が追加される |
| `kubernetes/manifests/production/kustomization.yaml` | regenerated | `[./00-namespaces, ./cilium, ./gateway-api, ./keda, ./metrics-server]` |

## Migration sequence

Plan 1b（Cilium 移行）と異なり、本 spec のコンポーネントは **既存 service routing に影響しない純粋な追加** のみ。Flux suspend は不要、PR merge → Flux 自動 reconcile で完結する。

| Step | 内容 | 実行者 | Flux 状態 |
|---|---|---|---|
| 1 | `kubernetes/components/{gateway-api,metrics-server,keda}/production/` 一式 + `make hydrate ENV=production` 結果（`manifests/production/{gateway-api,metrics-server,keda}/` + 更新された `00-namespaces` + 更新された `kustomization.yaml`）を 1 PR としてまとめて main へ merge | controller (subagent) + user | active |
| 2 | merge 後 Flux が main を取得 → 差分（CRD install + Helm release × 2 + namespace 追加）を apply | Flux 自動 | active |
| 3 | Verification checklist 完走（後述） | user | active |

> 設計意図：Plan 1b の kube-proxy 削除のような「既存 routing への破壊的変更」がないため、Flux 経由の通常 reconcile で安全に展開できる。manual apply / Flux suspend は不要。

## Verification checklist

各 Goal について、以下のコマンドが pass すれば達成とみなす。

### Gateway API CRDs

```bash
# CRDs install 確認
kubectl get crd 2>&1 | grep -E "gateway.networking.k8s.io" | wc -l
# 期待: 5 個程度（GatewayClass / Gateway / HTTPRoute / GRPCRoute / ReferenceGrant）

# Cilium Gateway Controller が register する GatewayClass 確認
kubectl get gatewayclass cilium
# 期待: ACCEPTED: True（Cilium operator が CRDs を picking up して register、30 秒程度かかる）

# 動作確認（minimal Gateway 1 個 apply）
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
sleep 30
kubectl get gateway smoke-test-gateway -n default -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
# 期待: True
kubectl delete gateway smoke-test-gateway -n default
```

### Metrics Server

```bash
kubectl get deployment -n kube-system metrics-server
# 期待: READY 1/1

# resource metrics の取得確認
kubectl top nodes
# 期待: 各 node の CPU / Memory 値が表示される
kubectl top pods -A | head -10
# 期待: 各 pod の CPU / Memory 値が表示される
```

### KEDA

```bash
kubectl get deployment -n keda
# 期待: keda-operator 1/1, keda-operator-metrics-apiserver 1/1

kubectl get crd 2>&1 | grep keda.sh
# 期待: ScaledObject / ScaledJob / TriggerAuthentication / ClusterTriggerAuthentication 等

# Smoke test: minimal ScaledObject（CPU baseline）
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: keda-smoke-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-target
  namespace: keda-smoke-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: smoke-target
  template:
    metadata:
      labels:
        app: smoke-target
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: 50m
            limits:
              cpu: 100m
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: smoke-test-so
  namespace: keda-smoke-test
spec:
  scaleTargetRef:
    name: smoke-target
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: cpu
      metadata:
        type: Utilization
        value: "50"
EOF
sleep 30
# KEDA が HPA を生成することを確認
kubectl get hpa -n keda-smoke-test
# 期待: keda-hpa-smoke-test-so（KEDA が auto-create）

kubectl get scaledobject -n keda-smoke-test smoke-test-so -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# 期待: True
kubectl delete namespace keda-smoke-test
```

### Flux

```bash
flux get kustomizations -n flux-system flux-system
# 期待: READY: True, MESSAGE: Applied revision: main@<sha>

flux get all -A | head -20
# 期待: 全 resource Ready
```

## Rollback strategy

PR merge 後に問題が発覚した場合：

| 失敗フェーズ | 戻し方 |
|---|---|
| Gateway API CRDs install で問題発生 | 通常は無害（純粋な API 拡張）。問題があれば revert PR + `kubectl delete -k <upstream-url>` で CRDs を削除（既存 Gateway/HTTPRoute がない前提） |
| Metrics Server で `kubectl top` が動かない | revert PR + `helm uninstall metrics-server -n kube-system`、values 修正後 re-apply。HPA を未利用なので業務影響なし |
| KEDA controller が起動しない | revert PR + `helm uninstall keda -n keda` + `kubectl delete namespace keda`、ScaledObject を未利用なので業務影響なし |
| Flux reconciliation が失敗 | `flux logs --kind=Kustomization` で原因確認、values / hydrated manifest を修正して main へ追加 commit |

すべてのフェーズで **production にアプリ未投入のため業務影響なし**。

## Future Specs（明示的に記録）

本 spec のスコープ外で、別 spec として追跡する：

- **Plan 1c-β**: AWS Load Balancer Controller + ExternalDNS + IRSA + ACM 証明書 + Route53 連携
- **Gateway API Experimental channel への切り替え**: TCPRoute / TLSRoute / GRPCRoute / BackendTLSPolicy 等が必要になったタイミング
- **KEDA AWS scaler の IRSA 設定**: monorepo の async worker（SQS / EventBridge consumer 等）投入時
- **Metrics Server HA 化**: production 規模が大きくなり single replica が SPOF になった時

## References

- ロードマップ spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`
- Plan 1a (Flux bootstrap): merged in PR #255
- Plan 1b spec (Cilium chaining): `docs/superpowers/specs/2026-05-03-eks-production-cilium-chaining-design.md`、merged in PR #257
- Plan 1b learnings: merged in PR #259
- Local Gateway API CRDs reference: `kubernetes/components/gateway-api/local/kustomization/kustomization.yaml`
- Cilium Gateway API documentation (1.18): `https://docs.cilium.io/en/v1.18/network/servicemesh/gateway-api/gateway-api/`
- Gateway API release v1.2.1: `https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.2.1`
- Metrics Server Helm chart: `https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server`
- KEDA Helm chart: `https://github.com/kedacore/charts`
