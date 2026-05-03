# EKS Production Foundation Addons (alpha) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster `eks-production` に **Gateway API CRDs (v1.2.1 Standard channel)** + **Metrics Server (chart 3.13.0)** + **KEDA (chart 2.19.0)** を Flux GitOps 経由で導入する。Plan 1c-α として Phase 1 Foundation の AWS 非依存 3 コンポーネントを完了させる。

**Architecture:** `kubernetes/components/{gateway-api,metrics-server,keda}/production/` を新設し、`make hydrate ENV=production` で `manifests/production/` を再生成、1 PR にまとめて main へ merge する。Plan 1b と異なり Flux suspend は不要（既存 service routing への破壊的変更なし）、merge 後 Flux が自動で reconcile する。`kubernetes/README.md` の Production Operations セクションも更新して新コンポーネントの運用手順を反映する。

**Tech Stack:** Kubernetes 1.35, Cilium 1.18.6, Gateway API v1.2.1 (Standard channel), Metrics Server Helm chart 3.13.0, KEDA Helm chart 2.19.0, Helmfile, Kustomize, FluxCD 2.x, kubectl, AWS EKS, AL2023 ARM64

**Spec:** `docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `kubernetes/components/gateway-api/production/kustomization/kustomization.yaml` | create | Gateway API v1.2.1 Standard channel CRDs（upstream URL） |
| `kubernetes/components/metrics-server/production/helmfile.yaml` | create | Metrics Server Helm release（chart 3.13.0、namespace: kube-system） |
| `kubernetes/components/metrics-server/production/values.yaml` | create | `--kubelet-preferred-address-types=InternalIP` + resource requests |
| `kubernetes/components/keda/production/helmfile.yaml` | create | KEDA Helm release（chart 2.19.0、namespace: keda） |
| `kubernetes/components/keda/production/values.yaml` | create | KEDA values（chart デフォルト中心） |
| `kubernetes/components/keda/production/namespace.yaml` | create | `keda` namespace 定義（env-aware hydrate-index で拾う） |
| `kubernetes/manifests/production/gateway-api/manifest.yaml` | create (hydrated) | `make hydrate ENV=production` 出力 |
| `kubernetes/manifests/production/gateway-api/kustomization.yaml` | create (hydrated) | 同上、`resources: - manifest.yaml` |
| `kubernetes/manifests/production/metrics-server/manifest.yaml` | create (hydrated) | 同上 |
| `kubernetes/manifests/production/metrics-server/kustomization.yaml` | create (hydrated) | 同上 |
| `kubernetes/manifests/production/keda/manifest.yaml` | create (hydrated) | 同上 |
| `kubernetes/manifests/production/keda/kustomization.yaml` | create (hydrated) | 同上 |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | regenerated | env-aware hydrate-index で keda namespace が追加 |
| `kubernetes/manifests/production/kustomization.yaml` | regenerated | `[./00-namespaces, ./cilium, ./gateway-api, ./keda, ./metrics-server]` |
| `kubernetes/README.md` | modify | Production Operations セクションに新コンポーネントの運用手順を追加 |

> **依存 spec / plan の前提**:
> - ロードマップ spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`（merged）
> - Plan 1a (Flux bootstrap): merged in PR #255
> - Plan 1b (Cilium chaining): merged in PR #257
> - Plan 1b 学び反映: merged in PR #259
> - Plan 1c-α 設計 spec: `docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md`（同 PR で merge 予定）

> **Out of scope（spec を継承）**:
> - AWS Load Balancer Controller / ExternalDNS / IRSA / ACM 証明書（Plan 1c-β）
> - Gateway API Experimental channel
> - KEDA AWS scaler（SQS / EventBridge 等）の IRSA 設定
> - Hubble UI / Grafana の Gateway 経由公開（Phase 4）

---

### Task 0: 前提条件の確認

**Files:** （read only）

実装前に prerequisite が揃っていることを確認する。

- [ ] **Step 1: worktree とブランチを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-foundation-addons-alpha
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/eks-production-foundation-addons-alpha`

以後すべてのコマンドはこの worktree で実行する。

- [ ] **Step 2: 必須 CLI が install 済であることを確認**

```bash
flux --version
kubectl version --client | head -1
helmfile --version
helm version --short
kustomize version
```

Expected: 各 CLI が version を返す。

- [ ] **Step 3: 親 helmfile で production env が認識されることを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -5
cd ..
```

