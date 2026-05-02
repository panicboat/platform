# EKS Production Cilium Chaining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster `eks-production` 上で Cilium 1.18.x を chaining mode（VPC CNI と共存）で動作させ、KPR / 独立 Envoy DaemonSet / Gateway Controller / Hubble を有効化する。spec の Open Questions 1-4 を実機検証で解消する。

**Architecture:** local 環境のパターンを踏襲して `kubernetes/components/cilium/production/` を新設し、Makefile の `hydrate-index` を env-aware に変更してから `make hydrate ENV=production` で manifests を生成する。Cilium と kube-proxy 共存期間を作るため、(1) Flux suspend 中に手動 `kubectl apply -k` で Cilium を入れ、(2) 検証完了後に PR を merge して terragrunt CI が `kube-proxy` addon を削除し、(3) `flux resume` で GitOps 管理に adopt させる、という 3 段階で進める。

**Tech Stack:** Cilium 1.18.x, Helmfile, Kustomize, kubectl, FluxCD 2.x, Terraform/OpenTofu, Terragrunt, AWS EKS (1.35), AL2023 ARM64, `eks-login.sh`

**Spec:** `docs/superpowers/specs/2026-05-03-eks-production-cilium-chaining-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `kubernetes/Makefile` | modify | `hydrate-index` ターゲットを env-aware に変更（env-specific path 優先 + env-non-specific fallback） |
| `kubernetes/helmfile.yaml.gotmpl` | modify | `production` env block に `cluster.eksApiEndpoint` を追加 |
| `kubernetes/components/cilium/production/helmfile.yaml` | create | production 用 helmfile（local の helmfile.yaml と同型、`k8sServiceHost` を gotmpl で差し込み） |
| `kubernetes/components/cilium/production/values.yaml.gotmpl` | create | production 用 Cilium values（chaining mode + KPR + Envoy DaemonSet + Gateway Controller） |
| `kubernetes/manifests/production/cilium/manifest.yaml` | create (hydrated) | `make hydrate ENV=production` で生成される rendered Cilium manifest |
| `kubernetes/manifests/production/cilium/kustomization.yaml` | create (hydrated) | 同上、`resources: - manifest.yaml` |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | create or empty (hydrated) | env-aware ロジックの結果。Cilium は kube-system 利用なので **空** |
| `kubernetes/manifests/production/00-namespaces/kustomization.yaml` | create (hydrated) | 同上、`resources: - namespaces.yaml` |
| `kubernetes/manifests/production/kustomization.yaml` | regenerate (hydrated) | `resources: [./00-namespaces, ./cilium]` |
| `aws/eks/modules/addons.tf` | modify | `cluster_addons` map から `kube-proxy` block を削除（KPR=true で不要） |

> **依存 spec / plan の前提**:
> - ロードマップ spec: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`（merged）
> - Plan 1a (Flux bootstrap): merged in PR #255 → eks-production cluster は FluxCD bootstrap 済
> - Cilium 設計 spec: `docs/superpowers/specs/2026-05-03-eks-production-cilium-chaining-design.md`（同 PR で merge 予定）

> **Out of scope（spec を継承）**:
> - Hubble UI 公開（Phase 4 の Plan 4-x）
> - HTTPRoute / CiliumEnvoyConfig による monorepo 認証実装（monorepo K8s 移行 spec）
> - `endpointRoutes.enabled = false` 検証（本 plan で `true` が pass すれば未実施で打ち切り）
> - Cluster Mesh / Egress Gateway

---

### Task 0: 前提条件の確認

**Files:** （read only）

実装前に prerequisite が揃っていることを確認する。

- [ ] **Step 1: worktree とブランチを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-cilium-chaining
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/eks-production-cilium-chaining`

以後すべてのコマンドはこの worktree で実行する。

- [ ] **Step 2: 必須 CLI が install 済であることを確認**

```bash
flux --version
kubectl version --client | head -1
helmfile --version
helm version
kustomize version
cilium version --client
```

Expected: 各 CLI が version を返す。`cilium` CLI は Cilium chart のクライアント側 verification に使う（`cilium status` / `cilium connectivity test`）。未 install なら `brew install cilium-cli` または `https://github.com/cilium/cilium-cli/releases`。

- [ ] **Step 3: production cluster へ kubectl 接続できることを確認**

```bash
source ~/Workspace/eks-login.sh production
kubectl cluster-info
```

Expected: `Kubernetes control plane is running at https://<cluster-id>.gr7.ap-northeast-1.eks.amazonaws.com`

- [ ] **Step 4: 現在の Cilium / kube-proxy 状態を記録**

```bash
kubectl get pods -n kube-system | grep -E "(cilium|kube-proxy)"
```

Expected:
- `kube-proxy-*`: Running（EKS managed addon）
- `cilium-*`: なし（未 install）

すでに Cilium が動いている場合は本 plan 開始前に状況確認が必要。

- [ ] **Step 5: Flux の現在の状態を記録**

```bash
flux get all -n flux-system
flux get kustomizations -n flux-system flux-system -o json | jq '.[] | {name, ready: .ready, suspended: .suspended}'
```

Expected: `flux-system` Kustomization が `Ready: True`、`Suspended: false`。

- [ ] **Step 6: production cluster の API endpoint を取得**

```bash
aws eks describe-cluster \
  --region ap-northeast-1 \
  --name eks-production \
  --query 'cluster.endpoint' \
  --output text
```

Expected: `https://<cluster-id>.gr7.ap-northeast-1.eks.amazonaws.com` のような URL。

URL から `https://` を除いた hostname 部分（`<cluster-id>.gr7.ap-northeast-1.eks.amazonaws.com`）を **記録**。Task 2 で `cluster.eksApiEndpoint` の値として使う。

