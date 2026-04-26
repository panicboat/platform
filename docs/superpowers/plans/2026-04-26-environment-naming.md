# Environment Naming Refactor (`k3d` → `local`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kubernetes コンポーネントの環境名を `k3d` → `local` にリネームし、`workflow-config.yaml` に `local` 環境を追加することで、CI の Kubernetes hydrate ジョブが起動するようにする。あわせて `develop` のリージョン整合、`staging` 残骸の削除、README の実体ズレ修正を行う。

**Architecture:** 単一 PR で一括リネーム。中間状態を作らないため Step 2（ディレクトリリネーム）と Step 3（ファイル内文字列置換）を 1 コミットにまとめる。`workflow-config.yaml` 更新、`develop` リージョン整合、`staging` 削除はそれぞれ別コミット。

**Tech Stack:** Bash, git (`mv`), GNU Make, helmfile, kustomize, GitHub Actions (workflow YAML), Terragrunt + OpenTofu, AWS IAM (Global)。

**Spec:** [`docs/superpowers/specs/2026-04-26-environment-naming-design.md`](../specs/2026-04-26-environment-naming-design.md)

**Prerequisites (local):**
- aqua（`.github/aqua.yaml`）で helmfile / kustomize が利用可能
- AWS 認証（develop / staging のロール assume 用）
- `gh` CLI が認証済み（PR 作成と `gh repo view` での外部リポ確認）

**Worktree:** `.claude/worktrees/refactor-environment-naming-local/`、ブランチ `refactor/environment-naming-local`

---

## File Structure

| 種別 | パス | 責務 |
|------|------|------|
| Rename | `kubernetes/clusters/k3d/` → `kubernetes/clusters/local/` | Flux ブートストラップディレクトリ |
| Rename | `kubernetes/components/<svc>/k3d/` → `<svc>/local/` (11 コンポーネント) | コンポーネント別 helmfile / kustomize 設定 |
| Rename | `kubernetes/manifests/k3d/` → `kubernetes/manifests/local/` | Hydrate 出力先 |
| Modify | `workflow-config.yaml` | `local` 環境追加、`staging` コメント削除 |
| Modify | `kubernetes/Makefile` | デフォルト ENV、ハードコードパス、help/コメント |
| Modify | `kubernetes/helmfile.yaml.gotmpl` | `environments:` 配下の env 名 |
| Modify | `kubernetes/components/<svc>/local/helmfile.yaml` × 9 | `environments: k3d:` → `local:`、ヘッダコメント |
| Modify | `kubernetes/components/<svc>/local/values.yaml`, `kustomization/*.yaml` | パス／env 名の `k3d` 参照（ツール名は維持） |
| Modify | `kubernetes/clusters/local/flux-system/gotk-sync.yaml` | `path:` 値、TODO コメント |
| Modify | `kubernetes/clusters/local/repositories/monorepo.yaml` | TODO コメント |
| Modify | `.github/workflows/reusable--kubernetes-{builder,hydrator}.yaml` | 説明文 `e.g., k3d` |
| Modify | `kubernetes/README.md` | k3d 参照を local に |
| Modify | `README.md`, `README-ja.md` | 環境表に local 行追加、ai-assistant 表記修正 |
| Regenerate | `kubernetes/manifests/local/**` | `make hydrate ENV=local` で再生成 |
| Modify | `aws/github-oidc-auth/envs/develop/env.hcl` | region `ap-northeast-1` → `us-east-1` |
| Modify | `aws/ai-assistant/envs/develop/env.hcl` | region `ap-northeast-1` → `us-east-1` |
| Delete | `aws/github-oidc-auth/envs/staging/` | ディレクトリ削除 |

---

## Task 1: 事前確認（コード変更なし）

外部依存と state 状況を確認し、後続 Task の方針を確定する。

**Files:** なし（調査のみ）

- [ ] **Step 1: `panicboat/deploy-actions/label-resolver` のソースを確認**

`workflow-config.yaml` に `local` 環境を追加する際、`aws_region`／`iam_role_plan`／`iam_role_apply` フィールドの欠落が許容されるかを判定する。

Run:
```bash
gh repo clone panicboat/deploy-actions /tmp/deploy-actions-check 2>/dev/null || true
ls /tmp/deploy-actions-check/label-resolver/
```

調査ポイント:
- `label-resolver` の入力スキーマで `environments[]` の各フィールドが必須かどうか
- 必須なら **案 b**（空文字フィールド）を採用、任意なら **案 a**（フィールド省略）を採用

調査結果を Task 3 で参照する。

- [ ] **Step 2: `aws/github-oidc-auth/envs/staging/` の state 確認**

過去に apply されていたかを確認し、残存リソースがあれば先に destroy する。

Run:
```bash
cd aws/github-oidc-auth/envs/staging && terragrunt plan
```

判定:
- `No changes` または「resource already exists」エラー → state 無し、Task 5 でディレクトリ削除のみで OK
- `N to add, 0 to change, 0 to destroy` → state は無いが apply されていない（リソース無し）、Task 5 でディレクトリ削除のみで OK
- `N to destroy` を含む → state あり実リソースあり、Task 5 の前に `terragrunt destroy` を要する