Expected: `cilium` release が一覧に出る（Plan 1b で追加した production cilium component が見える）。Error なし。

- [ ] **Step 4: Helm chart リポジトリの reachability を確認**

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts 2>&1 || true
helm repo update >/dev/null 2>&1
helm search repo metrics-server/metrics-server --version=3.13.0 --output=json | head -3
helm search repo kedacore/keda --version=2.19.0 --output=json | head -3
```

Expected: 各 chart の version 3.13.0 / 2.19.0 が見つかる（リポジトリ到達可能 + version 確定）。

- [ ] **Step 5: Plan 1b で hydrate された production manifests が存在することを確認**

```bash
ls kubernetes/manifests/production/
```

Expected:
```
00-namespaces/
cilium/
kustomization.yaml
```

これに新たに `gateway-api/`、`metrics-server/`、`keda/` が追加される。

---

### Task 1: gateway-api production component を作成

**Files:**
- Create: `kubernetes/components/gateway-api/production/kustomization/kustomization.yaml`

local の `kubernetes/components/gateway-api/local/kustomization/kustomization.yaml` と同型で、Gateway API v1.2.1 Standard channel の upstream install YAML を kustomize `resources` で参照する。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/components/gateway-api/production/kustomization
```

- [ ] **Step 2: kustomization.yaml を作成**

`kubernetes/components/gateway-api/production/kustomization/kustomization.yaml` を以下の内容で作成：

```yaml
# =============================================================================
# Gateway API CRDs Kustomization for production
# =============================================================================
# Installs the standard Gateway API CRDs from the upstream project.
# These CRDs are required by the Cilium Gateway Controller (gatewayAPI.enabled
# is true in kubernetes/components/cilium/production/values.yaml.gotmpl).
#
# Gateway API Version: v1.2.1
# https://gateway-api.sigs.k8s.io/
#
# Standard channel covers GatewayClass / Gateway / HTTPRoute / GRPCRoute /
# ReferenceGrant. Experimental channel (TCPRoute / TLSRoute / etc.) は
# 必要が出たタイミングで別 spec で評価する（Future Specs）。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

local 版との差分は banner コメントの「local」→「production」と production 固有の説明文（Cilium Gateway Controller の前提である旨）のみ。version pin は同じ v1.2.1。

- [ ] **Step 3: kustomize build でリソースが取得できることを確認**

```bash
kustomize build kubernetes/components/gateway-api/production/kustomization 2>&1 | head -30
```

Expected: GatewayClass / Gateway / HTTPRoute / GRPCRoute / ReferenceGrant の CRDs が rendering される（5 個程度）。

```bash
kustomize build kubernetes/components/gateway-api/production/kustomization 2>&1 | grep -c "^kind: CustomResourceDefinition"
```

Expected: `5` 程度（Standard channel が含む CRDs の数）。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/gateway-api/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/gateway-api): add production kustomization

Cilium Gateway Controller (gatewayAPI.enabled: true) の前提となる
Gateway API v1.2.1 Standard channel CRDs を upstream URL から
kustomize で取得する production 用 kustomization を追加する。
Version pin は local と同じ v1.2.1。
EOF
)"
```

Expected: 1 file changed, commit が `feat/eks-production-foundation-addons-alpha` ブランチに追加される。

---

### Task 2: metrics-server production component を作成

**Files:**
- Create: `kubernetes/components/metrics-server/production/helmfile.yaml`
- Create: `kubernetes/components/metrics-server/production/values.yaml`

EKS 用に `--kubelet-preferred-address-types=InternalIP` を arg として追加し、resource requests / limits を控えめに設定。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/components/metrics-server/production
```

- [ ] **Step 2: helmfile.yaml を作成**

`kubernetes/components/metrics-server/production/helmfile.yaml`:

```yaml
# =============================================================================
# Metrics Server Helmfile for production
# =============================================================================
# Provides resource metrics (CPU / memory) for HPA and `kubectl top`.
# Required by KEDA-generated HPAs as well.
# =============================================================================
environments:
  production:
---
repositories:
  - name: metrics-server
    url: https://kubernetes-sigs.github.io/metrics-server