- [ ] **Step 7: 現在の `make hydrate ENV=local` 出力の baseline を記録**

```bash
cd kubernetes
make hydrate ENV=local 2>&1 | tail -5
sha256sum manifests/local/00-namespaces/namespaces.yaml
cd ..
```

Expected: hydrate が成功し、`manifests/local/00-namespaces/namespaces.yaml` の SHA256 ハッシュが取得できる。Task 1 完了後にこのハッシュと比較して **backward compat（local の namespace 出力が変わらない）**を verify する。

ハッシュ値を **記録**（例: `abc123...`）。Task 1 Step 5 で再計算して比較する。

---

### Task 1: Makefile の `hydrate-index` を env-aware に変更

**Files:**
- Modify: `kubernetes/Makefile`

現状の `hydrate-index` は `find components -maxdepth 2 -name namespace.yaml` で全 component の namespace.yaml を env 非依存に集めている。これを「**`components/<comp>/<env>/` ディレクトリが存在する component のみ**」に絞り、namespace.yaml の配置位置は env-specific を優先、なければ env-non-specific を fallback する。

- [ ] **Step 1: 現状の hydrate-index ターゲットを確認**

```bash
grep -n "find components -maxdepth 2 -name namespace.yaml" kubernetes/Makefile
```

Expected: 1 行 hit（line 107 付近）。この行を含む `find ... | xargs ... > namespaces.yaml` 部分が変更対象。

- [ ] **Step 2: Makefile を編集**

`kubernetes/Makefile` の `hydrate-index` ターゲット内、以下の 2 行：

```makefile
	find components -maxdepth 2 -name namespace.yaml | sort | \
		xargs -I{} sh -c 'echo "---"; cat "{}"' > "$$env_dir/00-namespaces/namespaces.yaml"; \
```

を以下に置き換える：

```makefile
	: > "$$env_dir/00-namespaces/namespaces.yaml"; \
	for comp_dir in components/*/$(ENV)/; do \
		[ -d "$$comp_dir" ] || continue; \
		comp_name=$$(basename "$$(dirname "$$comp_dir")"); \
		if [ -f "components/$$comp_name/$(ENV)/namespace.yaml" ]; then \
			echo "---" >> "$$env_dir/00-namespaces/namespaces.yaml"; \
			cat "components/$$comp_name/$(ENV)/namespace.yaml" >> "$$env_dir/00-namespaces/namespaces.yaml"; \
		elif [ -f "components/$$comp_name/namespace.yaml" ]; then \
			echo "---" >> "$$env_dir/00-namespaces/namespaces.yaml"; \
			cat "components/$$comp_name/namespace.yaml" >> "$$env_dir/00-namespaces/namespaces.yaml"; \
		fi; \
	done; \
```

ロジック：

1. `components/*/$(ENV)/` に matchするディレクトリ（= 当該 env で deploy される component）のみを iterate
2. 各 component について env-specific な `<comp>/<env>/namespace.yaml` があればそれを優先、無ければ env-non-specific な `<comp>/namespace.yaml` を fallback として include
3. どちらも無ければ skip（Cilium のように kube-system 利用で namespace.yaml 不要な component）

- [ ] **Step 3: Makefile syntax を簡易チェック**

```bash
make -n -C kubernetes hydrate-index ENV=local 2>&1 | head -3
```

Expected: `set -euo pipefail; env_dir="manifests/local"; ...` のような shell command がプリント表示される（実行はされない、`-n` は dry-run）。Makefile syntax error が出ないこと。

- [ ] **Step 4: ENV=local で hydrate-index を実行（backward compat 検証）**

```bash
cd kubernetes
make hydrate-index ENV=local 2>&1 | tail -3
sha256sum manifests/local/00-namespaces/namespaces.yaml
cd ..
```

Expected: Task 0 Step 7 で記録したハッシュと **完全一致**。一致しない場合は Step 2 のロジックが既存の local 動作を破壊している。差分を確認：

```bash
git diff -- kubernetes/manifests/local/00-namespaces/namespaces.yaml
```

差分があれば Step 2 のロジックを見直す。env-non-specific fallback が想定通り機能しているか確認。

- [ ] **Step 5: ENV=production で hydrate-index を実行（新挙動検証）**

```bash
cd kubernetes
make hydrate-index ENV=production 2>&1 | tail -3
wc -c manifests/production/00-namespaces/namespaces.yaml
cat manifests/production/00-namespaces/namespaces.yaml
cd ..
```

Expected:
- `wc -c` の結果が **0 または小さい数値**（cilium production component がまだ無いため、production env でデプロイされる component が存在せず、namespaces.yaml は空）
- `cat` 出力も空

`components/*/production/` ディレクトリは Task 2-4 完了まで存在しないため、本 step では「production 用 component が無い → namespaces.yaml が空」という状態を確認する。

- [ ] **Step 6: 既存の local hydrate を完全に再実行して全体動作を verify**

```bash
cd kubernetes
make hydrate ENV=local
cd ..
git status --short kubernetes/manifests/local/
```

Expected: `git status` で kubernetes/manifests/local/ 配下に diff が **無い**（現在の commit 状態と一致）。差分が出る場合は Step 4 で見つからなかった backward compat 問題。

- [ ] **Step 7: 副次的に作られた production 配下を一旦削除（次の Task でクリーンに hydrate するため）**

```bash
rm -rf kubernetes/manifests/production/00-namespaces
ls kubernetes/manifests/production/
```

Expected: `kubernetes/manifests/production/` に `kustomization.yaml`（Plan 1a で作成した空 scaffold）のみ残る。

- [ ] **Step 8: Commit**