destroy が必要な場合、ユーザに確認を取ってから実行する。

- [ ] **Step 3: 現在の k3d 参照を完全列挙**

リネーム時の漏れを防ぐため、置換対象と非対象を明確化する。

Run:
```bash
git grep -nE 'k3d' -- ':!docs/superpowers/'
```

非対象（ツール名 k3d）として残す行を以下と照合:
- `kubernetes/Makefile`: `k3d cluster create/delete/list` などの CLI コマンド行、`CLUSTER_NAME ?= k8s-local`
- `.github/renovate.json`: Cilium description 内の `k3d serverlb` 記述
- `kubernetes/components/cilium/k3d/values.yaml` の `k8sServiceHost: k3d-k8s-local-server-0`（k3d CLI が生成するホスト名）

その他はすべて置換対象。

- [ ] **Step 4: 結果を作業メモに記録**

worktree のローカルに `docs/superpowers/plans/2026-04-26-environment-naming.notes.md`（git 追跡しない作業メモ）を作成し、Step 1〜3 の結果を保存。Task 1 はこれで完了。

```bash
cat > docs/superpowers/plans/2026-04-26-environment-naming.notes.md <<'EOF'
# Implementation Notes (not committed)
- label-resolver schema: <案 a or 案 b>
- staging state: <無し / 要 destroy>
- k3d references confirmed: <件数>
EOF
echo "/docs/superpowers/plans/2026-04-26-environment-naming.notes.md" >> .git/info/exclude
```

---

## Task 2: ディレクトリリネーム + ファイル内文字列置換（1 コミット）

`k3d` → `local` の名前変更を一括で実行し、git mv で履歴を保持しつつ単一コミットにする。

**Files:**
- Rename: `kubernetes/clusters/k3d/` → `kubernetes/clusters/local/`
- Rename: `kubernetes/components/{beyla,cilium,coredns,dashboard,fluent-bit,gateway-api,loki,opentelemetry,opentelemetry-collector,prometheus-operator,tempo}/k3d/` → `<svc>/local/`
- Rename: `kubernetes/manifests/k3d/` → `kubernetes/manifests/local/`
- Modify: `kubernetes/Makefile`
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/components/<svc>/local/helmfile.yaml` (9 ファイル: beyla, cilium, fluent-bit, loki, opentelemetry, opentelemetry-collector, prometheus-operator, tempo)
- Modify: `kubernetes/components/<svc>/local/values.yaml` および `kustomization/*.yaml` （ヘッダコメント・TODO タグ）
- Modify: `kubernetes/clusters/local/flux-system/gotk-sync.yaml`
- Modify: `kubernetes/clusters/local/repositories/monorepo.yaml`
- Modify: `.github/workflows/reusable--kubernetes-builder.yaml`
- Modify: `.github/workflows/reusable--kubernetes-hydrator.yaml`
- Modify: `kubernetes/README.md`
- Modify: `README.md`, `README-ja.md`
- Regenerate: `kubernetes/manifests/local/**`

- [ ] **Step 1: ディレクトリリネーム（git mv）**

Run:
```bash
git mv kubernetes/clusters/k3d kubernetes/clusters/local
git mv kubernetes/manifests/k3d kubernetes/manifests/local
for svc in beyla cilium coredns dashboard fluent-bit gateway-api loki opentelemetry opentelemetry-collector prometheus-operator tempo; do
  git mv "kubernetes/components/$svc/k3d" "kubernetes/components/$svc/local"
done
```

Expected:
- `git status` に `renamed: kubernetes/clusters/k3d/... -> kubernetes/clusters/local/...` の形で表示される
- 旧パス `kubernetes/{clusters,manifests}/k3d`、`kubernetes/components/*/k3d` がすべて消えている

Verify:
```bash
ls kubernetes/clusters kubernetes/manifests
ls kubernetes/components/cilium kubernetes/components/loki
```

- [ ] **Step 2: `kubernetes/helmfile.yaml.gotmpl` を更新**

`kubernetes/helmfile.yaml.gotmpl` を以下の内容に書き換える（環境名を `k3d` → `local` にし、コメント文言も更新）:

```yaml
# =============================================================================
# Helmfile Configuration
# =============================================================================
# This is the main entry point for Helmfile.
# It defines environments and includes component-specific helmfiles.
#
# Usage:
#   helmfile -e local list              # List all releases
#   helmfile -e local template          # Generate manifests
#   helmfile -e local apply             # Deploy to cluster
#
# TODO: (production) Add production, staging environments
# =============================================================================

environments:
  local:
    values:
      - cluster:
          name: k8s-local
          # TODO: (local) local-specific settings
          isLocal: true
  # TODO: (production) Uncomment and configure for production
  # production:
  #   values:
  #     - cluster:
  #         name: eks-production
  #         isLocal: false
  # staging:
  #   values:
  #     - cluster:
  #         name: eks-staging
  #         isLocal: false