releases:
  - name: metrics-server
    namespace: kube-system
    chart: metrics-server/metrics-server
    version: "3.13.0"
    values:
      - values.yaml
```

- [ ] **Step 3: values.yaml を作成**

`kubernetes/components/metrics-server/production/values.yaml`:

```yaml
# Metrics Server values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md

# =============================================================================
# Args
# =============================================================================
# EKS の kubelet は InternalIP で待ち受けるため、優先 address type に InternalIP
# を指定する。default の "InternalIP,ExternalIP,Hostname" でも動くが、
# InternalIP-only にすることで kubelet 接続が安定する。
args:
  - --kubelet-preferred-address-types=InternalIP

# =============================================================================
# Resources
# =============================================================================
resources:
  requests:
    cpu: 100m
    memory: 200Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# =============================================================================
# Replicas
# =============================================================================
# Phase 1 では single replica。HA 化は monorepo 投入時に再評価。
replicas: 1
```

- [ ] **Step 4: helmfile が release を認識することを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | grep -E "(NAME|metrics-server|cilium)" | head -5
cd ..
```

Expected: `cilium` と `metrics-server` の 2 release が一覧に表示される。

```
NAME            NAMESPACE     ENABLED  INSTALLED  ...  CHART                              VERSION
cilium          kube-system   true     true       ...  cilium/cilium                      1.18.6
metrics-server  kube-system   true     true       ...  metrics-server/metrics-server      3.13.0
```

- [ ] **Step 5: helmfile template でレンダリングを確認**

```bash
cd kubernetes
helmfile -e production --selector name=metrics-server template --skip-tests 2>&1 | head -20
helmfile -e production --selector name=metrics-server template --skip-tests 2>&1 | grep -c "^kind:"
cd ..
```

Expected: 1 つ目で Deployment / Service / SA / RBAC 等の YAML が出力。2 つ目で 10 程度の `kind:` カウント（Metrics Server の chart は 10 リソース前後）。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/metrics-server/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/metrics-server): add production helmfile + values

HPA の前提となる Metrics Server を chart version 3.13.0 で固定して
production 用 helmfile / values を追加する。EKS 用に
--kubelet-preferred-address-types=InternalIP を arg に指定し、
resource requests / limits は production 想定の控えめ値で設定。
EOF
)"
```

---

### Task 3: keda production component を作成

**Files:**
- Create: `kubernetes/components/keda/production/helmfile.yaml`
- Create: `kubernetes/components/keda/production/values.yaml`
- Create: `kubernetes/components/keda/production/namespace.yaml`

KEDA は新規 namespace `keda` を使うため、`namespace.yaml` を env-aware hydrate-index で拾わせる。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/components/keda/production
```

- [ ] **Step 2: namespace.yaml を作成**

`kubernetes/components/keda/production/namespace.yaml`:

```yaml
# =============================================================================
# KEDA Namespace
# =============================================================================
# This namespace contains:
#   - keda-operator (controller for ScaledObject / ScaledJob / TriggerAuthentication)
#   - keda-operator-metrics-apiserver (external metrics API server)
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: keda
  labels:
    app.kubernetes.io/name: keda
```

- [ ] **Step 3: helmfile.yaml を作成**

`kubernetes/components/keda/production/helmfile.yaml`:

```yaml
# =============================================================================
# KEDA Helmfile for production
# =============================================================================
# KEDA (Kubernetes Event-driven Autoscaling) installs ScaledObject / ScaledJob
# CRDs and provides external triggers (Prometheus / Cron / SQS / etc.) on top
# of native HPA. The chart includes the operator and metrics-apiserver.
# =============================================================================
environments:
  production:
---
repositories:
  - name: kedacore
    url: https://kedacore.github.io/charts

releases:
  - name: keda
    namespace: keda
    chart: kedacore/keda
    version: "2.19.0"
    values:
      - values.yaml
```

- [ ] **Step 4: values.yaml を作成**

`kubernetes/components/keda/production/values.yaml`:

```yaml
# KEDA values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md

# =============================================================================
# Resources / Replicas
# =============================================================================
# Phase 1 では chart デフォルトを採用。HA 化や resource tuning は
# monorepo の async worker 投入時に再評価する。
# AWS scaler (SQS / EventBridge / DynamoDB Streams) の IRSA 設定も
# 利用が顕在化したタイミングで別 spec で扱う。
```