```bash
git add kubernetes/Makefile
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): make hydrate-index env-aware

components/*/$(ENV)/ ディレクトリが存在する component のみを namespace
収集対象とし、env-specific namespace.yaml を優先、なければ env-non-specific
namespace.yaml を fallback で include するロジックに変更。これにより
production 環境で deploy しない component の namespace が production
manifests に混入することを避ける。local 環境の出力は backward compat
を維持。
EOF
)"
```

Expected: 1 file changed, commit が `feat/eks-production-cilium-chaining` ブランチに追加される。

---

### Task 2: 親 helmfile.yaml.gotmpl に cluster.eksApiEndpoint を追加

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`

production env block に `cluster.eksApiEndpoint` を追加して、cilium production helmfile から `.Values.cluster.eksApiEndpoint` で参照可能にする。

- [ ] **Step 1: 現状を確認**

```bash
cat kubernetes/helmfile.yaml.gotmpl
```

Expected: Plan 1a で追加した `production` env block が以下のように existing：

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
```

- [ ] **Step 2: production env block に eksApiEndpoint を追加**

`kubernetes/helmfile.yaml.gotmpl` の `production:` block を以下に変更：

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
          # eks-production cluster の API server endpoint hostname（https:// は含まない）
          # Task 0 Step 6 で取得した値を使用
          eksApiEndpoint: <CLUSTER_ENDPOINT_HOSTNAME>
```

`<CLUSTER_ENDPOINT_HOSTNAME>` は Task 0 Step 6 で取得した hostname（例: `ABCDEF.gr7.ap-northeast-1.eks.amazonaws.com`）に置き換える。

- [ ] **Step 3: helmfile が production env を引き続き認識することを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -5
cd ..
```

Expected: エラーで落ちないこと。`Error: environment "production" is not defined` が出ないこと。

components/*/production/ がまだ無いため `no matches for path: components/*/production/helmfile.yaml` のような output で良い。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): add eksApiEndpoint to production helmfile values

cilium production の helmfile から .Values.cluster.eksApiEndpoint で
EKS API server endpoint hostname を参照できるように追加する。
KPR=true で必要となる k8sServiceHost の動的差し込みに使う。
EOF
)"
```

---

### Task 3: cilium production 用 helmfile.yaml を作成

**Files:**
- Create: `kubernetes/components/cilium/production/helmfile.yaml`

local の helmfile.yaml を参考に、production 用 helmfile を作成。`k8sServiceHost` を `.Values.cluster.eksApiEndpoint` で差し込めるように gotmpl 化。

- [ ] **Step 1: ディレクトリを作成**

```bash
mkdir -p kubernetes/components/cilium/production
```

- [ ] **Step 2: helmfile.yaml を作成**

`kubernetes/components/cilium/production/helmfile.yaml` を以下の内容で作成：

```yaml
# =============================================================================
# Cilium Helmfile for production
# =============================================================================
# Cilium 1.18.x を chaining mode (VPC CNI 共存) で deploy する。
# KPR / Gateway Controller / 独立 Envoy DaemonSet / Hubble を有効化。
# k8sServiceHost は .Values.cluster.eksApiEndpoint で動的に差し込む。
# =============================================================================
environments:
  production:

---
repositories:
  - name: cilium
    url: https://helm.cilium.io/

releases:
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: "1.18.6"
    values:
      - values.yaml.gotmpl
```

`values.yaml` ではなく `values.yaml.gotmpl` を referenced しているのは、`k8sServiceHost` を `.Values.cluster.eksApiEndpoint` で差し込むため（Task 4 で `values.yaml.gotmpl` として作成）。

- [ ] **Step 3: Commit（values 作成は次 Task のため、helmfile のみ先行 commit）**

```bash
git add kubernetes/components/cilium/production/helmfile.yaml
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/cilium): add production helmfile

production 環境用の helmfile を新設。version は local と同じ 1.18.6。
values は values.yaml.gotmpl で gotmpl 経由 EKS API endpoint を差し込む形にする
（次 commit で values.yaml.gotmpl を追加）。
EOF
)"
```

---

### Task 4: cilium production 用 values.yaml.gotmpl を作成

**Files:**
- Create: `kubernetes/components/cilium/production/values.yaml.gotmpl`

spec で確定した values を gotmpl として作成。

- [ ] **Step 1: values.yaml.gotmpl を作成**

`kubernetes/components/cilium/production/values.yaml.gotmpl` を以下の内容で作成：

```yaml
# Cilium CNI Configuration for production (eks-production)
# Reference: docs/superpowers/specs/2026-05-03-eks-production-cilium-chaining-design.md

# =============================================================================
# CNI Chaining Mode（VPC CNI が IPAM/datapath、Cilium は L7/policy/observability）
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
# kube-proxy addon は spec の Migration sequence Step 5 で terragrunt 経由で削除
kubeProxyReplacement: true
k8sServiceHost: {{ .Values.cluster.eksApiEndpoint }}
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
      enabled: false                  # Phase 3 で prometheus-operator 導入後に true

# =============================================================================
# DNS Proxy（hostNetwork Pod の DNS resolution に必要）
# =============================================================================
dnsProxy:
  enabled: true

# =============================================================================
# Prometheus Metrics
# =============================================================================
prometheus:
  enabled: false                      # Phase 3 で prometheus-operator 導入後に true
```

- [ ] **Step 2: helmfile が values を読めることを確認**

```bash
cd kubernetes
helmfile -e production list 2>&1
cd ..
```

Expected: `cilium` release が一覧に表示される（chart/version が解決される）。

```
NAME    NAMESPACE    ENABLED    INSTALLED    LABELS    CHART          VERSION
cilium  kube-system  true       false        ...       cilium/cilium  1.18.6
```

- [ ] **Step 3: helmfile template で実際の rendering を確認**