# Include all component helmfiles for the current environment
helmfiles:
  - components/*/{{ .Environment.Name }}/helmfile.yaml
```

注: `cluster.name: k8s-local` は k3d クラスタの実名であり変更しない。

- [ ] **Step 3: 各コンポーネント helmfile.yaml の `environments:` を更新**

以下の 9 ファイルそれぞれで、`  k3d:` を `  local:` に置換し、ヘッダコメント中の "for k3d" を "for local" に置換する。

対象:
- `kubernetes/components/beyla/local/helmfile.yaml`
- `kubernetes/components/cilium/local/helmfile.yaml`
- `kubernetes/components/fluent-bit/local/helmfile.yaml`
- `kubernetes/components/loki/local/helmfile.yaml`
- `kubernetes/components/opentelemetry/local/helmfile.yaml`
- `kubernetes/components/opentelemetry-collector/local/helmfile.yaml`
- `kubernetes/components/prometheus-operator/local/helmfile.yaml`
- `kubernetes/components/tempo/local/helmfile.yaml`

各ファイルで:
- `# <Name> Helmfile for k3d` → `# <Name> Helmfile for local`
- `environments:` 直下の `  k3d:` → `  local:`

例（`kubernetes/components/loki/local/helmfile.yaml` のケース）:

`old_string`:
```
# Loki Helmfile for k3d
```
`new_string`:
```
# Loki Helmfile for local
```

`old_string`:
```
environments:
  k3d:
```
`new_string`:
```
environments:
  local:
```

- [ ] **Step 4: values.yaml と kustomization/*.yaml のコメントを更新**

これらのファイルでは「パス／環境名としての k3d」を「local」に置換するが、**「k3d クラスタの実行時挙動を説明する記述」と「k3d CLI 由来の生成値」は維持** する。

#### 維持する（変更しない）行:
- `kubernetes/components/cilium/local/values.yaml`: `k8sServiceHost: k3d-k8s-local-server-0`（k3d CLI が生成する API server ホスト名）

#### 置換対象の特定

まず以下のコマンドで対象行を一覧化する:

```bash
git grep -n '^# .* for k3d$' -- 'kubernetes/components/*/local/'
git grep -n 'with k3d-specific overrides' -- 'kubernetes/components/*/local/'
git grep -nE '# TODO: \(k3d\)' -- 'kubernetes/components/*/local/'
```

出力された各行に対して、Read でファイル全体を確認した上で以下の規則で Edit する。

#### 置換規則

**規則 1**: ヘッダコメント `# <Anything> for k3d` を `# <Anything> for local` に変更（"<Anything>" は実ファイルの文字列をそのまま保持）。例:
- `# Loki Helmfile for k3d` → `# Loki Helmfile for local`
- `# Cilium CNI Configuration for k3d` → `# Cilium CNI Configuration for local`
- `# Gateway API CRDs Kustomization for k3d` → `# Gateway API CRDs Kustomization for local`
- `# Hubble UI HTTPRoute for k3d` → `# Hubble UI HTTPRoute for local`
- `# CoreDNS ConfigMap for k3d` → `# CoreDNS ConfigMap for local`

**規則 2**: `# Production-ready base configuration with k3d-specific overrides` → `# Production-ready base configuration with local-specific overrides`

**規則 3**: TODO タグ `# TODO: (k3d)` の `(k3d)` 部分を `(local)` に変更。本文（タグの後ろの説明文）は、k3d クラスタの動作を説明している場合は維持し、env 名としての k3d を指す場合は `local` に変更。下記の個別ケースを参照。

ただし以下のように **「k3d クラスタの動作の説明」を含む TODO 文言は本文も書き換える** ものを以下に列挙:

##### `kubernetes/components/cilium/local/values.yaml`

`old_string`:
```
# TODO: (k3d) These values are specific to k3d cluster
# In production (EKS), use the actual API server endpoint
k8sServiceHost: k3d-k8s-local-server-0
```
`new_string`:
```
# TODO: (local) These values are specific to the local k3d cluster
# In production (EKS), use the actual API server endpoint
k8sServiceHost: k3d-k8s-local-server-0
```
（`k8sServiceHost` 値は維持。コメント本文の冒頭タグのみ `(local)` に。"specific to k3d cluster" は技術的説明として残すが、明示するため "the local k3d cluster" に変更）

##### `kubernetes/components/fluent-bit/local/values.yaml`

`old_string`: `  # TODO: (k3d) Systemd input is disabled to prevent /etc/machine-id mount errors in k3d`
`new_string`: `  # TODO: (local) Systemd input is disabled to prevent /etc/machine-id mount errors in k3d`
（"in k3d" は技術的説明として残す）

##### `kubernetes/components/coredns/local/kustomization/configmap.yaml`

`old_string`:
```
# =============================================================================
# CoreDNS ConfigMap for k3d
# =============================================================================
# This ConfigMap provides DNS configuration for the k3d cluster.
#
# TODO: (k3d) This configuration uses external DNS forwarders (8.8.8.8, etc.)
# because k3d can have issues with host DNS resolution.
# In production (EKS), CoreDNS uses the VPC DNS resolver automatically.
# =============================================================================
```
`new_string`:
```
# =============================================================================
# CoreDNS ConfigMap for local
# =============================================================================
# This ConfigMap provides DNS configuration for the k3d cluster.
#
# TODO: (local) This configuration uses external DNS forwarders (8.8.8.8, etc.)
# because k3d can have issues with host DNS resolution.
# In production (EKS), CoreDNS uses the VPC DNS resolver automatically.
# =============================================================================
```

