# `kustomize-diff` De-sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `panicboat/panicboat-actions` の composite action `kustomize-diff/` を廃止し、参照している `platform` と `monorepo` の呼び出し元ワークフローへ直接インライン化する。

**Architecture:** `kustomize-diff/action.yaml` の 5 ステップを、呼び出し元の `reusable--kubernetes-builder.yaml` に機械的に展開する。`inputs.*` への参照は呼び出し元で既に手元にある値（`steps.app-token.outputs.token` 等）に置き換える。3 リポジトリ（platform → monorepo → panicboat-actions）を順に処理し、最後の削除は前 2 つの動作確認が済んでから行う。

**Tech Stack:** GitHub Actions（composite action → inline steps）、`actionlint`、`int128/kustomize-action`、`int128/diff-action`、`thollander/actions-comment-pull-request`。

**Spec:** `docs/superpowers/specs/2026-08-21-kustomize-diff-deshare-design.md`

## Global Constraints

- upstream action の SHA pin はすべて既存の `kustomize-diff/action.yaml` からそのまま転記する（バージョンを上げない）
- `has-diff` output は job レベルでは export しない（呼び出し元での参照が無いことを確認済み）
- 各リポジトリでの作業開始前に、CLAUDE.md の Workflow に従い worktree / branch の進め方をユーザーに確認する
- コミットは `-s`（`--signoff`）付き、`Co-Authored-By` は付けない
- PR は `gh pr create --draft`

---

## File Structure

- Modify: `platform/.github/workflows/reusable--kubernetes-builder.yaml`
- Modify: `monorepo/.github/workflows/reusable--kubernetes-builder.yaml`
- Delete: `panicboat-actions/kustomize-diff/`（ディレクトリごと）
- Modify: `panicboat-actions/README.md`

---

# Task 1: platform — `Kustomize Diff` ステップのインライン化

**Files:**
- Modify: `.github/workflows/reusable--kubernetes-builder.yaml`

**Interfaces:**
- Consumes: 既存の job 内で既に定義済みの `steps.app-token.outputs.token`、`steps.pr-info.outputs.number`、job inputs `service-name` / `environment`
- Produces: `panicboat/panicboat-actions/kustomize-diff` への参照が platform から消える。Task 3 の削除判断がこれに依存する

- [ ] **Step 1: worktree の進め方を確認**

CLAUDE.md の Workflow に従い、worktree を使うか・新規ブランチのみか・現在のブランチで進めるかをユーザーに確認する。

- [ ] **Step 2: worktree を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git fetch origin main --quiet
git worktree add -b feat/kustomize-diff-inline-platform .claude/worktrees/feat-kustomize-diff-inline-platform origin/main
```

- [ ] **Step 3: 現状のステップを確認**

```bash
cd .claude/worktrees/feat-kustomize-diff-inline-platform
grep -n "Kustomize Diff" -A10 .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: `uses: panicboat/panicboat-actions/kustomize-diff@fd41cb7fb30ee0b650acedb9f504cbff719844a6 # main` を含む 1 ステップが表示される

- [ ] **Step 4: ステップを置き換える**

`.github/workflows/reusable--kubernetes-builder.yaml` の以下のブロックを:

```yaml
      - name: Kustomize Diff
        uses: panicboat/panicboat-actions/kustomize-diff@fd41cb7fb30ee0b650acedb9f504cbff719844a6 # main
        with:
          token: ${{ steps.app-token.outputs.token }}
          service-name: ${{ inputs.service-name }}
          environment: ${{ inputs.environment }}
          path: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}
          pr-number: ${{ steps.pr-info.outputs.number }}
```

以下に置き換える:

```yaml
      - name: Checkout base ref
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: base
          token: ${{ steps.app-token.outputs.token }}

      - name: Build head manifests
        id: kustomize-head
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          kustomization: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}/kustomization.yaml
          write-individual-files: true

      - name: Build base manifests
        id: kustomize-base
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          base-directory: base
          kustomization: kubernetes/manifests/${{ inputs.environment }}/${{ inputs.service-name }}/kustomization.yaml
          write-individual-files: true

      - name: Diff manifests
        id: diff
        uses: int128/diff-action@77a301a80335bebb9abb2d28a3dacfa844105395 # v2.28.0
        with:
          base: ${{ steps.kustomize-base.outputs.directory }}
          head: ${{ steps.kustomize-head.outputs.directory }}

      - name: Comment PR
        if: steps.pr-info.outputs.number != ''
        uses: thollander/actions-comment-pull-request@24bffb9b452ba05a4f3f77933840a6a841d1b32b # v3.0.1
        with:
          message: |
            ## Kustomize Diff

            **Service**: `${{ inputs.service-name }}`
            **Environment**: `${{ inputs.environment }}`

            ${{ steps.diff.outputs.comment-body || 'No changes' }}
          comment-tag: "kubernetes-${{ inputs.service-name }}-${{ inputs.environment }}"
          mode: upsert
          pr-number: ${{ steps.pr-info.outputs.number }}
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
          reactions: ${{ steps.diff.outputs.has-diff == 'true' && 'rocket' || '' }}
        continue-on-error: true
```