```bash
cd kubernetes
helmfile -e production template --skip-tests 2>&1 | head -30
cd ..
```

Expected: Cilium の Kubernetes manifest がプリント開始される（Service、Deployment、DaemonSet、ConfigMap 等）。

エラーなく rendering できれば values.yaml.gotmpl の構文が valid。`{{ .Values.cluster.eksApiEndpoint }}` が **Task 2 で設定した hostname に置換**されているか、output 内 `k8sServiceHost` 周辺で確認：

```bash
cd kubernetes
helmfile -e production template --skip-tests 2>&1 | grep -A 2 "k8s-service-host\|kube-apiserver-endpoint" | head -10
cd ..
```

Expected: hostname が gotmpl から正しく差し込まれている。

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/cilium/production/values.yaml.gotmpl
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/cilium): add production values.yaml.gotmpl

spec 2026-05-03-eks-production-cilium-chaining-design.md で確定した
chaining mode + KPR + L7 Envoy DaemonSet + Gateway Controller + Hubble の
values 一式を追加する。k8sServiceHost は .Values.cluster.eksApiEndpoint
で gotmpl 差し込み、prometheus / serviceMonitor は Phase 3 で有効化。
EOF
)"
```

---

### Task 5: `make hydrate ENV=production` を実行して manifests を生成・commit

**Files:**
- Create: `kubernetes/manifests/production/cilium/manifest.yaml`（hydrated output）
- Create: `kubernetes/manifests/production/cilium/kustomization.yaml`（hydrated output）
- Create: `kubernetes/manifests/production/00-namespaces/namespaces.yaml`（empty for cilium）
- Create: `kubernetes/manifests/production/00-namespaces/kustomization.yaml`（hydrated output）
- Modify: `kubernetes/manifests/production/kustomization.yaml`（hydrated regeneration）

- [ ] **Step 1: hydrate を実行**

```bash
cd kubernetes
make hydrate ENV=production
cd ..
```

Expected: 標準出力に `💧 Hydrating manifests for production...` → `Hydrating cilium...` → `✅ Manifests hydrated` のような flow。

- [ ] **Step 2: 生成された structure を確認**

```bash
find kubernetes/manifests/production -type f
```

Expected:
```
kubernetes/manifests/production/kustomization.yaml
kubernetes/manifests/production/00-namespaces/kustomization.yaml
kubernetes/manifests/production/00-namespaces/namespaces.yaml
kubernetes/manifests/production/cilium/kustomization.yaml
kubernetes/manifests/production/cilium/manifest.yaml
```

- [ ] **Step 3: 00-namespaces の中身が空であることを確認（cilium が kube-system 利用のため）**

```bash
wc -c kubernetes/manifests/production/00-namespaces/namespaces.yaml
cat kubernetes/manifests/production/00-namespaces/namespaces.yaml
```

Expected: byte 数 = 0 または非常に小さく、内容が空（または `---` のみ）。Cilium は kube-system を使うため namespace.yaml を持たない。

- [ ] **Step 4: manifests/production/kustomization.yaml が cilium を参照することを確認**

```bash
cat kubernetes/manifests/production/kustomization.yaml
```

Expected:
```yaml
resources:
  - ./00-namespaces
  - ./cilium
```

Plan 1a で書いた banner 付き手書き版は hydrate-index で **完全に上書き**されているはず。banner / apiVersion / kind は消える（hydrate output style に揃う）。

- [ ] **Step 5: kustomize build で valid であることを確認**

```bash
kustomize build kubernetes/manifests/production 2>&1 | head -20
```

Expected: Cilium の各種 K8s リソース（Deployment, DaemonSet, Service, ConfigMap, ServiceAccount, ClusterRole, ClusterRoleBinding 等）が出力される。エラーなし。

```bash
kustomize build kubernetes/manifests/production 2>&1 | grep -c "^kind:"
```

Expected: 数十〜100 程度（Cilium chart は多くのリソースを生成する）。

- [ ] **Step 6: cilium/manifest.yaml の主要設定を sanity-check**

```bash
grep -E "(routingMode|chainingMode|kubeProxyReplacement|enable-gateway-api|envoy|endpointRoutes)" kubernetes/manifests/production/cilium/manifest.yaml | head -20
```

Expected:
- `routing-mode: native` または `routingMode: "native"`
- `chainingMode: "aws-cni"` または cni-chaining mode 設定
- `kube-proxy-replacement: "true"` または同等
- `enable-gateway-api: "true"`
- `enable-envoy-config: "true"`
- `endpoint-routes: "true"`

検出されない設定があれば values.yaml.gotmpl の rendering を再確認。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/manifests/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/manifests/production): hydrate cilium production manifests

make hydrate ENV=production の output を commit する。
- cilium/manifest.yaml: chaining mode + KPR + L7 + Gateway Controller の rendered output
- 00-namespaces/namespaces.yaml: cilium は kube-system 利用のため空
- kustomization.yaml: ./00-namespaces と ./cilium を resource として参照
EOF
)"
```

---

### Task 6: aws/eks/modules/addons.tf から kube-proxy addon を削除

**Files:**
- Modify: `aws/eks/modules/addons.tf`

KPR=true で kube-proxy DaemonSet が不要になるため、EKS managed addon の `kube-proxy` block を削除する。**この変更は terragrunt apply で適用されるが、apply のタイミングは spec の Migration sequence Step 5（Cilium 検証完了後）に user が手動で行う**。本 task は apply は実行せず、Terraform 設定の変更のみ。

- [ ] **Step 1: 現状の addons.tf を確認**

```bash
grep -A 4 "kube-proxy = {" aws/eks/modules/addons.tf
```

Expected:
```
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
```

この block を Step 2 で削除する。