- [ ] **Step 5: helmfile が release を認識することを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | grep -E "(NAME|cilium|metrics-server|keda)" | head -5
cd ..
```

Expected: `cilium` / `metrics-server` / `keda` の 3 release が一覧に表示される。

- [ ] **Step 6: helmfile template でレンダリングを確認**

```bash
cd kubernetes
helmfile -e production --selector name=keda template --skip-tests 2>&1 | grep -c "^kind:"
cd ..
```

Expected: 30 〜 50 程度の `kind:` カウント（KEDA chart は controller / metrics-apiserver / RBAC / CRDs 含めてリソース数が多い）。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/components/keda/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/keda): add production helmfile + values + namespace

Pod autoscaling foundation の event-driven trigger layer として KEDA を
chart version 2.19.0 で固定して production 用 component を追加する。
namespace は keda（chart デフォルト）で env-aware hydrate-index に
namespace.yaml を拾わせる。values は chart default 中心、HA tuning や
AWS scaler IRSA は monorepo 投入時に再評価。
EOF
)"
```

---

### Task 4: `make hydrate ENV=production` を実行して manifests を生成・commit

**Files (auto-generated by hydrate):**
- Create: `kubernetes/manifests/production/gateway-api/manifest.yaml`
- Create: `kubernetes/manifests/production/gateway-api/kustomization.yaml`
- Create: `kubernetes/manifests/production/metrics-server/manifest.yaml`
- Create: `kubernetes/manifests/production/metrics-server/kustomization.yaml`
- Create: `kubernetes/manifests/production/keda/manifest.yaml`
- Create: `kubernetes/manifests/production/keda/kustomization.yaml`
- Modify: `kubernetes/manifests/production/00-namespaces/namespaces.yaml`（keda namespace 追加）
- Modify: `kubernetes/manifests/production/kustomization.yaml`（4 component 参照に拡張）

- [ ] **Step 1: hydrate を実行**

```bash
cd kubernetes
make hydrate ENV=production
cd ..
```

Expected: `💧 Hydrating manifests for production...` → `Hydrating cilium...` `Hydrating gateway-api...` `Hydrating keda...` `Hydrating metrics-server...` → `✅ Manifests hydrated`

- [ ] **Step 2: 生成された structure を確認**

```bash
find kubernetes/manifests/production -maxdepth 2 -type d | sort
```

Expected:
```
kubernetes/manifests/production
kubernetes/manifests/production/00-namespaces
kubernetes/manifests/production/cilium
kubernetes/manifests/production/gateway-api
kubernetes/manifests/production/keda
kubernetes/manifests/production/metrics-server
```

- [ ] **Step 3: 00-namespaces に keda namespace が追加されたことを確認**

```bash
cat kubernetes/manifests/production/00-namespaces/namespaces.yaml
```

Expected: `keda` namespace の YAML が含まれる（cilium は kube-system 利用なので namespace.yaml なし、keda のみ）。具体的には：

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: keda
  labels:
    app.kubernetes.io/name: keda
```

- [ ] **Step 4: top-level kustomization.yaml が 4 component を参照することを確認**

```bash
cat kubernetes/manifests/production/kustomization.yaml
```

Expected:
```yaml
resources:
  - ./00-namespaces
  - ./cilium
  - ./gateway-api
  - ./keda
  - ./metrics-server
```

- [ ] **Step 5: kustomize build で全体が valid であることを確認**

```bash
kustomize build kubernetes/manifests/production 2>&1 | grep -c "^kind:"
```

Expected: 80 〜 130 程度（Cilium 41 + Gateway API CRDs 5 + Metrics Server ~10 + KEDA 30〜50 + Namespace 1）。エラーなし。

- [ ] **Step 6: 各 manifest の主要設定を sanity-check**

```bash
echo "=== Gateway API CRDs ==="
grep -E "kind: CustomResourceDefinition" kubernetes/manifests/production/gateway-api/manifest.yaml | head -10
echo ""
echo "=== Metrics Server args ==="
grep -A 3 "args:" kubernetes/manifests/production/metrics-server/manifest.yaml | head -10
echo ""
echo "=== KEDA operator deployment ==="
grep -E "(kind: Deployment|name: keda-operator)" kubernetes/manifests/production/keda/manifest.yaml | head -5
```

Expected:
- Gateway API: GatewayClass / Gateway / HTTPRoute / GRPCRoute / ReferenceGrant の CRDs
- Metrics Server: `--kubelet-preferred-address-types=InternalIP` が args 内に存在
- KEDA: `keda-operator` Deployment が存在

- [ ] **Step 7: Commit**

```bash
git add kubernetes/manifests/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/manifests/production): hydrate gateway-api + metrics-server + keda

