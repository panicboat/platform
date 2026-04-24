# Kubernetes Builder Race Condition Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kubernetes builder ワークフローの matrix 並列実行で発生する hydrate race condition を、hydrate ジョブ分離とマニフェストのコンポーネントサブディレクトリ化で解消する。

**Architecture:** `reusable--kubernetes-hydrator.yaml` を新設し、env 単位の matrix と concurrency で hydrate を直列化。`reusable--kubernetes-builder.yaml` は diff 専用に縮小し、コンポーネントサブディレクトリを path とする。Makefile に `hydrate-component`, `hydrate-index` ターゲットを追加。

**Tech Stack:** GNU Make, Bash (`set -euo pipefail`), helmfile, kustomize, aqua, GitHub Actions (reusable workflows, matrix, concurrency), jq, `stefanzweifel/git-auto-commit-action`, `thollander/actions-comment-pull-request`, actionlint.

**Spec:** [`docs/superpowers/specs/2026-04-25-kubernetes-builder-race-condition-design.md`](../specs/2026-04-25-kubernetes-builder-race-condition-design.md)

**Prerequisites (local):** aqua（`.github/aqua.yaml` で helmfile, kustomize, actionlint, yamllint を管理）が有効であること。

---

## File Structure

| 種別 | パス | 責務 |
|------|------|------|
| Modify | `kubernetes/Makefile` | `hydrate-component`, `hydrate-index` 追加、`hydrate` 再実装、phase3 path 更新 |
| Regenerate | `kubernetes/manifests/k3d/*` | フラット構造 → コンポーネントサブディレクトリ構造 |
| Create | `.github/workflows/reusable--kubernetes-hydrator.yaml` | env 単位の hydrate + commit + index diff コメント |
| Modify | `.github/workflows/reusable--kubernetes-builder.yaml` | diff 専用に縮小、path をコンポーネントサブディレクトリに |
| Modify | `.github/workflows/auto-label--deploy-trigger.yaml` | `kubernetes-targets-group`, `deploy-kubernetes-hydrate` 追加、`deploy-kubernetes` の `needs` 更新 |
| Modify | `kubernetes/README.md`, `README.md`, `README-ja.md` | 構造説明の更新 |

---

## Task 1: Makefile に `hydrate-component` ターゲットを追加

**Files:**
- Modify: `kubernetes/Makefile`（L78 直前に新ターゲット追加）

- [ ] **Step 1: `hydrate-component` ターゲットを追加**

`kubernetes/Makefile` の L77（既存 `hydrate` の直前 `# Phase 0: Hydrate Manifests` セクション内）に、以下の新ターゲットを**追加**する。既存 `hydrate` ターゲットは Task 3 まで変更しない。

挿入位置: L77（既存 `.PHONY: hydrate` の直前）

```makefile
.PHONY: hydrate-component
hydrate-component: ## Hydrate single component (usage: make hydrate-component COMPONENT=cilium ENV=k3d)
	@set -euo pipefail; \
	component_dir="components/$(COMPONENT)/$(ENV)"; \
	out_dir="manifests/$(ENV)/$(COMPONENT)"; \
	mkdir -p "$$out_dir"; \
	: > "$$out_dir/manifest.yaml"; \
	if [ -f "$$component_dir/helmfile.yaml" ]; then \
		helmfile -f "$$component_dir/helmfile.yaml" template --include-crds --skip-tests >> "$$out_dir/manifest.yaml"; \
	fi; \
	if [ -d "$$component_dir/kustomization" ]; then \
		echo "---" >> "$$out_dir/manifest.yaml"; \
		kustomize build "$$component_dir/kustomization" >> "$$out_dir/manifest.yaml"; \
	fi; \
	printf "resources:\n  - manifest.yaml\n" > "$$out_dir/kustomization.yaml"; \
	if git ls-files --error-unmatch "$$out_dir/manifest.yaml" >/dev/null 2>&1; then \
		if git diff --quiet -I '^[[:space:]]*(ca\.crt|ca\.key|tls\.crt|tls\.key|caBundle):' -- "$$out_dir/manifest.yaml"; then \
			git checkout -- "$$out_dir/manifest.yaml"; \
		fi; \
	fi

```

- [ ] **Step 2: 動作確認: 1 コンポーネントを単独 hydrate**

Run:
```bash
cd kubernetes && make hydrate-component COMPONENT=cilium ENV=k3d
```