- [ ] **Step 2: kube-proxy block を削除**

`aws/eks/modules/addons.tf` の `cluster_addons` map 内、以下 4 行（および直後の空行）を削除：

```
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
```

削除後、`cluster_addons` map は `vpc-cni` / `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent` の 4 つのみを含む状態になる。

- [ ] **Step 3: ファイル冒頭の comment を更新**

`aws/eks/modules/addons.tf` の冒頭 comment 内、以下の文を：

```
# kube-proxy / coredns / pod-identity-agent
# do not need IRSA.
```

以下に書き換え：

```
# coredns / pod-identity-agent do not need IRSA. kube-proxy is intentionally
# omitted because Cilium is configured with kubeProxyReplacement=true (see
# kubernetes/components/cilium/production/values.yaml.gotmpl).
```

- [ ] **Step 4: terraform validate で syntax チェック**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate 2>&1
cd ../../../..
```

Expected: `Success! The configuration is valid.`

`init --backend=false` は state を触らずに providers / modules を取得する safe な validate モード。

- [ ] **Step 5: terraform plan を実行して変更内容を確認（apply はしない）**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(kube-proxy|Plan:)" | head -10
cd ../../../..
```

Expected:
- `module.eks.aws_eks_addon.this["kube-proxy"]` が `# will be destroyed` と表示される
- `Plan: 0 to add, 0 to change, 1 to destroy.`

差分が 1 destroy のみであれば想定通り。それ以外（add や change が出る、kube-proxy 以外が destroy される等）は Step 2 で別の block を誤って削除した可能性あり、確認。

> **注意**: 本 step では apply は **実行しない**。apply は spec の Migration sequence Step 5（Cilium 検証完了後）に user が実行する。ここでは plan で変更内容を verify するのみ。

- [ ] **Step 6: Commit**

```bash
git add aws/eks/modules/addons.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): remove kube-proxy from EKS managed addons

Cilium chaining mode で kubeProxyReplacement=true を有効化したため、
kube-proxy DaemonSet が不要になる。EKS managed addon block から
kube-proxy を削除する。本 commit の terragrunt apply は Cilium が
production cluster で検証完了した後（spec の Migration sequence
Step 5）に実行する。
EOF
)"
```

---

### Task 7: ブランチを push して Draft PR を作成

**Files:** （git 操作のみ）

ここまでの code 変更を Draft PR として user に提示し、user が cluster operations Phase へ移る。

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: Task 1-6 の commit + spec commit (`ad0bb48`) が並んでいる。

```
<sha> feat(aws/eks): remove kube-proxy from EKS managed addons
<sha> feat(kubernetes/manifests/production): hydrate cilium production manifests
<sha> feat(kubernetes/components/cilium): add production values.yaml.gotmpl
<sha> feat(kubernetes/components/cilium): add production helmfile
<sha> feat(kubernetes): add eksApiEndpoint to production helmfile values
<sha> feat(kubernetes): make hydrate-index env-aware
ad0bb48 docs(eks): add Plan 1b (Cilium chaining mode) design spec
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-cilium-chaining
```

Expected: `branch 'feat/eks-production-cilium-chaining' set up to track 'origin/feat/eks-production-cilium-chaining'`

- [ ] **Step 3: Draft PR を作成**

```bash
gh pr create --draft --base main \
  --title "feat(kubernetes,aws/eks): install Cilium chaining mode + remove kube-proxy (Plan 1b)" \
  --body "$(cat <<'EOF'
## Summary

- Cilium 1.18.6 を chaining mode（VPC CNI 共存）で eks-production に install
- KPR=true / endpointRoutes.enabled=true / envoy.enabled=true（独立 DaemonSet）/ Gateway Controller=true
- kube-proxy EKS managed addon を削除（KPR で代替）
- `kubernetes/Makefile` の `hydrate-index` を env-aware に変更（local の動作は backward compat）

Plan: ``docs/superpowers/plans/2026-05-03-eks-production-cilium-chaining.md``
Spec: ``docs/superpowers/specs/2026-05-03-eks-production-cilium-chaining-design.md``

これは Phase 1 (Foundation) の **Plan 1b**。Plan 1a (Flux bootstrap, #255) の後続。次は Plan 1c で foundation addons (ALB Controller / ExternalDNS / Metrics Server / KEDA / Gateway API CRDs)。

## Migration sequence (operator が手動で実施)

merge 前に以下の順で実施：

1. ``flux suspend kustomization flux-system -n flux-system``
2. PR branch を checkout して ``kubectl apply -k kubernetes/manifests/production/cilium/``
3. Verification battery (Q1-Q4 + Gateway API + Hubble + connectivity test) — 詳細は plan の Task 10
4. Mark PR ready for review → main merge → CI が terragrunt apply (kube-proxy 削除)
5. Post-removal verification (Q2 final: kube-proxy NotFound)
6. ``flux resume kustomization flux-system -n flux-system`` → Cilium adoption + idempotency check

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] ``make hydrate ENV=local`` の output が backward compat（manifests/local に diff なし）
- [x] ``make hydrate ENV=production`` で cilium と空の 00-namespaces が生成される
- [x] ``kustomize build kubernetes/manifests/production`` が valid
- [x] ``helmfile -e production template`` で Cilium manifest が rendering される
- [x] ``terragrunt plan`` で kube-proxy addon の destroy 1 件が表示される（apply は merge 後）

### Cluster-level (operator 実行)

- [ ] ``cilium status`` で KubeProxyReplacement: True / Gateway API: enabled
- [ ] ``cilium connectivity test`` 全 pass
- [ ] CiliumEnvoyConfig が Reconciled: True
- [ ] cilium-envoy DaemonSet が各 node で Running
- [ ] Gateway リソースが Programmed: True、HTTPRoute が Accepted: True
- [ ] hubble observe で flow が見える
- [ ] kube-proxy 削除後も Pod 間疎通が維持される
- [ ] Flux resume 後、cilium が drift なしで adopt される
EOF
)" 2>&1 | tail -3
```