- [ ] **Step 5: `panicboat-actions` への参照が残っていないことを確認**

```bash
grep -n "panicboat-actions/kustomize-diff" .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: 出力なし（何もヒットしない）

- [ ] **Step 6: actionlint で構文検証**

```bash
actionlint .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: エラーなし

- [ ] **Step 7: コミット**

```bash
git add .github/workflows/reusable--kubernetes-builder.yaml
git commit -s -m "refactor(ci): inline the kustomize-diff composite action"
```

- [ ] **Step 8: 検証用の一時的な manifest 変更を加える**

ワークフロー変更だけでは `label-resolver` が `kubernetes` stack を検出せず `Kustomize Diff` ジョブが起動しない。既にレンダリング済みの manifest に無害な annotation を追記して、実際に diff を発生させる。

```bash
grep -n "annotations:" -A3 kubernetes/manifests/production/external-dns/manifest.yaml | head -10
```

上記で見つかった Deployment の `metadata.annotations`（無ければ `spec.template.metadata.annotations`）に 1 行追記する:

```yaml
    verify.panicboat/kustomize-diff-check: "true"
```

- [ ] **Step 9: 一時変更をコミットして push**

```bash
git add kubernetes/manifests/production/external-dns/manifest.yaml
git commit -s -m "test: trigger kustomize-diff verification"
git push -u origin HEAD
```

- [ ] **Step 10: Draft PR を作成**

```bash
gh pr create --draft \
  --title "refactor(ci): inline the kustomize-diff composite action" \
  --body "$(cat <<'EOF'
Design: docs/superpowers/specs/2026-08-21-kustomize-diff-deshare-design.md

Inlines the `panicboat/panicboat-actions/kustomize-diff` composite action into this repo's `reusable--kubernetes-builder.yaml`. The temporary annotation on `external-dns` production manifest exists only to trigger the Kustomize Diff job for verification and will be reverted before this PR is finalized.
EOF
)"
```

- [ ] **Step 11: CI の `Kustomize Diff` チェックを確認**

```bash
gh pr checks --watch
```

Expected: `Deploy Kubernetes (external-dns:production) / Kustomize Diff` が pass する

- [ ] **Step 12: PR コメントの内容を確認**

```bash
gh pr view --json comments --jq '.comments[] | select(.body | contains("Kustomize Diff")) | .body' | tail -30
```

Expected: `## Kustomize Diff` ヘッダー、`**Service**: \`external-dns\``、`**Environment**: \`production\``、追加した annotation 行を含む diff が表示される

- [ ] **Step 13: 検証用の一時変更を revert**

```bash
git revert --no-edit HEAD
git push
```

- [ ] **Step 14: revert 後に diff が消えたことを確認**

```bash
gh pr checks --watch
gh pr view --json comments --jq '.comments[] | select(.body | contains("Kustomize Diff")) | .body' | tail -10
```

Expected: 最新のコメントが `No changes` に更新されている（`comment-tag` が一致するため同じコメントが upsert される）

---

# Task 2: monorepo — `Kustomize Diff` ステップのインライン化

**Files:**
- Modify: `.github/workflows/reusable--kubernetes-builder.yaml`

**Interfaces:**
- Consumes: 既存の job 内の `steps.app-token.outputs.token`、`steps.pr-info.outputs.number`、job inputs `service-name` / `environment` / `path`
- Produces: `panicboat/panicboat-actions/kustomize-diff` への参照が monorepo から消える。Task 3 の削除判断がこれに依存する

- [ ] **Step 1: worktree の進め方を確認**

Task 1 と同様、CLAUDE.md の Workflow に従いユーザーに確認する。

- [ ] **Step 2: worktree を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git fetch origin main --quiet
git worktree add -b feat/kustomize-diff-inline-monorepo .claude/worktrees/feat-kustomize-diff-inline-monorepo origin/main
```

- [ ] **Step 3: 現状のステップを確認**

```bash
cd .claude/worktrees/feat-kustomize-diff-inline-monorepo
grep -n "Kustomize Diff" -A10 .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: `uses: panicboat/panicboat-actions/kustomize-diff@fd41cb7fb30ee0b650acedb9f504cbff719844a6 # main` を含む 1 ステップが表示される

- [ ] **Step 4: ステップを置き換える**