Expected:
- 終了コード 0
- `kubernetes/manifests/k3d/cilium/manifest.yaml` が非空で存在
- `kubernetes/manifests/k3d/cilium/kustomization.yaml` が `resources:\n  - manifest.yaml` で存在
- 既存の `kubernetes/manifests/k3d/cilium.yaml` は残存（Task 3 以降で削除される）

Verify:
```bash
ls -la kubernetes/manifests/k3d/cilium/
cat kubernetes/manifests/k3d/cilium/kustomization.yaml
test -s kubernetes/manifests/k3d/cilium/manifest.yaml && echo "non-empty: OK"
```

- [ ] **Step 3: 動作確認: 冪等性（2 回実行で差分なし）**

Run:
```bash
cd kubernetes && make hydrate-component COMPONENT=cilium ENV=k3d
git diff --quiet -I '^[[:space:]]*(ca\.crt|ca\.key|tls\.crt|tls\.key|caBundle):' -- manifests/k3d/cilium/ && echo "idempotent: OK"
```

Expected: `idempotent: OK`

- [ ] **Step 4: 動作確認: エラー伝播（存在しないコンポーネント）**

Run:
```bash
cd kubernetes && make hydrate-component COMPONENT=nonexistent ENV=k3d
```

Expected: 終了コード 0、`manifests/k3d/nonexistent/manifest.yaml` は空ファイル（helmfile も kustomization も不在）、`kustomization.yaml` は生成される。これは**意図的な挙動**: `hydrate-index` の orphan cleanup が後で `manifests/k3d/nonexistent/` を削除する。

後片付け:
```bash
rm -rf kubernetes/manifests/k3d/nonexistent/
```

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
# cilium/ サブディレクトリは Task 4 で全コンポーネント分を一括 commit するのでここでは除外
git checkout -- kubernetes/manifests/
git add kubernetes/Makefile
git commit -s -m "feat(kubernetes): add hydrate-component make target

Component-scoped hydrate for parallel-safe, per-component regeneration.
Uses set -euo pipefail so helmfile/kustomize failures propagate.

Refs: #190"
```

---

## Task 2: Makefile に `hydrate-index` ターゲットを追加

**Files:**
- Modify: `kubernetes/Makefile`（Task 1 で追加した `hydrate-component` の直後）

- [ ] **Step 1: `hydrate-index` ターゲットを追加**

Task 1 で追加した `hydrate-component` ターゲットの直後に以下を**追加**する。

```makefile
.PHONY: hydrate-index
hydrate-index: ## Regenerate manifests/$(ENV) index and cleanup orphans (usage: make hydrate-index ENV=k3d)
	@set -euo pipefail; \
	env_dir="manifests/$(ENV)"; \
	mkdir -p "$$env_dir/00-namespaces"; \
	find components -maxdepth 2 -name namespace.yaml | sort | \
		xargs -I{} sh -c 'echo "---"; cat "{}"' > "$$env_dir/00-namespaces/namespaces.yaml"; \
	printf "resources:\n  - namespaces.yaml\n" > "$$env_dir/00-namespaces/kustomization.yaml"; \
	for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null); do \
		name=$$(basename "$$dir"); \
		if [ "$$name" = "00-namespaces" ]; then continue; fi; \
		if [ ! -d "components/$$name/$(ENV)" ]; then \
			rm -rf "$$dir"; \
		fi; \
	done; \
	{ \
		echo "resources:"; \
		echo "  - ./00-namespaces"; \
		for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null | grep -v "/00-namespaces/$$" | sort); do \
			echo "  - ./$$(basename $$dir)"; \
		done; \
	} > "$$env_dir/kustomization.yaml"