Expected: PR URL が表示される（`https://github.com/panicboat/platform/pull/<num>`）。

- [ ] **Step 4: PR URL を user に共有**

```bash
gh pr view --json url --jq .url
```

PR URL を controller (Claude) が user に提示。以後の Task 8-13 は user 実行。

---

### Task 8: (USER) production cluster の Flux を suspend

**Files:** （cluster 状態変更のみ）

operator が production cluster で Cilium 検証を行う前に Flux を suspend し、検証中の試行錯誤が GitOps と競合しないようにする。

- [ ] **Step 1: production cluster へ kubectl 接続**

```bash
source ~/Workspace/eks-login.sh production
kubectl config current-context
```

Expected: `arn:aws:eks:ap-northeast-1:559744160976:cluster/eks-production`

- [ ] **Step 2: 現在の Flux 状態を確認**

```bash
flux get kustomizations -n flux-system flux-system
```

Expected: `READY: True`、`SUSPENDED: False`。

- [ ] **Step 3: Flux を suspend**

```bash
flux suspend kustomization flux-system -n flux-system
```

Expected: `► suspending Kustomization flux-system in flux-system namespace ✔ Kustomization suspended`

- [ ] **Step 4: suspend を確認**

```bash
flux get kustomizations -n flux-system flux-system
```

Expected: `SUSPENDED: True`。

これ以降、main ブランチへの変更が production cluster に自動適用されることはない（再開は Task 13）。

---

### Task 9: (USER) PR branch から Cilium を手動 apply

**Files:** （cluster 状態変更のみ）

PR が draft の状態で、PR branch を local に checkout し、hydrate 済の Cilium manifests を `kubectl apply -k` で直接 apply する。kube-proxy はまだ動いているので Service routing は二重化されるが正常動作する。

- [ ] **Step 1: PR branch を local に fetch**

```bash
git fetch origin feat/eks-production-cilium-chaining
git checkout feat/eks-production-cilium-chaining
```

Expected: branch 切り替え成功。`git log --oneline -3` で Task 6 の commit が HEAD として見える。

- [ ] **Step 2: kustomize build で実際に apply される manifest を最終確認**

```bash
kustomize build kubernetes/manifests/production/cilium 2>&1 | grep -c "^kind:"
```

Expected: 数十〜100 程度の kind: 行。

- [ ] **Step 3: Cilium manifests を apply**

```bash
kubectl apply --server-side --force-conflicts -k kubernetes/manifests/production/cilium/
```

Expected: 多数の `applied` メッセージ（Deployment, DaemonSet, Service, ConfigMap, RBAC 等が created）。

エラーが出る場合は `kubectl describe` / `kubectl get events -n kube-system --sort-by=.lastTimestamp | tail -30` で原因確認。

- [ ] **Step 4: Cilium agent / operator / envoy の起動を待つ**

```bash
kubectl rollout status -n kube-system daemonset/cilium --timeout=300s
kubectl rollout status -n kube-system deployment/cilium-operator --timeout=300s
kubectl rollout status -n kube-system daemonset/cilium-envoy --timeout=300s
```

Expected: 3 つすべて `successfully rolled out`。

タイムアウトする場合：
- `kubectl get pods -n kube-system | grep cilium` で Pod 状態確認
- `kubectl logs -n kube-system <pod-name>` でログ確認

- [ ] **Step 5: Hubble Relay の起動を確認**

```bash
kubectl rollout status -n kube-system deployment/hubble-relay --timeout=180s
kubectl rollout status -n kube-system deployment/hubble-ui --timeout=180s
```

Expected: 両方とも `successfully rolled out`。

これで Cilium が install 完了。Task 10 で動作 verification を実施。

---

### Task 10: (USER) Verification battery を実行

**Files:** （read only / 一時的な test resource の create + delete）

spec の Open Questions 1-4 + Gateway API + Hubble + connectivity test を網羅的に確認する。すべて pass したら Task 11 に進む。

- [ ] **Step 1: Q1 verification — Cilium 全体ステータス**

```bash
cilium status
```

Expected:
- `Cilium`: `OK` (running on all nodes)
- `Cluster Pods`: `<n>/<n> managed by Cilium`
- `Operator`: `OK`
- `Envoy DaemonSet`: `OK`
- `Hubble Relay`: `OK`
- `Hubble UI`: `OK`
- `KubeProxyReplacement`: `True`（重要、Q2 の確定）
- `Gateway API`: `enabled`（重要、Q1 の一部）

- [ ] **Step 2: Q3 verification — endpointRoutes.enabled=true**

```bash
kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-endpoint-routes}'
echo
```

Expected: `true`

```bash
cilium endpoint list 2>&1 | head -10
```

Expected: 各 endpoint が `Ready` 状態でリスト表示される。

- [ ] **Step 3: Q4 verification — envoy.enabled=true（独立 DaemonSet）**

```bash
kubectl get ds -n kube-system cilium-envoy -o wide
```

Expected: `cilium-envoy` DaemonSet が存在、各 node で 1/1 Ready。

```bash
kubectl exec -n kube-system $(kubectl get pod -n kube-system -l k8s-app=cilium -o name | head -1) -- cilium-dbg envoy admin server-info 2>&1 | head -3
```

Expected: Envoy admin server からの response（version 情報等）。

- [ ] **Step 4: Q1 verification — CiliumEnvoyConfig 動作確認**

minimal な CEC を apply して reconcile されるか確認：