以下のブロックを:

```yaml
      - name: Kustomize Diff
        uses: panicboat/panicboat-actions/kustomize-diff@fd41cb7fb30ee0b650acedb9f504cbff719844a6 # main
        with:
          token: ${{ steps.app-token.outputs.token }}
          service-name: ${{ inputs.service-name }}
          environment: ${{ inputs.environment }}
          path: ${{ inputs.path }}
          pr-number: ${{ steps.pr-info.outputs.number }}
```

以下に置き換える:

```yaml
      - name: Checkout base ref
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: base
          token: ${{ steps.app-token.outputs.token }}

      - name: Build head manifests
        id: kustomize-head
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          kustomization: ${{ inputs.path }}/kustomization.yaml
          write-individual-files: true

      - name: Build base manifests
        id: kustomize-base
        uses: int128/kustomize-action@6cb04b0da49fce7201ff08e086072f33475d376e # v1.188.0
        with:
          base-directory: base
          kustomization: ${{ inputs.path }}/kustomization.yaml
          write-individual-files: true

      - name: Diff manifests
        id: diff
        uses: int128/diff-action@77a301a80335bebb9abb2d28a3dacfa844105395 # v2.28.0
        with:
          base: ${{ steps.kustomize-base.outputs.directory }}
          head: ${{ steps.kustomize-head.outputs.directory }}

      - name: Comment PR
        if: steps.pr-info.outputs.number != ''
        uses: thollander/actions-comment-pull-request@24bffb9b452ba05a4f3f77933840a6a841d1b32b # v3.0.1
        with:
          message: |
            ## Kustomize Diff

            **Service**: `${{ inputs.service-name }}`
            **Environment**: `${{ inputs.environment }}`

            ${{ steps.diff.outputs.comment-body || 'No changes' }}
          comment-tag: "kubernetes-${{ inputs.service-name }}-${{ inputs.environment }}"
          mode: upsert
          pr-number: ${{ steps.pr-info.outputs.number }}
          GITHUB_TOKEN: ${{ steps.app-token.outputs.token }}
          reactions: ${{ steps.diff.outputs.has-diff == 'true' && 'rocket' || '' }}
        continue-on-error: true
```

- [ ] **Step 5: `panicboat-actions` への参照が残っていないことを確認**

```bash
grep -n "panicboat-actions/kustomize-diff" .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: 出力なし

- [ ] **Step 6: actionlint で構文検証**

```bash
actionlint .github/workflows/reusable--kubernetes-builder.yaml
```

Expected: エラーなし

- [ ] **Step 7: コミット**

```bash
git add .github/workflows/reusable--kubernetes-builder.yaml
git commit -s -m "refactor(ci): inline the kustomize-diff composite action"
```

- [ ] **Step 8: 検証用の一時的な manifest 変更を加える**

monorepo は helmfile hydrate を経由せず `services/{service}/kubernetes/overlays/{environment}/` を直接 kustomize でビルドする。`services/monolith/kubernetes/overlays/production/deployment.yaml` に無害な annotation を追記する。

```bash
cat services/monolith/kubernetes/overlays/production/deployment.yaml
```

出力された Deployment patch の `metadata` または `spec.template.metadata` に `annotations:` ブロックが無ければ追加し、以下を 1 行追記する:

```yaml
      verify.panicboat/kustomize-diff-check: "true"
```

- [ ] **Step 9: 一時変更をコミットして push**

```bash
git add services/monolith/kubernetes/overlays/production/deployment.yaml
git commit -s -m "test: trigger kustomize-diff verification"
git push -u origin HEAD
```

- [ ] **Step 10: Draft PR を作成**

```bash
platform_pr_number="$(gh pr list --repo panicboat/platform --head feat/kustomize-diff-inline-platform --json number --jq '.[0].number')"

gh pr create --draft \
  --title "refactor(ci): inline the kustomize-diff composite action" \
  --body "$(cat <<EOF
Design: docs/superpowers/specs/2026-08-21-kustomize-diff-deshare-design.md (panicboat/platform, same spec)

Related: panicboat/platform#${platform_pr_number}

Inlines the \`panicboat/panicboat-actions/kustomize-diff\` composite action into this repo's \`reusable--kubernetes-builder.yaml\`. The temporary annotation on the monolith production overlay exists only to trigger the Kustomize Diff job for verification and will be reverted before this PR is finalized.
EOF
)"
```

- [ ] **Step 11: CI の `Kustomize Diff` チェックを確認**

```bash
gh pr checks --watch
```

Expected: `Deploy Kubernetes (monolith:production) / Kustomize Diff`（または該当する service:environment 名）が pass する

- [ ] **Step 12: PR コメントの内容を確認**