```

- [ ] **Step 2: 動作確認: index 生成**

Run（Task 1 で cilium だけ hydrate 済みの状態で実行）:
```bash
cd kubernetes && make hydrate-component COMPONENT=coredns ENV=k3d
cd kubernetes && make hydrate-index ENV=k3d
```

Expected:
- `kubernetes/manifests/k3d/00-namespaces/namespaces.yaml` が非空
- `kubernetes/manifests/k3d/00-namespaces/kustomization.yaml` が存在
- `kubernetes/manifests/k3d/kustomization.yaml` が以下のような内容:
  ```yaml
  resources:
    - ./00-namespaces
    - ./cilium
    - ./coredns
  ```

Verify:
```bash
cat kubernetes/manifests/k3d/kustomization.yaml
cat kubernetes/manifests/k3d/00-namespaces/kustomization.yaml
ls kubernetes/manifests/k3d/00-namespaces/namespaces.yaml
```

- [ ] **Step 3: 動作確認: Orphan cleanup**

ダミーの orphan ディレクトリを作り、`hydrate-index` が削除することを確認:
```bash
mkdir -p kubernetes/manifests/k3d/orphan-test && echo "stale" > kubernetes/manifests/k3d/orphan-test/manifest.yaml
cd kubernetes && make hydrate-index ENV=k3d
test ! -d manifests/k3d/orphan-test && echo "orphan cleanup: OK"
```

Expected: `orphan cleanup: OK`

- [ ] **Step 4: 動作確認: トップ kustomization.yaml が kustomize build できる**

Run:
```bash
cd kubernetes && kustomize build manifests/k3d >/dev/null && echo "kustomize build: OK"
```

Expected: `kustomize build: OK`（Task 1 の cilium と Task 2 の coredns のマニフェストがビルド可能）

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git checkout -- kubernetes/manifests/
git add kubernetes/Makefile
git commit -s -m "feat(kubernetes): add hydrate-index make target

Regenerates manifests/\$(ENV)/kustomization.yaml and
manifests/\$(ENV)/00-namespaces/ from the current components/ state,
with orphan directory cleanup for removed components.

Refs: #190"
```

---

## Task 3: Makefile の `hydrate` を新ターゲットへの delegation に書き換え

**Files:**
- Modify: `kubernetes/Makefile`（既存 L78–104 の `hydrate` ターゲット全体を置換）

- [ ] **Step 1: `hydrate` ターゲットを置換**

既存の `.PHONY: hydrate` から `@echo "$(GREEN)✅ Manifests hydrated$(NC)"` までのブロック全体を、以下で置換する。

```makefile
.PHONY: hydrate
hydrate: ## Hydrate all components (usage: make hydrate ENV=k3d)
	@echo "$(BLUE)💧 Hydrating manifests for $(ENV)...$(NC)"
	@rm -rf manifests/$(ENV)/*
	@mkdir -p manifests/$(ENV)
	@for component in $$(ls -d components/*/$(ENV) 2>/dev/null | cut -d'/' -f2 | sort -u); do \
		echo "Hydrating $$component..."; \
		$(MAKE) hydrate-component COMPONENT=$$component ENV=$(ENV); \
	done
	@$(MAKE) hydrate-index ENV=$(ENV)
	@echo "$(GREEN)✅ Manifests hydrated$(NC)"
```

- [ ] **Step 2: 動作確認: フル hydrate**

Run:
```bash
cd kubernetes && make hydrate ENV=k3d
```

Expected:
- 全 11 コンポーネント + 00-namespaces がサブディレクトリ構造で生成される
- `kubernetes/manifests/k3d/` 配下に既存のフラット `.yaml` ファイル（cilium.yaml 等）が残っていない（`rm -rf manifests/$(ENV)/*` により削除）

Verify:
```bash
ls kubernetes/manifests/k3d/
# Expected: 00-namespaces/ beyla/ cilium/ coredns/ dashboard/ fluent-bit/
#           gateway-api/ kustomization.yaml loki/ opentelemetry/
#           opentelemetry-collector/ prometheus-operator/ tempo/

test ! -f kubernetes/manifests/k3d/cilium.yaml && echo "flat files removed: OK"
kustomize build kubernetes/manifests/k3d >/dev/null && echo "kustomize build: OK"
```

- [ ] **Step 3: 動作確認: 既存出力との diff（cert 以外ゼロ）**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
# 新構造でビルドされたマニフェストの内容を kustomize 経由で取得
kustomize build kubernetes/manifests/k3d > /tmp/hydrate-new.yaml

# 比較用に origin/main の flat 構造でビルド
git show origin/main:kubernetes/manifests/k3d/kustomization.yaml > /tmp/old-kustomization.yaml
# （参考: origin/main 側は flat 構造でビルド可能。直接差分比較は構造が違うので難しい。
#  代わりに両者のリソース数・種別を比較する。）

grep -c "^kind:" /tmp/hydrate-new.yaml
```

Expected: リソース数が origin/main の `kustomize build kubernetes/manifests/k3d` 結果と等しい（手動比較）。cert 関連フィールドのみ差分が出る可能性あり（helm の再生成）。

- [ ] **Step 4: Commit**

この commit には Makefile 変更のみを含める。manifests の構造変更は Task 4 で別 commit する。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git checkout -- kubernetes/manifests/
git add kubernetes/Makefile
git commit -s -m "refactor(kubernetes): delegate hydrate to component/index targets

The top-level hydrate target now loops over components invoking
hydrate-component, then runs hydrate-index once. Output structure
changes from flat files to per-component subdirectories, which is
applied in a follow-up commit.

Refs: #190"
```