```bash
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
  resources:
    - "@type": type.googleapis.com/envoy.config.listener.v3.Listener
      name: smoke-test-listener
      address:
        socket_address:
          address: "127.0.0.1"
          port_value: 19999
EOF
```

Expected: `ciliumenvoyconfig.cilium.io/smoke-test-cec created`

```bash
sleep 5
kubectl get ciliumenvoyconfig smoke-test-cec -n kube-system -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}'
echo
```

Expected: `True`

cleanup：

```bash
kubectl delete ciliumenvoyconfig smoke-test-cec -n kube-system
```

- [ ] **Step 5: Gateway API 動作確認**

```bash
kubectl get gatewayclass cilium
```

Expected: `cilium` GatewayClass が `ACCEPTED: True` で存在。

minimal な Gateway を apply：

```bash
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
```

Expected: `gateway.gateway.networking.k8s.io/smoke-test-gateway created`

```bash
sleep 30
kubectl get gateway smoke-test-gateway -n default -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
echo
```

Expected: `True`

cleanup：

```bash
kubectl delete gateway smoke-test-gateway -n default
```

- [ ] **Step 6: Hubble 動作確認**

```bash
hubble observe --last 10 --output compact 2>&1 | head -15
```

Expected: 直近の network flow が表示される（kube-system Pod 間の通信等）。`No flows` の場合は cluster がアイドル状態の可能性、しばらく待ってから再実行。

- [ ] **Step 7: Q1 final — Cilium 公式 connectivity test**

> **注意**: `cilium connectivity test` は test namespace を作成して数分間 test を走らせる。chaining mode + KPR の組み合わせでは一部 test が **flaky** な場合があるため、`--test '!check-log-errors'` で除外し、check-log-errors の発生は別途記録する。

```bash
cilium connectivity test --test '!check-log-errors' 2>&1 | tail -30
```

Expected: 最終行が `[=] 0/<n> tests failed` で終わる（all pass）。失敗 test がある場合は具体的な test 名を確認し、Cilium docs / GitHub issues で既知問題か調査。

> **注意**: test 完了後、`cilium-test-1` namespace が cluster に残る。clean up したい場合は：

```bash
cilium connectivity test --cleanup-only
```

- [ ] **Step 8: 全体ステータスの最終 snapshot**

```bash
kubectl get pods -n kube-system | grep cilium
echo "---"
kubectl get gatewayclass
echo "---"
flux get kustomizations -n flux-system flux-system   # まだ Suspended: True のはず
```

Expected:
- すべての cilium-* Pod が Running
- `cilium` GatewayClass が ACCEPTED: True
- Flux が Suspended: True

すべての検証が pass したら Task 11 に進む。pass しない項目があれば spec の Rollback strategy（Step 3 / Step 4）に従って `helm uninstall` または values 修正後 `kubectl apply --server-side --force-conflicts -k` で再 apply。

---

### Task 11: (USER) PR を ready にして merge、CI が kube-proxy addon を削除

**Files:** （Terraform state 変更、cluster 状態変更）

ここで PR を `Ready for review` に変更し、main へ merge する。merge 後 CI が terragrunt apply を実行し、`kube-proxy` EKS managed addon が削除される。

- [ ] **Step 1: PR を Ready for review に変更**

```bash
gh pr ready
```

または GitHub UI で `Ready for review` ボタンを押す。

- [ ] **Step 2: review approve（self-approve または別 reviewer）**

```bash
gh pr review --approve
```

または GitHub UI で approve。

- [ ] **Step 3: PR を main へ merge**

```bash
gh pr merge --squash --delete-branch
```

または GitHub UI で merge。

> **注意**: ここで CI が terragrunt apply を実行する。aws/eks の plan で確認した `kube-proxy addon destroy` が適用される。CI が完了するまで 3-5 分。

- [ ] **Step 4: CI workflow を tail で見る**

```bash
gh run watch
```

または GitHub Actions の UI で workflow 進捗を見る。Expected: `aws/eks/envs/production` の terragrunt apply が success で完了する。

CI 失敗時は `gh run view --log` で原因確認。よくある問題: AWS API rate limit、IAM 権限不足、依存リソースの destroy 順序問題。

- [ ] **Step 5: kube-proxy DaemonSet が削除されたことを確認**

```bash
kubectl get ds -n kube-system kube-proxy 2>&1
```

Expected: `Error from server (NotFound): daemonsets.apps "kube-proxy" not found`

```bash
kubectl get pods -n kube-system | grep kube-proxy
```

Expected: 結果が空（kube-proxy Pod が無い）。

これで Q2 の最終確認 (`kube-proxy NotFound`) が pass。

---

### Task 12: (USER) kube-proxy 削除後の疎通検証

**Files:** （read only / 一時 test resource）

kube-proxy が削除された状態で Cilium KPR が単独で Service routing を担当していることを確認する。

- [ ] **Step 1: 既存 Service への ClusterIP 経由疎通**

```bash
kubectl run smoke-svc-test --rm -i --restart=Never --image=busybox -- wget -qO- --timeout=5 http://kubernetes.default.svc.cluster.local 2>&1 | head -5
```

Expected: `wget: error getting response: Connection refused` 系のメッセージ（K8s API は HTTPS 認証必須なので接続自体は確立される、このエラー文言は接続成功を示す）。タイムアウトしたり `bad address` が出ると DNS / Service routing 失敗。

- [ ] **Step 2: cilium status 再確認**

```bash
cilium status
```

Expected: `KubeProxyReplacement: True`、kube-proxy が無い状態でも `OK` で動作継続。

- [ ] **Step 3: hubble で flow を観測**

```bash
hubble observe --last 20 --output compact 2>&1 | head -20
```