`old_string`: `        # TODO: (k3d) Using public DNS forwarders for k3d compatibility`
`new_string`: `        # TODO: (local) Using public DNS forwarders for k3d compatibility`

##### `kubernetes/components/opentelemetry-collector/local/values.yaml`

`old_string`: `          # TODO: (k3d) Change to actual cluster name in production`
`new_string`: `          # TODO: (local) Change to actual cluster name in production`

##### `kubernetes/components/opentelemetry-collector/local/kustomization/hostport-patch.yaml`

`old_string`: `# TODO: (k3d) This patch adds hostPort to allow Beyla (hostNetwork pod) to`
`new_string`: `# TODO: (local) This patch adds hostPort to allow Beyla (hostNetwork pod) to`

##### `kubernetes/components/tempo/local/values.yaml`

`old_string`: `        # TODO: (k3d) Change cluster name in production`
`new_string`: `        # TODO: (local) Change cluster name in production`

##### `kubernetes/components/loki/local/values.yaml`

`old_string`: `  # Disable multi-tenancy for simplicity in k3d`
`new_string`: `  # Disable multi-tenancy for simplicity in local`

##### `kubernetes/components/beyla/local/values.yaml`

`old_string`: `      # Using ClusterIP DNS name - works with kube-proxy enabled in k3d`
`new_string`: `      # Using ClusterIP DNS name - works with kube-proxy enabled in local`
（同じ文字列が 2 箇所あるので `replace_all: true` を使用）

##### `kubernetes/components/prometheus-operator/local/values.yaml`

`old_string`:
```
# Disable admission webhooks (and the cert-gen Job) in k3d. The cert-gen Job
# in chart v82.x fails with an RBAC error patching ValidatingWebhookConfiguration,
# and PrometheusRule webhook validation is unnecessary for local dev.
```
`new_string`:
```
# Disable admission webhooks (and the cert-gen Job) in local. The cert-gen Job
# in chart v82.x fails with an RBAC error patching ValidatingWebhookConfiguration,
# and PrometheusRule webhook validation is unnecessary for local dev.
```

各ファイルを Edit する前に Read で正確な現在の内容を確認すること（コメント文言が上記と完全一致しない場合は実体に合わせる）。

- [ ] **Step 5: `kubernetes/Makefile` を更新**

複数箇所を修正する。各 Edit を順次実行。

##### Edit 1: ヘッダコメント

`old_string`:
```
# =============================================================================
# Kubernetes Platform Setup for k3d
# =============================================================================
# This Makefile provides commands to set up and manage a local Kubernetes
# cluster using k3d with a production-ready observability stack.
```
`new_string`:
```
# =============================================================================
# Kubernetes Platform Setup for local
# =============================================================================
# This Makefile provides commands to set up and manage a local Kubernetes
# cluster using k3d with a production-ready observability stack.
```

##### Edit 2: デフォルト ENV

`old_string`: `ENV ?= k3d`
`new_string`: `ENV ?= local`

##### Edit 3: hydrate-component の usage コメント

`old_string`: `hydrate-component: ## Hydrate single component (usage: make hydrate-component COMPONENT=cilium ENV=k3d)`
`new_string`: `hydrate-component: ## Hydrate single component (usage: make hydrate-component COMPONENT=cilium ENV=local)`

##### Edit 4: hydrate-index の usage コメント

`old_string`: `hydrate-index: ## Regenerate manifests/$(ENV) index and cleanup orphans (usage: make hydrate-index ENV=k3d)`
`new_string`: `hydrate-index: ## Regenerate manifests/$(ENV) index and cleanup orphans (usage: make hydrate-index ENV=local)`

##### Edit 5: hydrate の usage コメント

`old_string`: `hydrate: ## Hydrate all components (usage: make hydrate ENV=k3d)`
`new_string`: `hydrate: ## Hydrate all components (usage: make hydrate ENV=local)`

##### Edit 6: gateway-install のハードコードパス

`old_string`: `	@kubectl apply -k components/gateway-api/k3d/kustomization >/dev/null`
`new_string`: `	@kubectl apply -k components/gateway-api/$(ENV)/kustomization >/dev/null`

##### Edit 7: cilium-install のハードコードパス