---

## Task 4: Makefile の phase3 path 参照を更新

**Files:**
- Modify: `kubernetes/Makefile` L141, L211, L214

- [ ] **Step 1: L141（cilium-install）の path 更新**

既存:
```makefile
		kubectl apply -f manifests/k3d/cilium.yaml; \
```

変更後:
```makefile
		kubectl apply -f manifests/k3d/cilium/manifest.yaml; \
```

- [ ] **Step 2: L211（components-install の namespaces）の path 更新**

既存:
```makefile
	@kubectl apply -f manifests/k3d/00-namespaces.yaml
```

変更後:
```makefile
	@kubectl apply -f manifests/k3d/00-namespaces/namespaces.yaml
```

- [ ] **Step 3: L214（components-install の prometheus-operator）の path 更新**

既存:
```makefile
	@kubectl apply --server-side --force-conflicts -f manifests/k3d/prometheus-operator.yaml >/dev/null 2>&1 || true
```

変更後:
```makefile
	@kubectl apply --server-side --force-conflicts -f manifests/k3d/prometheus-operator/manifest.yaml >/dev/null 2>&1 || true
```

- [ ] **Step 4: 動作確認: Makefile 構文チェック**

Run:
```bash
cd kubernetes && make -n cilium-install 2>/dev/null | grep "manifest.yaml" && echo "L141: OK"
cd kubernetes && make -n components-install 2>/dev/null | grep "00-namespaces/namespaces.yaml" && echo "L211: OK"
cd kubernetes && make -n components-install 2>/dev/null | grep "prometheus-operator/manifest.yaml" && echo "L214: OK"
```

Expected: 3 つとも `OK`

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git add kubernetes/Makefile
git commit -s -m "refactor(kubernetes): update phase3 manifest paths for subdirectory layout

Update cilium-install and components-install to reference
per-component manifest.yaml and 00-namespaces/namespaces.yaml.