make hydrate ENV=production の output を commit する。
- gateway-api/manifest.yaml: Gateway API v1.2.1 Standard channel CRDs
- metrics-server/manifest.yaml: chart 3.13.0 の rendered output
- keda/manifest.yaml: chart 2.19.0 の rendered output
- 00-namespaces/namespaces.yaml: keda namespace 追加
- kustomization.yaml: cilium / gateway-api / keda / metrics-server を resources として参照
EOF
)"
```

---

### Task 5: kubernetes/README.md の Production Operations セクションを更新

**Files:**
- Modify: `kubernetes/README.md`

Plan 1c-α の 3 コンポーネントを Production Operations セクションに反映する。

- [ ] **Step 1: 現状の README 構成を確認**

```bash
grep -n "^### " kubernetes/README.md | head -20
```

Expected: `## Production Operations` 以下の subsections（Cluster overview / Initial Bootstrap / Daily Operations / Cilium-specific operations / Troubleshooting / GitOps 原則）が見える。

- [ ] **Step 2: Cluster overview セクションを更新**

`kubernetes/README.md` の `### Cluster overview (post Plan 1b)` セクションを以下に書き換える（行を追加する形）：

`### Cluster overview (post Plan 1b)` のセクションタイトルを `### Cluster overview (post Plan 1c-α)` に変更し、既存のテーブルの下に以下の追加表を append：

````markdown
加えて Plan 1c-α で以下の foundation addons を導入：

| Addon | Namespace | 役割 |
|---|---|---|
| Gateway API CRDs | (cluster-scoped) | Cilium Gateway Controller の前提（Standard channel v1.2.1） |
| Metrics Server | `kube-system` | Pod の resource metrics を公開、HPA / KEDA-generated HPA の前提 |
| KEDA | `keda` | Event-driven autoscaling layer（HPA を内部生成） |
````

- [ ] **Step 3: Cilium-specific operations の直後に Foundation addon operations セクションを追加**

`### Cilium-specific operations` セクションの直後（次の `### Troubleshooting` の前）に、以下の新セクションを追加：

````markdown
### Foundation addon operations

```bash
# Gateway API（Cilium Gateway Controller）
kubectl get gatewayclass cilium                          # Programmed: True
kubectl get gateway -A                                   # cluster 内の Gateway 一覧
kubectl get httproute -A                                 # HTTPRoute 一覧

# Metrics Server
kubectl top nodes                                        # node の CPU/Memory
kubectl top pods -A | head                               # pod の CPU/Memory
kubectl logs -n kube-system deploy/metrics-server --tail=20

# KEDA
kubectl get scaledobject -A                              # ScaledObject 一覧
kubectl get hpa -A | grep keda-hpa                       # KEDA-generated HPA
kubectl logs -n keda deploy/keda-operator --tail=20
```
````

- [ ] **Step 4: Troubleshooting テーブルに行を追加**

`### Troubleshooting` テーブルの末尾（既存の Plan 1b 学び 4 行の後）に以下の行を追加：

````markdown
| `kubectl top` が `Metrics API not available` を返す | metrics-server が未 Ready or kubelet certs / preferred address types の不一致。`kubectl logs -n kube-system deploy/metrics-server` で確認 |
| `GatewayClass cilium` が `Programmed: False` | Cilium operator が CRDs を picking up していない。`kubectl logs -n kube-system deploy/cilium-operator` で確認、Cilium pod の rolling restart が必要なケースあり |
| KEDA `ScaledObject` が `Ready: False` | trigger 設定誤り or RBAC error。`kubectl describe scaledobject <name> -n <ns>` で詳細を確認 |
````

- [ ] **Step 5: README の整合性確認**

```bash
grep -c "^##" kubernetes/README.md
```

Expected: section count が 9 個以上を維持（Plan 1a の 9 + 新規ゼロ、見出し追加なし、subsection 追加のみのため）。