`old_string`: `		kubectl apply -f manifests/k3d/cilium/manifest.yaml; \`
`new_string`: `		kubectl apply -f manifests/$(ENV)/cilium/manifest.yaml; \`

##### Edit 8: coredns-update のハードコードパス

`old_string`: `	@kubectl apply -k components/coredns/k3d/kustomization >/dev/null`
`new_string`: `	@kubectl apply -k components/coredns/$(ENV)/kustomization >/dev/null`

##### Edit 9: components-install の namespaces.yaml パス

`old_string`: `	@kubectl apply -f manifests/k3d/00-namespaces/namespaces.yaml`
`new_string`: `	@kubectl apply -f manifests/$(ENV)/00-namespaces/namespaces.yaml`

##### Edit 10: components-install の prometheus-operator パス

`old_string`: `	@kubectl apply --server-side --force-conflicts -f manifests/k3d/prometheus-operator/manifest.yaml >/dev/null 2>&1 || true`
`new_string`: `	@kubectl apply --server-side --force-conflicts -f manifests/$(ENV)/prometheus-operator/manifest.yaml >/dev/null 2>&1 || true`

##### Edit 11: components-install の kustomize 適用パス

`old_string`: `	@kubectl apply --server-side --force-conflicts -k manifests/k3d >/dev/null`
`new_string`: `	@kubectl apply --server-side --force-conflicts -k manifests/$(ENV) >/dev/null`

##### Edit 12: gitops-setup のパス

`old_string`: `	@kubectl apply -k clusters/k3d/flux-system || echo "$(YELLOW)⚠️  Push code to repository first$(NC)"`
`new_string`: `	@kubectl apply -k clusters/$(ENV)/flux-system || echo "$(YELLOW)⚠️  Push code to repository first$(NC)"`

##### Edit 13: gitops-enable のパス

`old_string`: `	@kubectl apply -k clusters/k3d >/dev/null || echo "$(YELLOW)⚠️  GitOps migration failed$(NC)"`
`new_string`: `	@kubectl apply -k clusters/$(ENV) >/dev/null || echo "$(YELLOW)⚠️  GitOps migration failed$(NC)"`

注: `k3d cluster create/delete/list` コマンドや `CLUSTER_NAME ?= k8s-local` は k3d CLI と k3d クラスタ名なので変更しない。

- [ ] **Step 6: `kubernetes/clusters/local/flux-system/gotk-sync.yaml` を更新**

`old_string`:
```
# =============================================================================
# FluxCD GitOps Sync Configuration for k3d
# =============================================================================
# This file configures FluxCD to sync with the Git repository.
#
# TODO: (production) Configure different branches for different environments
# =============================================================================
```
`new_string`:
```
# =============================================================================
# FluxCD GitOps Sync Configuration for local
# =============================================================================
# This file configures FluxCD to sync with the Git repository.
#
# TODO: (production) Configure different branches for different environments
# =============================================================================
```

`old_string`:
```
spec:
  interval: 1m
  url: https://github.com/panicboat/platform.git
  ref:
    # TODO: (k3d) Change branch for different environments
    branch: main
```
`new_string`:
```
spec:
  interval: 1m
  url: https://github.com/panicboat/platform.git
  ref:
    # TODO: (local) Change branch for different environments
    branch: main
```

`old_string`: `  path: ./kubernetes/clusters/k3d`
`new_string`: `  path: ./kubernetes/clusters/local`

- [ ] **Step 7: `kubernetes/clusters/local/repositories/monorepo.yaml` を更新**

`old_string`: `    # TODO: (k3d) Change branch for different environments`
`new_string`: `    # TODO: (local) Change branch for different environments`

注: `path: ./clusters/develop` は monorepo 側のパス（platform 側の env 名と独立）なので変更しない。

- [ ] **Step 8: `.github/workflows/reusable--kubernetes-builder.yaml` を更新**

`old_string`: `        description: 'Target environment (e.g., k3d)'`
`new_string`: `        description: 'Target environment (e.g., local)'`

- [ ] **Step 9: `.github/workflows/reusable--kubernetes-hydrator.yaml` を更新**

`old_string`: `        description: 'Target environment for hydration (e.g., k3d)'`
`new_string`: `        description: 'Target environment for hydration (e.g., local)'`

- [ ] **Step 10: `kubernetes/README.md` を更新**

事前に Read で文脈を確認。

`kubernetes/README.md` L111 の `- k3d クラスター作成` は **変更しない**（k3d CLI でクラスターを作成する手順の記述）。

L127 を以下で更新:

`old_string`: ``- FluxCD が `manifests/k3d`（コンポーネント別サブディレクトリ）を同期``
`new_string`: ``- FluxCD が `manifests/local`（コンポーネント別サブディレクトリ）を同期``

- [ ] **Step 11: `README.md` の環境表と関連記述を更新**

事前に Read で全体構造を確認した上で、以下を実施:

##### Edit 1: ディレクトリツリー内の表記

`old_string`:
```
├── aws/                       # Terragrunt stacks (module + envs/{environment})
│   ├── claude-code/
│   ├── claude-code-action/
│   ├── github-oidc-auth/
│   └── vpc/
```
`new_string`:
```
├── aws/                       # Terragrunt stacks (module + envs/{environment})
│   ├── ai-assistant/
│   ├── github-oidc-auth/
│   └── vpc/
```

##### Edit 2: Environments の表（local 行追加 + 文言修正）

`old_string`:
```
Defined in `workflow-config.yaml`. Currently `develop` and `production` are active; `staging` is reserved (commented out).

| Environment | AWS Region | AWS Account | Status |
|-------------|------------|-------------|--------|
| develop | us-east-1 | 559744160976 | Active |
| staging | - | - | Reserved |
| production | ap-northeast-1 | 559744160976 | Active |
```
`new_string`:
```
Defined in `workflow-config.yaml`. `local`, `develop`, and `production` are active.

| Environment | AWS Region | AWS Account | Status |
|-------------|------------|-------------|--------|
| local | - | - | Active (kubernetes only, k3d cluster) |
| develop | us-east-1 | 559744160976 | Active |
| production | ap-northeast-1 | 559744160976 | Active |
```