```bash
gh pr view --json comments --jq '.comments[] | select(.body | contains("Kustomize Diff")) | .body' | tail -30
```

Expected: `## Kustomize Diff` ヘッダーと追加した annotation 行を含む diff が表示される

- [ ] **Step 13: 検証用の一時変更を revert**

```bash
git revert --no-edit HEAD
git push
```

- [ ] **Step 14: revert 後に diff が消えたことを確認**

```bash
gh pr checks --watch
gh pr view --json comments --jq '.comments[] | select(.body | contains("Kustomize Diff")) | .body' | tail -10
```

Expected: 最新のコメントが `No changes` に更新されている

---

# Task 3: panicboat-actions — `kustomize-diff/` の削除

**Files:**
- Delete: `kustomize-diff/`（ディレクトリごと）
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 / Task 2 がそれぞれの Draft PR で CI green を確認済みであること（両方が完了するまでこのタスクを開始しない）

- [ ] **Step 1: Task 1・Task 2 が完了していることを確認**

```bash
platform_pr_number="$(gh pr list --repo panicboat/platform --head feat/kustomize-diff-inline-platform --json number --jq '.[0].number')"
monorepo_pr_number="$(gh pr list --repo panicboat/monorepo --head feat/kustomize-diff-inline-monorepo --json number --jq '.[0].number')"

gh pr view --repo panicboat/platform "$platform_pr_number" --json state,statusCheckRollup --jq '{state, checks: [.statusCheckRollup[].conclusion] | unique}'
gh pr view --repo panicboat/monorepo "$monorepo_pr_number" --json state,statusCheckRollup --jq '{state, checks: [.statusCheckRollup[].conclusion] | unique}'
```

Expected: 両方とも `checks` に `"FAILURE"` を含まないこと（`Kustomize Diff` の revert 後の green 状態）

- [ ] **Step 2: worktree の進め方を確認**

CLAUDE.md の Workflow に従いユーザーに確認する。

- [ ] **Step 3: worktree を作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git fetch origin main --quiet
git worktree add -b chore/remove-kustomize-diff .claude/worktrees/chore-remove-kustomize-diff origin/main
```

- [ ] **Step 4: `kustomize-diff/` を削除**

```bash
cd .claude/worktrees/chore-remove-kustomize-diff
git rm -r kustomize-diff/
```

- [ ] **Step 5: README の記載を削除**

`README.md` から以下の行を削除する:

```markdown
- `kustomize-diff/` — Build kustomize overlays and post diff as a PR comment.
```

- [ ] **Step 6: 他に `kustomize-diff` への参照が残っていないことを確認**

```bash
grep -rn "kustomize-diff" . --include="*.md" --include="*.yaml" --include="*.yml" 2>/dev/null
```

Expected: 出力なし（`.git/` 配下は対象外）

- [ ] **Step 7: コミット**

```bash
git add -A
git commit -s -m "chore: remove kustomize-diff (inlined into platform and monorepo)"
git push -u origin HEAD
```

- [ ] **Step 8: Draft PR を作成**

```bash
platform_pr_number="$(gh pr list --repo panicboat/platform --head feat/kustomize-diff-inline-platform --json number --jq '.[0].number')"
monorepo_pr_number="$(gh pr list --repo panicboat/monorepo --head feat/kustomize-diff-inline-monorepo --json number --jq '.[0].number')"

gh pr create --draft \
  --title "chore: remove kustomize-diff (inlined into platform and monorepo)" \
  --body "$(cat <<EOF
Design: docs/superpowers/specs/2026-08-21-kustomize-diff-deshare-design.md (panicboat/platform)

Both consumers have inlined this composite action and verified it in CI:
- panicboat/platform#${platform_pr_number}
- panicboat/monorepo#${monorepo_pr_number}

No repository references \`panicboat/panicboat-actions/kustomize-diff\` anymore.
EOF
)"
```

- [ ] **Step 9: lint / actionlint が通ることを確認**

```bash
gh pr checks --watch
```

Expected: `Lint GitHub Actions` を含む全チェックが pass する

---

## Verification Checklist

- [ ] platform の `reusable--kubernetes-builder.yaml` に `panicboat-actions/kustomize-diff` への参照が無い
- [ ] monorepo の `reusable--kubernetes-builder.yaml` に `panicboat-actions/kustomize-diff` への参照が無い
- [ ] platform の Draft PR で `Kustomize Diff` ジョブが実際にコメントを投稿し、その後 revert で `No changes` に更新されたことを確認済み
- [ ] monorepo の Draft PR で同上
- [ ] panicboat-actions から `kustomize-diff/` が削除され、README にも記載が残っていない
- [ ] `terragrunt-run/` は変更していない（スコープ外）