Refs: #190"
```

---

## Task 5: `kubernetes/manifests/k3d/` をサブディレクトリ構造に再生成してコミット

**Files:**
- Modify: `kubernetes/manifests/k3d/*`（フラット構造 → サブディレクトリ構造への一括変換）

- [ ] **Step 1: 新構造でフル hydrate**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
make -C kubernetes hydrate ENV=k3d
```

Expected:
- 既存のフラット `.yaml`（cilium.yaml 等）が削除される
- 11 コンポーネント + 00-namespaces のサブディレクトリが生成される
- `kubernetes/manifests/k3d/kustomization.yaml` がサブディレクトリ参照になる

- [ ] **Step 2: 構造確認**

Run:
```bash
find kubernetes/manifests/k3d -maxdepth 2 -type f | sort
```

Expected（順序は前後あり、計 25 ファイル程度）:
```
kubernetes/manifests/k3d/00-namespaces/kustomization.yaml
kubernetes/manifests/k3d/00-namespaces/namespaces.yaml
kubernetes/manifests/k3d/beyla/kustomization.yaml
kubernetes/manifests/k3d/beyla/manifest.yaml
kubernetes/manifests/k3d/cilium/kustomization.yaml
kubernetes/manifests/k3d/cilium/manifest.yaml
kubernetes/manifests/k3d/coredns/kustomization.yaml
kubernetes/manifests/k3d/coredns/manifest.yaml
kubernetes/manifests/k3d/dashboard/kustomization.yaml
kubernetes/manifests/k3d/dashboard/manifest.yaml
kubernetes/manifests/k3d/fluent-bit/kustomization.yaml
kubernetes/manifests/k3d/fluent-bit/manifest.yaml
kubernetes/manifests/k3d/gateway-api/kustomization.yaml
kubernetes/manifests/k3d/gateway-api/manifest.yaml
kubernetes/manifests/k3d/kustomization.yaml
kubernetes/manifests/k3d/loki/kustomization.yaml
kubernetes/manifests/k3d/loki/manifest.yaml
kubernetes/manifests/k3d/opentelemetry-collector/kustomization.yaml
kubernetes/manifests/k3d/opentelemetry-collector/manifest.yaml
kubernetes/manifests/k3d/opentelemetry/kustomization.yaml
kubernetes/manifests/k3d/opentelemetry/manifest.yaml
kubernetes/manifests/k3d/prometheus-operator/kustomization.yaml
kubernetes/manifests/k3d/prometheus-operator/manifest.yaml
kubernetes/manifests/k3d/tempo/kustomization.yaml
kubernetes/manifests/k3d/tempo/manifest.yaml
```

- [ ] **Step 3: kustomize build 検証**

Run:
```bash
kustomize build kubernetes/manifests/k3d > /tmp/new-build.yaml
grep -c "^kind:" /tmp/new-build.yaml
```

Expected: リソース数が 0 より大きく、`kustomize build` がエラーなく完了する。

- [ ] **Step 4: リソース集合の parity 比較（origin/main との比較）**

別 worktree に origin/main をチェックアウトしてビルド結果を比較する。

Run:
```bash
git worktree add /tmp/main-parity-check origin/main
kustomize build /tmp/main-parity-check/kubernetes/manifests/k3d > /tmp/old-build.yaml
git worktree remove /tmp/main-parity-check

# kind と name を抽出してソート比較（順序非依存）
diff <(grep -E "^(kind|  name):" /tmp/old-build.yaml | sort -u) \
     <(grep -E "^(kind|  name):" /tmp/new-build.yaml | sort -u) && \
  echo "resource set matches: OK"
```

Expected: `resource set matches: OK`（リソース集合が完全一致）

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git add kubernetes/manifests/k3d
git commit -s -m "chore(kubernetes/manifests/k3d): migrate to per-component subdirectory layout

Replace flat \$(component).yaml files with \$(component)/manifest.yaml
+ kustomization.yaml pairs, plus 00-namespaces/ subdirectory.
Top-level kustomization.yaml now references subdirectories.

Enables per-component diff scoping in kubernetes-builder workflow.

Refs: #190"
```

---

## Task 6: `.github/workflows/reusable--kubernetes-hydrator.yaml` を新規作成

**Files:**
- Create: `.github/workflows/reusable--kubernetes-hydrator.yaml`

- [ ] **Step 1: ファイル新規作成**

以下の内容で `.github/workflows/reusable--kubernetes-hydrator.yaml` を作成する。

```yaml
name: 'Reusable - Kubernetes Hydrator'

on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
        description: 'Target environment for hydration (e.g., k3d)'
      services:
        required: true
        type: string
        description: 'JSON array of service names to hydrate (e.g. ["coredns","cilium"])'
      app-id:
        required: true
        type: string
        description: 'GitHub App ID for authentication'
    secrets:
      private-key:
        required: true
        description: 'GitHub App private key for authentication'

concurrency:
  group: kubernetes-hydrate-${{ github.event.pull_request.number || github.ref }}-${{ inputs.environment }}
  cancel-in-progress: false

jobs:
  hydrate:
    name: 'Hydrate'
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@v3.1.1
        with:
          app-id: ${{ inputs.app-id }}
          private-key: ${{ secrets.private-key }}
          owner: ${{ github.repository_owner }}

      - name: Get PR information
        id: pr-info
        uses: jwalton/gh-find-current-pr@v1
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          state: all
        continue-on-error: true

      - name: Checkout
        uses: actions/checkout@v6
        with:
          token: ${{ steps.app-token.outputs.token }}
          ref: ${{ github.head_ref }}
          fetch-depth: 0

      - name: Setup aqua
        uses: aquaproj/aqua-installer@v4.0.4
        with:
          aqua_version: v2.48.2
        env:
          AQUA_CONFIG: .github/aqua.yaml

      - name: Hydrate changed components
        env:
          SERVICES_JSON: ${{ inputs.services }}
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: |
          set -euo pipefail
          for svc in $(echo "$SERVICES_JSON" | jq -r '.[]'); do
            make -C kubernetes hydrate-component COMPONENT="$svc" ENV="${{ inputs.environment }}"
          done

      - name: Hydrate index
        env:
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: make -C kubernetes hydrate-index ENV=${{ inputs.environment }}

      - name: Commit and push hydrated manifests
        id: auto-commit
        uses: stefanzweifel/git-auto-commit-action@v7
        with:
          commit_message: 'chore(kubernetes/manifests/${{ inputs.environment }}): hydrate manifests'
          commit_options: '--signoff'
          file_pattern: 'kubernetes/manifests/${{ inputs.environment }}/'
          commit_user_name: 'github-actions[bot]'
          commit_user_email: 'github-actions[bot]@users.noreply.github.com'

      - name: Compute index diff
        id: index-diff
        if: steps.pr-info.outputs.number != ''
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          ENV: ${{ inputs.environment }}
        run: |
          set -euo pipefail
          diff=$(git diff "$BASE_SHA" HEAD -- \
            "kubernetes/manifests/$ENV/kustomization.yaml" \
            "kubernetes/manifests/$ENV/00-namespaces/" || true)
          {
            echo 'diff<<EOF'
            echo "$diff"
            echo 'EOF'
          } >> "$GITHUB_OUTPUT"
          if [ -n "$diff" ]; then
            echo "has-diff=true" >> "$GITHUB_OUTPUT"
          else
            echo "has-diff=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Comment index diff
        if: steps.index-diff.outputs.has-diff == 'true' && steps.pr-info.outputs.number != ''
        uses: thollander/actions-comment-pull-request@v3.0.1
        with:
          message: |
            ## Kubernetes Index Diff

            **Environment**: `${{ inputs.environment }}`

            ```diff
            ${{ steps.index-diff.outputs.diff }}
            ```
          comment-tag: 'kubernetes-index-${{ inputs.environment }}'
          mode: upsert
          pr-number: ${{ steps.pr-info.outputs.number }}
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
        continue-on-error: true
```

- [ ] **Step 2: actionlint で構文チェック**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
actionlint .github/workflows/reusable--kubernetes-hydrator.yaml
```

Expected: エラー・警告なし（終了コード 0）

- [ ] **Step 3: yamllint でフォーマットチェック**

Run:
```bash
yamllint .github/workflows/reusable--kubernetes-hydrator.yaml
```

Expected: エラーなし（既存ワークフローと同程度の基準。warning は許容）

- [ ] **Step 4: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git add .github/workflows/reusable--kubernetes-hydrator.yaml
git commit -s -m "feat(workflows): add reusable kubernetes-hydrator

Per-environment hydrate job with concurrency lock to serialize
commits and avoid push races. Posts a single kubernetes-index-\$(env)
PR comment when top-level kustomization.yaml or 00-namespaces/
change.

Refs: #190"
```

---

## Task 7: `reusable--kubernetes-builder.yaml` を diff 専用に縮小

**Files:**
- Modify: `.github/workflows/reusable--kubernetes-builder.yaml`（既存ファイル全体を置換）

- [ ] **Step 1: ファイル全体を置換**

既存のファイル内容を以下で置換する。

```yaml
name: 'Reusable - Kubernetes Builder'

on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
        description: 'Service name for identification'
      environment:
        required: true
        type: string
        description: 'Target environment (e.g., k3d)'
      app-id:
        required: true
        type: string
        description: 'GitHub App ID for authentication'
    secrets:
      private-key:
        required: true
        description: 'GitHub App private key for authentication'

jobs:
  kustomize-diff:
    name: 'Kustomize Diff'
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@v3.1.1
        with:
          app-id: ${{ inputs.app-id }}
          private-key: ${{ secrets.private-key }}
          owner: ${{ github.repository_owner }}

      - name: Get PR information
        id: pr-info
        uses: jwalton/gh-find-current-pr@v1
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          state: all
        continue-on-error: true

      - name: Checkout
        uses: actions/checkout@v6
        with:
          token: ${{ steps.app-token.outputs.token }}
          ref: ${{ github.head_ref }}
          fetch-depth: 0

      - name: Kubernetes Diff
        uses: panicboat/deploy-actions/kubernetes@main
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          service-name: ${{ inputs.service-name }}
          environment: ${{ inputs.environment }}
          path: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}
          pr-number: ${{ steps.pr-info.outputs.number }}
```

変更点の要約:
- `Hydrate manifests` ステップ削除（hydrator に移動）
- `Commit and push hydrated manifests` ステップ削除（hydrator に移動）
- `Setup aqua` ステップ削除（diff は kustomize build 不要、composite action 側の kustomize-action が担う）
- `permissions.contents: write` → `read`（push しないため）
- `path` を `kubernetes/manifests/${{ inputs.environment }}` → `kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}` に変更

- [ ] **Step 2: actionlint / yamllint チェック**

Run:
```bash
actionlint .github/workflows/reusable--kubernetes-builder.yaml
yamllint .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: エラーなし

- [ ] **Step 3: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git add .github/workflows/reusable--kubernetes-builder.yaml
git commit -s -m "refactor(workflows): shrink kubernetes-builder to diff-only

Remove hydrate/commit/push steps (moved to kubernetes-hydrator).
Narrow diff path to per-component subdirectory so each PR comment
shows only that component's changes.

Refs: #190"
```

---

## Task 8: `auto-label--deploy-trigger.yaml` を更新

**Files:**
- Modify: `.github/workflows/auto-label--deploy-trigger.yaml`（`kubernetes-targets-group`, `deploy-kubernetes-hydrate` ジョブ追加、`deploy-kubernetes` の `needs` 更新）

- [ ] **Step 1: `kubernetes-targets-group` ジョブを追加**

既存 `deploy-terragrunt:` ジョブの直前（L54 の直前）に以下を**挿入**する。

```yaml
  kubernetes-targets-group:
    name: 'Group Kubernetes Targets by Environment'
    needs: deploy-trigger
    if: |
      needs.deploy-trigger.outputs.has-targets == 'true' &&
      contains(needs.deploy-trigger.outputs.targets, '"stack":"kubernetes"')
    runs-on: ubuntu-latest
    outputs:
      environments: ${{ steps.group.outputs.environments }}
    steps:
      - name: Group by environment
        id: group
        env:
          TARGETS: ${{ needs.deploy-trigger.outputs.targets }}
        run: |
          set -euo pipefail
          grouped=$(echo "$TARGETS" | jq -c '
            [.[] | select(.stack == "kubernetes")]
            | group_by(.environment)
            | map({environment: .[0].environment, services: [.[].service]})
          ')
          echo "environments=$grouped" >> "$GITHUB_OUTPUT"

  deploy-kubernetes-hydrate:
    name: 'Hydrate Kubernetes (${{ matrix.env.environment }})'
    needs: kubernetes-targets-group
    strategy:
      matrix:
        env: ${{ fromJson(needs.kubernetes-targets-group.outputs.environments) }}
      fail-fast: false
    uses: ./.github/workflows/reusable--kubernetes-hydrator.yaml
    with:
      environment: ${{ matrix.env.environment }}
      services: ${{ toJson(matrix.env.services) }}
      app-id: ${{ vars.APP_ID }}
    secrets:
      private-key: ${{ secrets.APP_PRIVATE_KEY }}

```

- [ ] **Step 2: `deploy-kubernetes` の `needs` を更新**

既存 L78 の `needs: deploy-trigger` を以下に置換:

```yaml
    needs: [deploy-trigger, deploy-kubernetes-hydrate]
```

- [ ] **Step 3: `deployment-summary` の `needs` を更新**

既存 L99 の `needs: [deploy-trigger, deploy-terragrunt, deploy-kubernetes]` を以下に置換:

```yaml
    needs: [deploy-trigger, deploy-terragrunt, deploy-kubernetes-hydrate, deploy-kubernetes]
```

また、L111 の直後（`echo "Kubernetes Job Status: ${{ needs.deploy-kubernetes.result }}"` の直後）に以下を追加:

```yaml
          echo "Kubernetes Hydrate Job Status: ${{ needs.deploy-kubernetes-hydrate.result }}"
```

- [ ] **Step 4: actionlint / yamllint チェック**

Run:
```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
actionlint .github/workflows/auto-label--deploy-trigger.yaml
yamllint .github/workflows/auto-label--deploy-trigger.yaml
```

Expected: エラーなし

- [ ] **Step 5: jq 変換のローカル検証**

Run:
```bash
echo '[{"service":"coredns","environment":"k3d","stack":"kubernetes"},{"service":"cilium","environment":"k3d","stack":"kubernetes"},{"service":"vpc","environment":"develop","stack":"terragrunt"}]' | \
  jq -c '[.[] | select(.stack == "kubernetes")] | group_by(.environment) | map({environment: .[0].environment, services: [.[].service]})'
```

Expected:
```json
[{"environment":"k3d","services":["coredns","cilium"]}]
```

- [ ] **Step 6: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git add .github/workflows/auto-label--deploy-trigger.yaml
git commit -s -m "feat(workflows): orchestrate hydrate-before-diff for kubernetes

Add kubernetes-targets-group to regroup matrix targets by
environment, then run deploy-kubernetes-hydrate before
deploy-kubernetes. Diff jobs wait for the single hydrate
commit to land, eliminating the push race.

Refs: #190"
```

---

## Task 9: README を更新

**Files:**
- Modify: `README.md`（L20）
- Modify: `README-ja.md`（L20）
- Modify: `kubernetes/README.md`（L127, L172）

- [ ] **Step 1: `README.md` L20 を更新**

Edit `README.md`:
- Old: `│   └── manifests/k3d/         # Rendered manifests for the k3d cluster`
- New: `│   └── manifests/k3d/         # Rendered manifests (per-component subdirectories)`

- [ ] **Step 2: `README-ja.md` L20 を更新**

Edit `README-ja.md`:
- Old: `│   └── manifests/k3d/         # Rendered manifests for the k3d cluster`
- New: `│   └── manifests/k3d/         # Rendered manifests (per-component subdirectories)`

- [ ] **Step 3: `kubernetes/README.md` L127 を更新**

Edit `kubernetes/README.md`:
- Old: `- FluxCD が `manifests/k3d` を同期`
- New: `- FluxCD が `manifests/k3d`（コンポーネント別サブディレクトリ）を同期`

- [ ] **Step 4: `kubernetes/README.md` L172 を更新して新ターゲットを追加**

Edit `kubernetes/README.md`:
- Old:
  ```
  make hydrate         # マニフェスト生成 (components -> manifests)
  make gateway-install # Gateway API CRDs
  ```
- New:
  ```
  make hydrate                              # 全コンポーネント生成 (components -> manifests)
  make hydrate-component COMPONENT=<name> ENV=<env>  # 単一コンポーネントのみ再生成（CI 用）
  make hydrate-index ENV=<env>              # 集約ファイル再生成 + orphan 削除（CI 用）
  make gateway-install # Gateway API CRDs
  ```

- [ ] **Step 5: Commit**

```bash
git add README.md README-ja.md kubernetes/README.md
git commit -s -m "docs(kubernetes): document per-component hydrate targets

Add usage for hydrate-component and hydrate-index, and describe
the per-component subdirectory layout under manifests/\$(env)/.

Refs: #190"
```

---

## Task 10: Draft PR を作成

**Files:** なし（GitHub 上の操作のみ）

- [ ] **Step 1: worktree からブランチを push**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/fix-kubernetes-hydrate-race-190
git push -u origin HEAD
```

- [ ] **Step 2: Draft PR を作成**

```bash
gh pr create --draft --title "fix(kubernetes-builder): separate hydrate from diff to resolve race condition" --body "$(cat <<'EOF'
## Summary

- `reusable--kubernetes-hydrator.yaml` を新設し、env 単位 matrix + concurrency で hydrate を直列化
- `kubernetes/manifests/\$(env)/` をコンポーネントサブディレクトリ構造に変更し、diff スコープをコンポーネント単位に絞る
- `Makefile` に `hydrate-component`, `hydrate-index` ターゲットを追加、`set -euo pipefail` でエラー伝播を保証
- 詳細は [spec](docs/superpowers/specs/2026-04-25-kubernetes-builder-race-condition-design.md) 参照

Closes #190

## Test plan

- [ ] 単一コンポーネント変更の PR でコンポーネントコメントにそのコンポーネントの diff のみが出ること
- [ ] 複数コンポーネント同時変更の PR で push 競合が発生せず、全コンポーネントコメントが正しく投稿されること
- [ ] helmfile 意図的エラー（不正 values）を含む PR で auto-commit が走らないこと
- [ ] コンポーネント追加・削除の PR で \`kubernetes-index-\$(env)\` コメントが投稿されること
- [ ] ローカルで \`make phase1 && make phase2 && make phase3\` が成功すること
- [ ] \`make hydrate ENV=k3d\` の出力（cert 除く）が origin/main と実質一致すること
EOF
)"
```

Expected: Draft PR が作成され、URL が出力される。

- [ ] **Step 3: 手動検証シナリオの実施**

PR 作成後、上記 Test plan の各項目を手動で検証する。各シナリオで問題があれば追加 commit で修正。

---

## Verification Checklist（マージ前最終確認）

- [ ] `make hydrate-component COMPONENT=<any> ENV=k3d` が成功
- [ ] `make hydrate-index ENV=k3d` が成功し orphan cleanup が動作する
- [ ] `make hydrate ENV=k3d` が全 11 コンポーネントを subdirectory 構造で生成する
- [ ] `kustomize build kubernetes/manifests/k3d` がエラーなく完了する
- [ ] `actionlint .github/workflows/*.yaml` でエラーなし
- [ ] `yamllint .github/workflows/*.yaml` でエラーなし
- [ ] テスト PR で 3 つ以上のコンポーネントを同時変更し、push 競合が発生しないこと
- [ ] テスト PR で各コンポーネント PR コメントに当該コンポーネントの diff のみが表示されること
- [ ] テスト PR で `kubernetes-index-k3d` コメントが（index 変更時のみ）投稿されること
- [ ] `make phase1 && make phase2 && make phase3` ローカル成功