##### Edit 3: Claude Code Integration セクション

`old_string`:
```
- `.github/workflows/claude-code-action.yaml` is triggered by `@claude` comments and invokes AWS Bedrock Claude via the `claude-code-action` IAM role.
- `aws/claude-code-action/` and `aws/claude-code/` define the IAM roles for Bedrock invocation and execution respectively.
```
`new_string`:
```
- `.github/workflows/claude-code-action.yaml` is triggered by `@claude` comments and invokes AWS Bedrock Claude via the `ai-assistant` IAM role.
- `aws/ai-assistant/` defines the IAM roles for Bedrock invocation and execution.
```

- [ ] **Step 12: `README-ja.md` を同様に更新**

事前に Read。`README.md` と同じ箇所を日本語側でも対応する。具体的な文言は `README-ja.md` を読んでから差分を最小化する形で適用する。

主な変更点:
- ディレクトリツリーの `claude-code/` `claude-code-action/` → `ai-assistant/`
- Environments 表に `local` 行追加、`staging` 行削除
- Claude Code Integration の記述を `ai-assistant` に統一

- [ ] **Step 13: マニフェストを再生成**

旧 `manifests/k3d/` の内容を `manifests/local/` に移動済みだが、values.yaml のコメントなどが変わった可能性があるため再生成する。

Run:
```bash
make -C kubernetes hydrate ENV=local
```

Expected:
- 終了コード 0
- `kubernetes/manifests/local/` 配下の各コンポーネントが再生成される
- 既存 `manifests/k3d` ディレクトリ参照のエラーが出ない

Verify:
```bash
ls kubernetes/manifests/local
```
出力に `00-namespaces/`、各コンポーネント名（cilium, loki など）、`kustomization.yaml` が含まれること。

- [ ] **Step 14: 残存 k3d 参照のチェック**

「ツール名としての k3d」のみが残ることを確認する。

Run:
```bash
git grep -nE 'k3d' -- ':!docs/superpowers/' ':!kubernetes/manifests/local/'
```

Expected: 出力される行が以下のいずれかのカテゴリのみ:
- k3d CLI コマンド（`k3d cluster ...`）
- k3d クラスタ名（`CLUSTER_NAME ?= k8s-local`、`k3d-k8s-local-server-0`）
- 「k3d クラスタ／k3d ツール」を技術的に説明するコメント（"k3d cluster"、"in k3d"、"with k3d"、"k3d serverlb" など）

manifests/local 配下にも k3d 参照があるかもしれないが、これらは生成物（ConfigMap value など）でツール由来なので追加チェック不要。

もし「パス／環境名としての k3d」（例: `manifests/k3d`、`clusters/k3d`、`(k3d) <環境向け設定の説明>` など）が残っていたら該当箇所を Edit で修正してから再度 Step 14 を実行。

- [ ] **Step 15: Makefile が正しく動くかローカル実行で確認**

クラスタ作成不要、ヘルプとパス確認のみ。

Run:
```bash
make -C kubernetes help | head -20
```

Expected: 終了コード 0、`make hydrate` などの help が表示される。エラーで失敗しない。

- [ ] **Step 16: 変更を 1 コミットにまとめる**

Run:
```bash
git add -A
git status
```

Verify: `git status` の出力に以下が含まれる:
- `renamed:` で 全 `k3d` → `local` のディレクトリ配下のリネーム
- `modified:` で `kubernetes/Makefile`、`kubernetes/helmfile.yaml.gotmpl`、`workflow-config.yaml` 以外の前述ファイル
- 新規・削除ファイルが想定外の場所に無い

Run:
```bash
git commit -s -m "$(cat <<'EOF'
refactor(kubernetes): rename k3d environment to local

- workflow-config.yaml の environments と整合する環境名に統一
- kubernetes/{clusters,components/*,manifests}/k3d/ を local/ にリネーム
- helmfile, Makefile, ワークフロー YAML, README の参照を更新
- ツール名（k3d CLI コマンド、k3d クラスタ名）は維持
EOF
)"
```

Expected: コミットが成功し、`git log --oneline -1` で `refactor(kubernetes): rename k3d environment to local` が表示される。

---

## Task 3: `workflow-config.yaml` を更新（1 コミット）

`local` 環境を追加し、`staging` の予約コメントブロックを削除する。

**Files:**
- Modify: `workflow-config.yaml`

- [ ] **Step 1: Task 1 の判定結果を確認**

`docs/superpowers/plans/2026-04-26-environment-naming.notes.md` の `label-resolver schema:` 行を確認:
- 案 a（フィールド省略）→ Step 2 で空のフィールドを書かない
- 案 b（フィールド必須）→ Step 2 で空文字フィールドを書く

- [ ] **Step 2-a: 案 a の場合 — `local` 環境追加 + staging コメント削除**