```bash
grep -c "^### " kubernetes/README.md
```

Expected: subsection count が増えている（既存 + Foundation addon operations の 1 増分）。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "$(cat <<'EOF'
docs(kubernetes): reflect Plan 1c-α addons in README

Production Operations セクションに Plan 1c-α で導入する Foundation
addons (Gateway API CRDs / Metrics Server / KEDA) を反映する。
- Cluster overview に foundation addon の追加テーブル
- Foundation addon operations セクション新設（運用コマンド集）
- Troubleshooting に metrics-server / GatewayClass / KEDA ScaledObject
  の対処エントリ 3 件追加
EOF
)"
```

---

### Task 6: ブランチを push して Draft PR を作成

**Files:** （git 操作のみ）

ここまでの code 変更を Draft PR として user に提示する。

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected:
```
<sha> docs(kubernetes): reflect Plan 1c-α addons in README
<sha> feat(kubernetes/manifests/production): hydrate gateway-api + metrics-server + keda
<sha> feat(kubernetes/components/keda): add production helmfile + values + namespace
<sha> feat(kubernetes/components/metrics-server): add production helmfile + values
<sha> feat(kubernetes/components/gateway-api): add production kustomization
<sha> docs(eks): add Plan 1c-α (foundation addons alpha) design spec
```

合計 6 commits（spec 1 + components 3 + hydrate 1 + README 1）。

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-foundation-addons-alpha
```

Expected: `branch 'feat/eks-production-foundation-addons-alpha' set up to track 'origin/feat/eks-production-foundation-addons-alpha'`

- [ ] **Step 3: Draft PR を作成**

```bash
gh pr create --draft --base main \
  --title "feat(kubernetes): install gateway-api CRDs + metrics-server + KEDA (Plan 1c-α)" \
  --body "$(cat <<'EOF'
## Summary

Plan 1c-α: production EKS cluster `eks-production` に AWS 非依存の Foundation addons 3 件を Flux GitOps 経由で導入する。

### Code 変更（本 PR）

- `kubernetes/components/gateway-api/production/`: Gateway API v1.2.1 Standard channel CRDs を upstream URL から kustomize で取得
- `kubernetes/components/metrics-server/production/`: Helm chart 3.13.0、`--kubelet-preferred-address-types=InternalIP` 追加
- `kubernetes/components/keda/production/`: Helm chart 2.19.0、namespace `keda` 新設
- `kubernetes/manifests/production/`: hydrate output（4 component + 00-namespaces）
- `kubernetes/README.md`: Production Operations セクション更新（Cluster overview / Foundation addon operations / Troubleshooting）

### Documents

- Plan: ``docs/superpowers/plans/2026-05-03-eks-production-foundation-addons-alpha.md``
- Spec: ``docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-alpha-design.md``

これは Phase 1 (Foundation) の **Plan 1c-α**。次は Plan 1c-β で AWS 連携の foundation (ALB Controller / ExternalDNS / IRSA / ACM)。

## Migration sequence

Plan 1b と異なり既存 service routing への破壊的変更がないため、Flux suspend は不要。merge 後 Flux が自動で reconcile する。

1. Code 変更を 1 PR で main へ merge
2. CI: Hydrate Kubernetes (production) workflow が auto-run（既存）
3. Flux が main を pull → 差分（CRDs install + Helm release × 2 + namespace 追加）を apply
4. Verification battery を operator が手動実行

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] ``helmfile -e production list`` で cilium / metrics-server / keda の 3 release が表示される
- [x] ``helmfile -e production --selector name=metrics-server template`` が valid
- [x] ``helmfile -e production --selector name=keda template`` が valid
- [x] ``kustomize build kubernetes/components/gateway-api/production/kustomization`` で CRDs 5 個 rendering
- [x] ``kustomize build kubernetes/manifests/production`` が valid（80-130 resources）
- [x] ``kubernetes/manifests/production/00-namespaces/namespaces.yaml`` に keda namespace 追加
- [x] ``kubernetes/manifests/production/kustomization.yaml`` が `[./00-namespaces, ./cilium, ./gateway-api, ./keda, ./metrics-server]` を参照

### Cluster-level (operator 実行、merge 後)

- [ ] ``flux get kustomizations -n flux-system flux-system`` で `Applied revision: main@<sha>` が新 commit を反映
- [ ] ``kubectl get crd | grep gateway.networking.k8s.io`` で 5 個程度の CRDs
- [ ] ``kubectl get gatewayclass cilium`` で `Programmed: True`（Cilium operator が CRDs を picking up）
- [ ] ``kubectl top nodes`` および ``kubectl top pods -A`` が値を返す（Metrics Server 動作）
- [ ] ``kubectl get deployment -n keda`` で ``keda-operator`` / ``keda-operator-metrics-apiserver`` が Ready
- [ ] minimal Gateway を apply → Programmed: True
- [ ] minimal ScaledObject を apply → KEDA-managed HPA が auto-create される

## Out of scope (spec を継承)

- AWS Load Balancer Controller / ExternalDNS / IRSA / ACM（Plan 1c-β）
- Gateway API Experimental channel
- KEDA AWS scaler の IRSA 設定（monorepo の async worker 投入時）
- Hubble UI / Grafana の Gateway 経由公開（Phase 4）
EOF
)" 2>&1 | tail -3
```

