# Kubernetes Builder: Race Condition Fix by Hydrate/Diff Separation

**Date**: 2026-04-25
**Issue**: [panicboat/platform#190](https://github.com/panicboat/platform/issues/190)
**Status**: Proposed

## Background

`reusable--kubernetes-builder.yaml` は `strategy.matrix` でコンポーネントごとに並列実行されるが、`kubernetes/Makefile` の `hydrate` ターゲットが環境全体を一括再生成する設計のため、複数コンポーネントを同時変更した PR で以下の問題が発生する。

1. **Hydrate のレースコンディション**: 並列ジョブが同じブランチ上で `rm -rf` → 全コンポーネント再生成 → auto-commit → push を同時実行し、ファイル書き込みや push で競合する
2. **Diff スコープの不一致**: `path: kubernetes/manifests/{environment}` で環境全体を比較するため、各コンポーネントの PR コメントに他コンポーネントの diff が混入する
3. **Hydrate のエラーハンドリング不足**: helmfile/kustomize が失敗しても `make hydrate` が success で終了し、壊れたマニフェスト（空または部分的）が auto-commit される（PR #188 で 225 ファイル削除を発生させた実例あり）
4. **Concurrency の不足**: workflow 単位の concurrency では matrix 展開後のジョブ間を直列化できない

## Goals

- 複数コンポーネント同時変更時の push 競合を構造的に解消する
- コンポーネント単位の PR コメントにそのコンポーネントの diff のみを表示する
- helmfile/kustomize 失敗時に壊れたマニフェストを auto-commit しない
- 既存のローカル開発ワークフロー（`make hydrate`, `make phase1..4`）との互換性を維持する

## Non-Goals

- `panicboat/deploy-actions/kubernetes` および `label-resolver` の改修
- kubernetes 以外の stack（terragrunt）のワークフロー変更
- label-dispatcher の挙動調査・改善
- `phase3` デプロイ順の抜本見直し（path 参照更新のみ行う）

## Architecture

### Before

```
PR: kubernetes/components/{coredns,cilium}/ を変更
  ↓
label-resolver → targets: [{svc:coredns,env:k3d}, {svc:cilium,env:k3d}]
  ↓ strategy.matrix（並列）
┌────────────────────────┐  ┌────────────────────────┐
│ Job: coredns:k3d       │  │ Job: cilium:k3d        │
│ 1. make hydrate ENV=k3d│  │ 1. make hydrate ENV=k3d│ ← 全環境再生成
│ 2. auto-commit + push  │  │ 2. auto-commit + push  │ ← 競合
│ 3. diff (全体)         │  │ 3. diff (全体)         │ ← 他コンポ混入
└────────────────────────┘  └────────────────────────┘
```

### After

```
PR: kubernetes/components/{coredns,cilium}/ を変更
  ↓
label-resolver → targets: [{svc:coredns,env:k3d}, {svc:cilium,env:k3d}]
  ↓
kubernetes-targets-group (jq) → kubernetes-environments:
  [{environment:"k3d", services:["coredns","cilium"]}]
  ↓
┌─────────────────────────────────────────────────────┐
│ deploy-kubernetes-hydrate (env 単位の matrix)        │
│ concurrency: kubernetes-hydrate-${PR}-${env}         │
│   (cancel-in-progress: false)                        │
│                                                       │
│ k3d:                                                  │
│   for svc in [coredns, cilium]:                      │
│     make hydrate-component COMPONENT=$svc ENV=k3d    │
│   make hydrate-index ENV=k3d                         │
│   git-auto-commit-action                             │
│   git diff base..head -- manifests/k3d/kustomization.yaml│
│                       manifests/k3d/00-namespaces/   │
│     → PR comment (tag: kubernetes-index-k3d)         │
└─────────────────────────────────────────────────────┘
  ↓ needs
┌────────────────────────┐  ┌────────────────────────┐
│ deploy-kubernetes      │  │ deploy-kubernetes      │
│ (matrix: coredns:k3d)  │  │ (matrix: cilium:k3d)   │
│ path: manifests/k3d/   │  │ path: manifests/k3d/   │
│       coredns          │  │       cilium           │
│ → tag: kubernetes-     │  │ → tag: kubernetes-     │
│     coredns-k3d        │  │     cilium-k3d         │
└────────────────────────┘  └────────────────────────┘
```

### Issue 対応表

| Issue | 解決機構 |
|-------|---------|
| #1 Hydrate レースコンディション | hydrate ジョブ 1 本化 + env 単位 concurrency による直列化 |
| #2 Diff スコープ不一致 | コンポーネントサブディレクトリ構造 + path 単位絞込 |
| #3 Hydrate エラーハンドリング不足 | `set -euo pipefail` + 各コマンドの戻り値検査 |
| #4 Concurrency 不足 | ジョブ単位の concurrency（matrix の外側） |

## Manifests Layout

`kubernetes/manifests/{env}/` をフラットファイル構造からコンポーネントサブディレクトリ構造に変更する。

### Before

```
kubernetes/manifests/k3d/
├── kustomization.yaml        # resources: [cilium.yaml, coredns.yaml, ..., 00-namespaces.yaml]
├── 00-namespaces.yaml
├── cilium.yaml
├── coredns.yaml
└── ...
```

### After

```
kubernetes/manifests/k3d/
├── kustomization.yaml            # resources: [./00-namespaces, ./cilium, ./coredns, ...]
├── 00-namespaces/
│   ├── kustomization.yaml        # resources: [namespaces.yaml]
│   └── namespaces.yaml           # 全コンポーネントの namespace.yaml を連結
├── cilium/
│   ├── kustomization.yaml        # resources: [manifest.yaml]
│   └── manifest.yaml             # helmfile template + kustomize build 出力
├── coredns/
│   ├── kustomization.yaml
│   └── manifest.yaml
└── ... (11 コンポーネント分)
```

**設計根拠**:
- 各コンポーネントが自己完結したディレクトリになり、`deploy-actions/kubernetes` の `path` にそのまま渡せる
- トップ `kustomization.yaml` がサブディレクトリを参照するため `kubectl apply -k manifests/k3d` は変更不要
- `_diff/` のような特殊ディレクトリを作らず、kustomize 慣例に沿った自然な階層

## Makefile Changes

### New target: `hydrate-component`

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
	# cert revert (既存ロジックをコンポーネント単位で適用)
	if git ls-files --error-unmatch "$$out_dir/manifest.yaml" >/dev/null 2>&1; then \
		if git diff --quiet -I '^[[:space:]]*(ca\.crt|ca\.key|tls\.crt|tls\.key|caBundle):' -- "$$out_dir/manifest.yaml"; then \
			git checkout -- "$$out_dir/manifest.yaml"; \
		fi; \
	fi
```

**挙動**:
- `components/$(COMPONENT)/$(ENV)/` に helmfile.yaml も kustomization/ もない場合、空の `manifest.yaml` が生成される（hydrate-index の cleanup で処理される）
- helmfile/kustomize いずれかが失敗すると `set -euo pipefail` により非ゼロ終了
- cert 規則の差分のみの場合は `git checkout` で戻す（helm が実行毎に再生成するため）

### New target: `hydrate-index`

```makefile
.PHONY: hydrate-index
hydrate-index: ## Regenerate manifests/$(ENV) index and cleanup orphans (usage: make hydrate-index ENV=k3d)
	@set -euo pipefail; \
	env_dir="manifests/$(ENV)"; \
	mkdir -p "$$env_dir/00-namespaces"; \
	# namespaces.yaml: components/*/namespace.yaml を連結
	find components -maxdepth 2 -name namespace.yaml | sort | \
		xargs -I{} sh -c 'echo "---"; cat "{}"' > "$$env_dir/00-namespaces/namespaces.yaml"; \
	printf "resources:\n  - namespaces.yaml\n" > "$$env_dir/00-namespaces/kustomization.yaml"; \
	# Orphan 削除: components/X/$(ENV)/ が存在しないディレクトリを manifests/$(ENV)/ から削除
	for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null); do \
		name=$$(basename "$$dir"); \
		[ "$$name" = "00-namespaces" ] && continue; \
		if [ ! -d "components/$$name/$(ENV)" ]; then \
			rm -rf "$$dir"; \
		fi; \
	done; \
	# トップ kustomization.yaml 再生成
	{ \
		echo "resources:"; \
		echo "  - ./00-namespaces"; \
		for dir in $$(ls -d "$$env_dir"/*/ 2>/dev/null | grep -v "/00-namespaces/" | sort); do \
			echo "  - ./$$(basename $$dir)"; \
		done; \
	} > "$$env_dir/kustomization.yaml"
```

### Refactored target: `hydrate`

```makefile
.PHONY: hydrate
hydrate: ## Hydrate all components (usage: make hydrate ENV=k3d)
	@echo "$(BLUE)💧 Hydrating manifests for $(ENV)...$(NC)"
	@rm -rf manifests/$(ENV)/*
	@mkdir -p manifests/$(ENV)
	@for component in $$(ls -d components/*/$(ENV) 2>/dev/null | cut -d'/' -f2 | sort -u); do \
		$(MAKE) hydrate-component COMPONENT=$$component ENV=$(ENV); \
	done
	@$(MAKE) hydrate-index ENV=$(ENV)
	@echo "$(GREEN)✅ Manifests hydrated$(NC)"
```

### Existing target updates

`phase3` 系で path を更新:

| 行 | Before | After |
|----|--------|-------|
| L141 | `kubectl apply -f manifests/k3d/cilium.yaml` | `kubectl apply -f manifests/k3d/cilium/manifest.yaml` |
| L211 | `kubectl apply -f manifests/k3d/00-namespaces.yaml` | `kubectl apply -f manifests/k3d/00-namespaces/namespaces.yaml` |
| L214 | `kubectl apply ... -f manifests/k3d/prometheus-operator.yaml` | `kubectl apply ... -f manifests/k3d/prometheus-operator/manifest.yaml` |
| L217 | `kubectl apply ... -k manifests/k3d` | 変更不要 |

## Workflow Changes

### New: `reusable--kubernetes-hydrator.yaml`

```yaml
name: 'Reusable - Kubernetes Hydrator'

on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
      services:
        required: true
        type: string
        description: 'JSON array of service names (e.g. ["coredns","cilium"])'
      app-id:
        required: true
        type: string
    secrets:
      private-key:
        required: true

concurrency:
  group: kubernetes-hydrate-${{ github.event.pull_request.number || github.ref }}-${{ inputs.environment }}
  cancel-in-progress: false

jobs:
  hydrate:
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
        if: steps.index-diff.outputs.has-diff == 'true'
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

### Modified: `reusable--kubernetes-builder.yaml`

Hydrate ステップ・commit ステップ・Setup aqua ステップを削除し、diff 専用に縮小。`path` をコンポーネントディレクトリに変更。

```yaml
name: 'Reusable - Kubernetes Builder'

on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
      environment:
        required: true
        type: string
      app-id:
        required: true
        type: string
    secrets:
      private-key:
        required: true

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

### Modified: `auto-label--deploy-trigger.yaml`

`deploy-trigger` の後に env 単位グルーピング、hydrate、diff ジョブを追加する。

```yaml
jobs:
  deploy-trigger: (既存のまま)

  # NEW: targets を環境ごとにグルーピング
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

  # NEW: env 単位で hydrate
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

  # MODIFIED: hydrate 完了後に diff
  deploy-kubernetes:
    name: 'Deploy Kubernetes (${{ matrix.target.service }}:${{ matrix.target.environment }})'
    needs: [deploy-trigger, deploy-kubernetes-hydrate]
    if: |
      needs.deploy-trigger.outputs.has-targets == 'true' &&
      contains(needs.deploy-trigger.outputs.targets, '"stack":"kubernetes"')
    strategy:
      matrix:
        target: ${{ fromJson(needs.deploy-trigger.outputs.targets) }}
        exclude:
          - target:
              stack: terragrunt
      fail-fast: false
    uses: ./.github/workflows/reusable--kubernetes-builder.yaml
    with:
      service-name: ${{ matrix.target.service }}
      environment: ${{ matrix.target.environment }}
      app-id: ${{ vars.APP_ID }}
    secrets:
      private-key: ${{ secrets.APP_PRIVATE_KEY }}

  deployment-summary:
    needs: [deploy-trigger, deploy-terragrunt, deploy-kubernetes]
    (既存のまま)
```

## Error Handling

| レイヤ | 失敗時の挙動 |
|--------|------|
| `make hydrate-component` | `set -euo pipefail` により helmfile/kustomize 失敗で非ゼロ終了 → "Hydrate" ステップが fail → auto-commit は実行されない |
| `make hydrate-index` | 同上 |
| `git-auto-commit-action` push 失敗 | concurrency により単一ジョブしか走らないので競合は発生しない想定。他経路（手動 push）と競合した場合はジョブ fail |
| Index diff コメント投稿失敗 | `continue-on-error: true`（既存 kubernetes-builder と同じ方針） |
| `deploy-kubernetes` | hydrate fail → `needs` によりスキップ |

## Edge Cases

**コンポーネント削除**:
- label-dispatcher が `deploy:xxx` を付与するか否かに関わらず、`hydrate-index` の cleanup が `components/xxx/{env}/` 不在を検知して `manifests/{env}/xxx/` を削除する
- ラベル付与された場合は `hydrate-component` が先に走るが、`components/xxx/{env}/` 不在なら空 `manifest.yaml` が生成されるだけで、後続の cleanup で削除される

**コンポーネント追加**:
- label-dispatcher が `deploy:xxx` を付与 → targets に含まれる → `hydrate-component` で生成 → `hydrate-index` がトップ `kustomization.yaml` にリストアップ

**PR に kubernetes 変更が含まれない**:
- `if: contains(targets, '"stack":"kubernetes"')` により kubernetes-targets-group, hydrate, diff ジョブすべてスキップ

**aqua ポリシー違反（PR #188 の再発ケース）**:
- `aqua-installer` が fail → 後続スキップ → 壊れたマニフェストが commit されない
- helmfile が `exit 1` した場合も `set -euo pipefail` により fail

**PR の rapid push**:
- `concurrency.cancel-in-progress: false` により前回の hydrate ジョブの push 完了を待ってから次を実行
- 最新の hydrate 結果が必ず残る

## Testing

### ユニット相当（ローカル検証）

- `make hydrate-component COMPONENT=cilium ENV=k3d`
  - `manifests/k3d/cilium/{manifest.yaml,kustomization.yaml}` が生成される
  - 再実行で差分なし（冪等）
- `make hydrate-index ENV=k3d`
  - トップ `kustomization.yaml` に全コンポーネントがリストされる
  - `00-namespaces/{namespaces.yaml,kustomization.yaml}` が生成される
  - components/ 未登録のディレクトリが削除される（orphan cleanup）
- `make hydrate ENV=k3d`
  - 既存出力と構造以外の差分がほぼゼロ（cert 除く）

### 統合テスト（テスト PR）

- 単一コンポーネント変更（coredns のみ）
- 複数コンポーネント同時変更（coredns + cilium）: push 競合が発生しないこと
- コンポーネント追加・削除: トップ `kustomization.yaml` が追従すること
- helmfile 意図的エラー（不正な values）: auto-commit が走らないこと
- PR コメント: 各コンポーネント PR コメントにそのコンポーネントの diff のみが表示されること

### Regression

- `make phase1 && make phase2 && make phase3` で k3d クラスタ構築成功
- `clusters/k3d/kustomization.yaml` の `../../manifests/k3d` 参照が正しく機能

## Migration Plan

1 PR 内で段階的に実装する。

1. Makefile 新ターゲット追加（`hydrate-component`, `hydrate-index`）。`hydrate` は旧実装のまま残す
2. `make hydrate-component` / `make hydrate-index` をローカルで実行し、意図通り動くことを検証
3. `hydrate` を新実装に切り替え、ローカルで `make hydrate ENV=k3d` を実行
4. `kubernetes/manifests/k3d/` をサブディレクトリ構造に一括変換してコミット
5. Makefile phase3 の path 参照更新（L141, L211, L214）
6. `reusable--kubernetes-hydrator.yaml` 新規作成
7. `reusable--kubernetes-builder.yaml` 縮小
8. `auto-label--deploy-trigger.yaml` 更新（`kubernetes-targets-group`, `deploy-kubernetes-hydrate` 追加、`deploy-kubernetes` の `needs` 更新）
9. `kubernetes/README.md`, `README.md`, `README-ja.md` の構造説明更新
10. テスト PR で動作確認

## Success Criteria

- 複数コンポーネント同時変更時に push 競合が発生しない
- 各コンポーネント PR コメントにそのコンポーネントの diff のみが表示される
- helmfile/kustomize 失敗時に壊れたマニフェストが auto-commit されない
- `make phase1..phase4` で k3d クラスタ構築が成功する
- `make hydrate ENV=k3d` の出力（cert 除く）が既存と一致する

## Scope

### In Scope (panicboat/platform)

- `kubernetes/Makefile`: `hydrate-component`, `hydrate-index` ターゲット追加、`hydrate` 再実装、phase3 path 更新
- `.github/workflows/reusable--kubernetes-hydrator.yaml`: 新規作成
- `.github/workflows/reusable--kubernetes-builder.yaml`: diff 専用に縮小
- `.github/workflows/auto-label--deploy-trigger.yaml`: `kubernetes-targets-group`, `deploy-kubernetes-hydrate` 追加、`deploy-kubernetes` の `needs` 更新
- `kubernetes/manifests/k3d/`: サブディレクトリ構造に一括変換
- `kubernetes/README.md`, `README.md`, `README-ja.md`: 構造説明更新

### Out of Scope

- `panicboat/deploy-actions/kubernetes` および `label-resolver` の改修（jq 変換で吸収）
- kubernetes 以外の stack（terragrunt）のワークフロー変更
- label-dispatcher のコンポーネント削除検知挙動の調査・改善
- `phase3` デプロイ順の抜本見直し