`workflow-config.yaml` を以下の内容に書き換える:

```yaml
environments:
  - environment: local
    # local environment is kubernetes-only; no AWS fields

  - environment: develop
    aws_region: us-east-1
    iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role
    iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role

  - environment: production
    aws_region: ap-northeast-1
    iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-role
    iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-role

directory_conventions:
  - root: "aws/{service}"
    stacks:
      - name: terragrunt
        directory: "envs/{environment}"

  - root: "github/{service}"
    stacks:
      - name: terragrunt
        directory: "envs/{environment}"

  - root: "kubernetes/components/{service}"
    stacks:
      - name: kubernetes
        directory: "{environment}"
```

- [ ] **Step 2-b: 案 b の場合 — 空文字フィールド付き**

案 b の場合は `local` の定義を以下に差し替える:

```yaml
  - environment: local
    aws_region: ""
    iam_role_plan: ""
    iam_role_apply: ""
```

- [ ] **Step 3: 構造の妥当性を確認**

Run:
```bash
yq '.environments[].environment' workflow-config.yaml
```

Expected:
```
local
develop
production
```

- [ ] **Step 4: コミット**

Run:
```bash
git add workflow-config.yaml
git commit -s -m "$(cat <<'EOF'
chore(workflow-config): add local environment and remove staging stub

- environments に local を追加（kubernetes 専用）
- staging の予約コメントブロックを削除
EOF
)"
```

---

## Task 4: AWS env.hcl の region 修正（1 コミット）

`develop` のリージョン記述を `workflow-config.yaml` と整合させる。

**Files:**
- Modify: `aws/github-oidc-auth/envs/develop/env.hcl`
- Modify: `aws/ai-assistant/envs/develop/env.hcl`

- [ ] **Step 1: `aws/github-oidc-auth/envs/develop/env.hcl` を編集**

`old_string`: `  aws_region  = "ap-northeast-1"`
`new_string`: `  aws_region  = "us-east-1"`

- [ ] **Step 2: `aws/ai-assistant/envs/develop/env.hcl` を編集**

`old_string`: `  aws_region           = "ap-northeast-1"`
`new_string`: `  aws_region           = "us-east-1"`

- [ ] **Step 3: `terragrunt plan` で意図通りの差分を確認 — github-oidc-auth**

Run:
```bash
cd aws/github-oidc-auth/envs/develop && terragrunt plan
```

Expected:
- IAM は Global サービスなので、リージョン変更による IAM ロール／ポリシーの replace は発生しない
- Plan 出力に `# replace` または `destroy` のフラグが付いた IAM リソースが **無い** こと
- Provider configuration の region 値が変わるが、リソース差分には現れないか、tag のみの変更

もし IAM リソースが replace 扱いになった場合は **Stop し、ユーザに確認** を求める。

- [ ] **Step 4: `terragrunt plan` で意図通りの差分を確認 — ai-assistant**

Run:
```bash
cd aws/ai-assistant/envs/develop && terragrunt plan
```

Expected:
- リージョナルリソース（CloudWatch Logs グループ、Bedrock IAM 設定の region 限定 ARN 等）が含まれていなければ、replace は発生しない
- Plan 出力に `replace`、`destroy` 操作 **無し**

もし replace が発生したら **Stop し、ユーザに確認** を求める（リソース再作成・データロスのリスクがあるため）。

- [ ] **Step 5: コミット**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/refactor-environment-naming-local
git add aws/github-oidc-auth/envs/develop/env.hcl aws/ai-assistant/envs/develop/env.hcl
git commit -s -m "$(cat <<'EOF'
fix(aws/envs/develop): align aws_region with workflow-config (us-east-1)

env.hcl が ap-northeast-1 で、workflow-config.yaml と README の
us-east-1 と乖離していた。Source-of-truth である workflow-config に揃える。
IAM は Global サービスのため region 変更でリソース再作成は発生しない。
EOF
)"
```

---

## Task 5: `staging` ディレクトリ削除（1 コミット）

`workflow-config.yaml` での予約コメントは Task 3 で削除済み。残る `aws/github-oidc-auth/envs/staging/` を削除する。

**Files:**
- Delete: `aws/github-oidc-auth/envs/staging/`

- [ ] **Step 1: Task 1 の state 判定結果を確認**

`docs/superpowers/plans/2026-04-26-environment-naming.notes.md` の `staging state:` 行が `無し` であること。

`要 destroy` の場合: ユーザに確認の上、`cd aws/github-oidc-auth/envs/staging && terragrunt destroy` を先行してから本 Task に戻る。

- [ ] **Step 2: ディレクトリ削除**

Run:
```bash
git rm -r aws/github-oidc-auth/envs/staging
```

Expected:
- `aws/github-oidc-auth/envs/staging/env.hcl` と `terragrunt.hcl` が削除されたとして表示される
- 配下の他ファイルも削除されている

Verify:
```bash
ls aws/github-oidc-auth/envs/
```
Expected: `develop` と `production` のみ表示される。

- [ ] **Step 3: コミット**

Run:
```bash
git commit -s -m "$(cat <<'EOF'
chore(aws/github-oidc-auth): remove unused staging environment