Expected: PR URL が表示される（`https://github.com/panicboat/platform/pull/<num>`）。

- [ ] **Step 4: PR URL を user に共有**

```bash
gh pr view --json url --jq .url
```

PR URL を controller (Claude) が user に提示。以後の Task 7-8 は user 実行。

---

### Task 7: (USER) PR を ready にして merge、Flux 自動 reconcile を待つ

**Files:** （cluster 状態変更）

Plan 1b と異なり Flux suspend は不要。PR を ready / merge し、Flux が自動で apply するのを待つ。

- [ ] **Step 1: PR を Ready for review に変更**

```bash
gh pr ready
```

または GitHub UI で `Ready for review` ボタンを押す。

- [ ] **Step 2: review approve（self-approve または別 reviewer）**

```bash
gh pr review --approve
```

- [ ] **Step 3: PR を main へ merge**

```bash
gh pr merge --squash --delete-branch
```

merge 後、Hydrate Kubernetes (production) workflow が CI で auto-run する。

- [ ] **Step 4: CI workflow が完了することを確認**

```bash
gh run watch
```

または GitHub Actions UI で workflow 進捗を確認。Expected: 全 step success。

- [ ] **Step 5: production cluster 接続して Flux reconcile を確認**

```bash
source ~/.zshrc
eks-login production
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
flux get kustomizations -n flux-system flux-system
```

Expected: 最後の `flux get` で `READY: True`、`MESSAGE: Applied revision: main@<merged sha>`。

- [ ] **Step 6: 新リソースが apply されたことを確認**

```bash
kubectl get crd | grep gateway.networking.k8s.io
kubectl get deployment -n kube-system metrics-server
kubectl get deployment -n keda
```

Expected:
- Gateway API CRDs が 5 個程度 install 済
- metrics-server deployment が Ready 1/1
- keda deployment が `keda-operator` / `keda-operator-metrics-apiserver` の 2 個 Ready

reconcile に時間がかかる場合は `flux get all -A` で進捗確認。

---

### Task 8: (USER) Verification battery を実行

**Files:** （read only / 一時 test resource の create + delete）

各 component が期待通り動作することを確認する。

- [ ] **Step 1: Gateway API verification**

```bash
# CRDs install 確認
kubectl get crd 2>&1 | grep "gateway.networking.k8s.io" | wc -l
```

Expected: `5` 程度（GatewayClass / Gateway / HTTPRoute / GRPCRoute / ReferenceGrant）。

```bash
# Cilium が GatewayClass を register したことを確認
kubectl get gatewayclass cilium
kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
```

Expected: `gatewayclass.gateway.networking.k8s.io/cilium` が `ACCEPTED: True` で表示される。jsonpath 出力が `True`。

最初は Cilium operator が CRDs を picking up するのに 30 〜 60 秒かかる場合がある。`Not Found` の場合：

```bash
kubectl rollout restart -n kube-system deploy/cilium-operator
sleep 60
kubectl get gatewayclass cilium
```