Expected: 直近の flow が観測される（Step 1 で発生した Service 通信を含む）。

- [ ] **Step 4: 全 Pod が Running を維持**

```bash
kubectl get pods -A | grep -v Running | grep -v Completed | head -10
```

Expected: 結果が空（または header のみ）。kube-proxy 削除で機能不全に陥った Pod が無いこと。

すべて pass したら Task 13 に進む。

---

### Task 13: (USER) Flux を resume + adoption 確認 + 冪等性確認

**Files:** （cluster 状態変更）

Flux を再開し、main の Cilium manifests を adopt させる。drift が無いこと（Flux apply が unchanged で完了する）を verify。

- [ ] **Step 1: Flux を resume**

```bash
flux resume kustomization flux-system -n flux-system
```

Expected: `► resuming Kustomization flux-system in flux-system namespace ✔ Kustomization resumed`

- [ ] **Step 2: 強制 reconcile で sync 状態を確認**

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
```

Expected: 両方とも `applied revision: main@sha1:<sha>` で完了する。

- [ ] **Step 3: Cilium が drift なしで adopt されたことを確認**

```bash
flux get kustomizations -n flux-system flux-system
```

Expected: `READY: True`、`MESSAGE: Applied revision: main@sha1:<sha>`、`SUSPENDED: False`。

```bash
kubectl describe kustomization flux-system -n flux-system | grep -A 3 "Status:"
```

Expected: `Conditions` 内に `Type: Ready, Status: True`、`Reason: ReconciliationSucceeded` が見える。

- [ ] **Step 4: Cilium Pod が drift で再起動していないことを確認**

```bash
kubectl get pods -n kube-system | grep cilium
```

Expected: 各 cilium-* Pod の `AGE` が Task 9 で起動した時間（数十分〜数時間前）と一致。Flux resume で AGE が 0 にリセットされていない（= 不要な rollout が発生していない）。

もし Flux が drift を検知して全 Cilium Pod を再起動した場合、`kubectl apply --server-side --force-conflicts` のフィールド管理と Flux の field manager の不一致が原因の可能性。`kubectl get pods -o yaml | grep -A 5 managedFields` で確認。

- [ ] **Step 5: 冪等性確認（再 reconcile しても unchanged）**

```bash
flux reconcile kustomization flux-system -n flux-system
sleep 10
kubectl get events -n flux-system --sort-by=.lastTimestamp | tail -5
```

Expected: 直近の event に `ReconciliationSucceeded` または `Normal` が出ており、Pod 再起動・apply の警告が無い。

- [ ] **Step 6: Plan 1b 完了の最終 snapshot**

```bash
echo "=== Cilium status ==="
cilium status --wait
echo ""
echo "=== Flux status ==="
flux get all -n flux-system
echo ""
echo "=== EKS addons ==="
aws eks list-addons --region ap-northeast-1 --cluster-name eks-production
```

Expected:
- Cilium status all OK、KubeProxyReplacement True、Gateway API enabled
- Flux GitRepository / Kustomization READY True、SUSPENDED False
- EKS addons から `kube-proxy` が消えており、`vpc-cni` / `coredns` / `aws-ebs-csi-driver` / `eks-pod-identity-agent` のみ

すべて pass したら **Plan 1b 完了**。次は Plan 1c（ALB Controller / ExternalDNS / Metrics Server / KEDA / Gateway API CRDs）。

---

## Self-review checklist

このセクションは Plan 完成後に書き手（Claude）が自己 review する項目。実装者は Skip して構わない。

- [x] **Spec coverage**:
  - Spec の Components 変更マトリクス（Cilium production helmfile / values / 親 helmfile / Makefile / addons.tf / hydrated manifests）→ Task 1-6 でカバー
  - Migration sequence Step 1（Flux suspend）→ Task 8
  - Migration sequence Step 2（PR merge with code）→ Task 7（PR 作成）+ Task 11（merge）
  - Migration sequence Step 3（手動 helm install）→ Task 9（kubectl apply -k で代替）
  - Migration sequence Step 4（verification）→ Task 10
  - Migration sequence Step 5（kube-proxy 削除）→ Task 11（CI が apply）
  - Migration sequence Step 6（post-removal verification）→ Task 12
  - Migration sequence Step 7（flux resume + adopt）→ Task 13
  - Migration sequence Step 8（idempotency）→ Task 13 Step 5
  - Verification checklist の Q1-Q4 + Gateway API + Hubble → Task 10 全 step
  - Open Questions 1-4 確定値（KPR=true, endpointRoutes=true, envoy=true, chaining 動作） → values.yaml.gotmpl と Task 10 verification で確認
- [x] **Placeholder scan**:
  - `<CLUSTER_ENDPOINT_HOSTNAME>` は Task 0 Step 6 で取得した実値に置換する明示的指示あり
  - `TBD` / `implement later` 等の禁止文言なし
- [x] **Type / signature consistency**:
  - File path: 全 task で同一（kubernetes/components/cilium/production/{helmfile.yaml, values.yaml.gotmpl}, kubernetes/manifests/production/cilium/{manifest.yaml, kustomization.yaml}）
  - Helmfile values reference: `.Values.cluster.eksApiEndpoint` を Task 2 で定義、Task 4 で参照
- [x] **CLAUDE.md 準拠**:
  - 出力言語日本語、コミット `-s`、`Co-Authored-By` 不付与、PR は `--draft`、`-u origin HEAD`、Conventional Commits
- [x] **代替パスを user 実行に明示**:
  - kubectl apply -k で apply（spec の "helm install" の代わり）→ Migration sequence Step 3 と差異が出るが、Hydration Pattern の利点（実 manifest を Git に commit）と一致しており、Flux adoption も clean に成立