workflow-config.yaml から staging 予約は削除済み。
残骸の env.hcl もディレクトリごと削除する。
将来必要になったら新規追加する。
EOF
)"
```

---

## Task 6: ローカル検証 + Draft PR 作成 + CI 検証

すべての変更が CI で意図通り動くことを確認する。

**Files:** なし（検証と PR）

- [ ] **Step 1: 全 commit の確認**

Run:
```bash
git log --oneline origin/main..HEAD
```

Expected: 4 commits（design spec、refactor rename、workflow-config、env.hcl region、staging delete）。

注: 本 plan を Task 2 で 1 コミット、Task 3〜5 で 3 コミットに分けたため、design spec を入れて合計 5 コミットの可能性。spec コミットは既に存在するためプッシュ前に origin にも未送信なら 5 コミット。

- [ ] **Step 2: ローカルで hydrate を最終実行**

Run:
```bash
make -C kubernetes hydrate ENV=local
git status -- kubernetes/manifests/local
```

Expected: いずれかの出力:
- 変更なし（Task 2 の Step 13 で再生成済み）
- 微小な差分があれば、それを追加コミット

差分があれば追加コミット:
```bash
git add kubernetes/manifests/local
git commit -s -m "chore(kubernetes/manifests/local): regenerate after rename"
```

- [ ] **Step 3: ブランチを push**

Run:
```bash
git push -u origin HEAD
```

Expected: `refactor/environment-naming-local` がリモートに作成され、tracking が設定される。

- [ ] **Step 4: Draft PR を作成**

Run:
```bash
gh pr create --draft --title "refactor: rename k3d environment to local" --body "$(cat <<'EOF'
## Summary

- `kubernetes/{clusters,components/*,manifests}/k3d/` を `local/` にリネーム
- `workflow-config.yaml` に `local` 環境を追加し、Kubernetes hydrate ジョブが起動するように修正
- `develop` 環境の AWS リージョン記述を `us-east-1` に統一
- `staging` 残骸（`workflow-config.yaml` の予約コメントと `aws/github-oidc-auth/envs/staging/`）を削除
- README の `aws/claude-code{,-action}/` 表記を `aws/ai-assistant/` に修正、環境表に `local` 行を追加

Spec: `docs/superpowers/specs/2026-04-26-environment-naming-design.md`

## Test plan

- [ ] `auto-label--label-dispatcher` が `kubernetes` 系ラベルを付与する
- [ ] `auto-label--deploy-trigger` の `deploy-kubernetes-hydrate` ジョブが env=local で起動する
- [ ] hydrate ジョブが `kubernetes/manifests/local/` への差分コミットを PR に追加する（差分が無ければ no-op）
- [ ] `deploy-kubernetes` ジョブが各コンポーネントの diff コメントを投稿する
- [ ] `terragrunt plan` が `aws/github-oidc-auth/envs/develop`、`aws/ai-assistant/envs/develop` で意図通りの差分を出す
EOF
)"
```

Expected: PR URL が出力される。

- [ ] **Step 5: CI のラベル付与確認**

Run:
```bash
gh pr view --json labels
```

Expected: `kubernetes` 関連、各 service の deploy ラベルが付与されている。

- [ ] **Step 6: hydrate ジョブの起動と差分コミット確認**

Run:
```bash
gh pr view --json statusCheckRollup
```

Expected: `deploy-kubernetes-hydrate` という名前のジョブが `IN_PROGRESS` または `SUCCESS` で表示される。

ジョブ完了後:
```bash
git fetch origin
git log --oneline origin/refactor/environment-naming-local
```

Expected: `chore(kubernetes/manifests/local): hydrate manifests` というコミットがリモートに追加されている可能性（差分があれば）。差分が無ければコミット無し（OK）。

- [ ] **Step 7: builder ジョブの diff コメント確認**

Run:
```bash
gh pr view --comments | grep -A2 'kubernetes-service-local\|kubernetes-index-local'
```

Expected: `kubernetes-index-local` または各 service の `kubernetes-service-<svc>-local` のコメントタグが見つかる。

- [ ] **Step 8: 最終 grep で k3d 残存確認**

Run:
```bash
git grep -nE 'k3d' -- ':!docs/superpowers/' ':!kubernetes/manifests/local/'
```

Expected: ツール名としての k3d 参照のみ残る。パス／環境名としての k3d 参照は無い。

- [ ] **Step 9: PR を Ready for review に変更**

すべてのチェックが緑になり、CI 検証が完了したら:

Run:
```bash
gh pr ready
```

Expected: Draft が解除される。

---

## 完了基準

以下がすべて満たされた時点で本 plan 完了:

- [ ] `auto-label--label-dispatcher` が PR に kubernetes ラベルを付与する
- [ ] `auto-label--deploy-trigger` で `deploy-kubernetes-hydrate` ジョブが env=local で実行される
- [ ] `terragrunt plan` が `aws/github-oidc-auth/envs/develop` と `aws/ai-assistant/envs/develop` で replace/destroy 無し
- [ ] `git grep 'k3d'` の結果がツール名 k3d の参照のみ
- [ ] PR が Draft 解除され、CI チェックがすべて緑