```bash
# minimal Gateway を apply して動作確認
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
kubectl get gateway smoke-test-gateway -n default -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

Expected: `True`。

cleanup:

```bash
kubectl delete gateway smoke-test-gateway -n default
```

- [ ] **Step 2: Metrics Server verification**

```bash
kubectl get deployment -n kube-system metrics-server
```

Expected: `READY 1/1`。

```bash
kubectl top nodes
```

Expected: 各 node の CPU / Memory 値が表示される。最初の collection に 30 秒程度かかる場合あり。

```bash
kubectl top pods -A | head -10
```

Expected: 各 pod の CPU / Memory 値が表示される。

エラーが出る場合（例 `Metrics API not available`）：

```bash
kubectl logs -n kube-system deploy/metrics-server --tail=30
```

`x509: cannot validate certificate` 系のエラーが出る場合は `--kubelet-insecure-tls` の追加を要検討（spec の Future Specs ではないが、EKS の AMI / kubelet cert の挙動次第。本 plan の範囲では values.yaml 修正なしで動く想定）。

- [ ] **Step 3: KEDA verification**

```bash
kubectl get deployment -n keda
```

Expected:
```
NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
keda-operator                     1/1     1            1           ...
keda-operator-metrics-apiserver   1/1     1            1           ...
```

`keda-admission-webhooks` が含まれる場合もある（chart version による）。すべて 1/1 で Ready。

```bash
kubectl get crd 2>&1 | grep "keda.sh"
```

Expected:
```
clustertriggerauthentications.keda.sh
scaledjobs.keda.sh
scaledobjects.keda.sh
triggerauthentications.keda.sh
```

```bash
# Smoke test: minimal ScaledObject (CPU baseline)
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
kubectl get hpa -n keda-smoke-test
```

Expected: KEDA が auto-create した HPA が 1 件表示される（name は `keda-hpa-smoke-test-so`）。

```bash
kubectl get scaledobject -n keda-smoke-test smoke-test-so -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `True`。

cleanup:

```bash
kubectl delete namespace keda-smoke-test
```

- [ ] **Step 4: 全体 Flux 状態の最終確認**

```bash
flux get all -n flux-system | head -10
flux get kustomizations -A
```

Expected: GitRepository / Kustomization 全部 Ready: True、Suspended: False。

- [ ] **Step 5: 冪等性確認**

```bash
flux reconcile kustomization flux-system -n flux-system
sleep 10
kubectl get events -n flux-system --sort-by=.lastTimestamp | tail -5
```

Expected: 直近の event に `ReconciliationSucceeded` または `Normal` のみ。Pod 再起動 / apply 警告なし。

- [ ] **Step 6: 全 Pod が Running を維持していることを最終確認**

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Expected: 結果が空（または header のみ）。Plan 1c-α 投入で stuck した pod が無いこと。

すべて pass したら **Plan 1c-α 完了**。次は Plan 1c-β（ALB Controller / ExternalDNS / IRSA / ACM）の brainstorming に進む。

---

## Self-review checklist

このセクションは Plan 完成後に書き手（Claude）が自己 review する項目。実装者は Skip して構わない。

- [x] **Spec coverage**:
  - Spec の Goals 1-5 → Task 1-5（component 作成）+ Task 7-8（cluster-level verification）でカバー
  - Spec の Components 変更マトリクス → File Structure と Task 1-5 で 1 対 1 対応
  - Spec の Migration sequence → Task 6（PR）+ Task 7（user merge → Flux auto reconcile）
  - Spec の Verification checklist → Task 8 で全項目を網羅
  - Spec の Architecture decisions（継承） → Task 内で参照
  - Spec の Future Specs → Plan の Out of scope 注記で参照
- [x] **Placeholder scan**:
  - すべての Step に exact 値 / exact command 記載
  - `<sha>` のみ commit hash placeholder（実装時に確定）
  - `TBD` / `implement later` 等の禁止文言なし
- [x] **Type / signature consistency**:
  - File path: 全 task で同一
  - Helm chart version: Task 2 で 3.13.0 固定 / Task 3 で 2.19.0 固定 / Task 1 で v1.2.1 固定、Task 4 hydrate / Task 8 verification で同じ値を確認
- [x] **CLAUDE.md 準拠**:
  - 出力言語日本語、コミット `-s`、`Co-Authored-By` 不付与、PR は `--draft`、`-u origin HEAD`、Conventional Commits
- [x] **README 更新が含まれている**: Task 5 で kubernetes/README.md を Production Operations セクション 3 箇所修正
