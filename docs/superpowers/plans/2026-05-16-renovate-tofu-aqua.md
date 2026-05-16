# Renovate-driven OpenTofu/Terragrunt via aqua — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OpenTofu / Terragrunt の binary version source-of-truth を各 caller repo の `.github/aqua.yaml` に移し、`panicboat-actions/terragrunt-run` を `gruntwork-io/terragrunt-action` から aqua install + 直接 invoke に置換することで、Renovate の cross-repo merge 順序に依存しない構造を作る。

**Architecture:** caller repo（platform / monorepo）が `.github/aqua.yaml` に `opentofu/opentofu@v1.12.0` と `gruntwork-io/terragrunt@v1.0.2` を pin。panicboat-actions/terragrunt-run composite action が `aquaproj/aqua-installer` で aqua 自体を install し、aqua の shim 経由で `terragrunt` を直接実行する。`parse-results.js` への output contract（`tg_action_exit_code` / `tg_action_output`）は維持し、PR comment 生成系は無変更。

**Tech Stack:** GitHub Actions composite actions / aqua (aqua-registry v4.311.0) / opentofu / terragrunt / Renovate (aqua manager + terraform manager の `overridePackageName` rule)

**Spec:** `docs/superpowers/specs/2026-05-16-renovate-tofu-aqua-design.md`

---

## File map

| Repo | File | 操作 |
|------|------|------|
| monorepo | `.github/aqua.yaml` | 新規作成 |
| platform | `.github/aqua.yaml` | packages に 2 行追記 |
| panicboat-actions | `terragrunt-run/action.yaml` | `Execute Terragrunt` step を 3 step に差し替え |
| panicboat-actions | `.github/renovate.json` | `customManagers` array (typo 込み 2 件) を削除 |

## Task 順序

```
Task 1 (PR-A) と Task 2 (PR-B) は並列実行可。
Task 3 (PR-C) は Task 1 + Task 2 の merge 完了を待ってから ready-for-review にする。
Task 4 / Task 5 は PR-C merge 後の Renovate 自動 PR を watch するもの。
```

---

### Task 1: PR-A — Create monorepo `.github/aqua.yaml`

**Files:**
- Create: `monorepo/.github/aqua.yaml`

**Branch:** `chore/aqua-add-tofu-terragrunt`
**Worktree:** `.claude/worktrees/chore-aqua-add-tofu-terragrunt`

- [ ] **Step 1: Create worktree on monorepo**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
grep -qxF '/.claude/worktrees/' .git/info/exclude 2>/dev/null \
  || echo '/.claude/worktrees/' >> .git/info/exclude
git fetch origin main --quiet
git worktree add -b chore/aqua-add-tofu-terragrunt \
  .claude/worktrees/chore-aqua-add-tofu-terragrunt origin/main
```

Expected: `Preparing worktree (new branch 'chore/aqua-add-tofu-terragrunt')`

- [ ] **Step 2: Write `.github/aqua.yaml`**

Content (`monorepo/.claude/worktrees/chore-aqua-add-tofu-terragrunt/.github/aqua.yaml`):

```yaml
---
# aqua - Declarative CLI Version Manager
# https://aquaproj.github.io/
registries:
  - type: standard
    ref: v4.311.0 # renovate: github_release aquaproj/aqua-registry

packages:
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
```

- [ ] **Step 3: Verify yaml parses**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/chore-aqua-add-tofu-terragrunt
yq -r '.packages[].name' .github/aqua.yaml
```

Expected output:
```
opentofu/opentofu@v1.12.0
gruntwork-io/terragrunt@v1.0.2
```

- [ ] **Step 4: Commit**

```bash
git add .github/aqua.yaml
git commit -s -m "$(cat <<'EOF'
chore(.github): pin opentofu and terragrunt versions in aqua.yaml

Introduces aqua as the version manager for terragrunt-side binaries so
that .github/workflows/reusable--terragrunt-executor.yaml (via
panicboat-actions/terragrunt-run composite) reads versions from this
file once the composite migrates to aqua. No behavior change yet —
current composite ignores aqua.yaml.
EOF
)"
```

- [ ] **Step 5: Push and open draft PR**

```bash
git push -u origin HEAD
gh pr create --draft --title "chore(.github): pin opentofu and terragrunt versions in aqua.yaml" --body "$(cat <<'EOF'
## Summary

Introduces `.github/aqua.yaml` with `opentofu/opentofu@v1.12.0` and `gruntwork-io/terragrunt@v1.0.2`. Part 1/3 of the rollout in `docs/superpowers/plans/2026-05-16-renovate-tofu-aqua.md` (see panicboat/platform spec PR).

No behavior change: the current `panicboat-actions/terragrunt-run` composite reads versions from `gruntwork-io/terragrunt-action` inputs, not from aqua.yaml. This PR lands the source-of-truth file first so the composite migration in panicboat-actions can rely on it without breaking caller CI.

## Test plan

- [ ] yamllint passes
- [ ] CI green (no-op for terragrunt workflow)
EOF
)"
```

---

### Task 2: PR-B — Add OpenTofu / Terragrunt to platform `.github/aqua.yaml`

**Files:**
- Modify: `platform/.github/aqua.yaml`

**Branch:** `chore/aqua-add-tofu-terragrunt`
**Worktree:** `.claude/worktrees/chore-aqua-add-tofu-terragrunt`

- [ ] **Step 1: Create worktree on platform**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
grep -qxF '/.claude/worktrees/' .git/info/exclude 2>/dev/null \
  || echo '/.claude/worktrees/' >> .git/info/exclude
git fetch origin main --quiet
git worktree add -b chore/aqua-add-tofu-terragrunt \
  .claude/worktrees/chore-aqua-add-tofu-terragrunt origin/main
```

Expected: `Preparing worktree (new branch 'chore/aqua-add-tofu-terragrunt')`

- [ ] **Step 2: Edit `.github/aqua.yaml`**

Read the existing file first:

```bash
cat /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/chore-aqua-add-tofu-terragrunt/.github/aqua.yaml
```

Append 2 lines under `packages:` (after the existing last entry `rhysd/actionlint@v1.7.7`):

```yaml
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
```

Final state:

```yaml
---
# aqua - Declarative CLI Version Manager
# https://aquaproj.github.io/
registries:
  - type: standard
    ref: v4.311.0 # renovate: github_release aquaproj/aqua-registry

packages:
  - name: helmfile/helmfile@v0.169.2
  - name: helm/helm@v3.17.3
  - name: kubernetes-sigs/kustomize@kustomize/v5.6.0
  - name: nektos/act@v0.2.87
  - name: rhysd/actionlint@v1.7.7
  - name: opentofu/opentofu@v1.12.0
  - name: gruntwork-io/terragrunt@v1.0.2
```

- [ ] **Step 3: Verify yaml parses and packages are recognized**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/chore-aqua-add-tofu-terragrunt
yq -r '.packages[].name' .github/aqua.yaml | grep -E "(opentofu|terragrunt)"
```

Expected output:
```
opentofu/opentofu@v1.12.0
gruntwork-io/terragrunt@v1.0.2
```

- [ ] **Step 4: Commit**

```bash
git add .github/aqua.yaml
git commit -s -m "$(cat <<'EOF'
chore(.github): pin opentofu and terragrunt versions in aqua.yaml

Extends the existing aqua.yaml (which already pins helm / helmfile /
kustomize / act / actionlint) with the binaries used by terragrunt
workflows. No behavior change yet — current
panicboat-actions/terragrunt-run composite ignores aqua.yaml; it will
start reading these versions once that composite migrates to aqua.
EOF
)"
```

- [ ] **Step 5: Push and open draft PR**

```bash
git push -u origin HEAD
gh pr create --draft --title "chore(.github): pin opentofu and terragrunt versions in aqua.yaml" --body "$(cat <<'EOF'
## Summary

Adds `opentofu/opentofu@v1.12.0` and `gruntwork-io/terragrunt@v1.0.2` to the existing `.github/aqua.yaml`. Part 2/3 of the rollout in `docs/superpowers/plans/2026-05-16-renovate-tofu-aqua.md`.

No behavior change. The composite migration in panicboat-actions will start consuming these once landed.

## Test plan

- [ ] yamllint passes
- [ ] CI green (no-op for terragrunt workflow)
EOF
)"
```

---

### Task 3: PR-C — Migrate panicboat-actions/terragrunt-run to aqua + remove typo'd customManagers

**Files:**
- Modify: `panicboat-actions/terragrunt-run/action.yaml`（`Execute Terragrunt` step を 3 step に差し替え）
- Modify: `panicboat-actions/.github/renovate.json`（`customManagers` array を削除）

**Branch:** `refactor/terragrunt-run-aqua`
**Worktree:** `.claude/worktrees/refactor-terragrunt-run-aqua`

**Precondition:** Task 1 (PR-A) と Task 2 (PR-B) を **draft で push 完了** していること。merge は ready-for-review 段階までに完了させる。

- [ ] **Step 1: Create worktree on panicboat-actions**

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
grep -qxF '/.claude/worktrees/' .git/info/exclude 2>/dev/null \
  || echo '/.claude/worktrees/' >> .git/info/exclude
git fetch origin main --quiet
git worktree add -b refactor/terragrunt-run-aqua \
  .claude/worktrees/refactor-terragrunt-run-aqua origin/main
```

Expected: `Preparing worktree (new branch 'refactor/terragrunt-run-aqua')`

- [ ] **Step 2: Replace `Execute Terragrunt` step in `terragrunt-run/action.yaml`**

Target file: `panicboat-actions/.claude/worktrees/refactor-terragrunt-run-aqua/terragrunt-run/action.yaml`

old_string (現状の lines 77-90):

```yaml
    - name: Execute Terragrunt
      id: terragrunt
      uses: gruntwork-io/terragrunt-action@53dbdc2c3d43e82bf3bae10b734a968196442bec # v3.2.0
      with:
        tg_version: '1.0.2'
        tofu_version: '1.11.6'
        tg_dir: ${{ inputs.working-directory }}
        tg_command: ${{ inputs.action-type }}
        tg_add_approve: ${{ inputs.action-type == 'apply' && '1' || '' }}
        github_token: ${{ inputs.token }}
      env:
        TF_INPUT: false
        GITHUB_TOKEN: ${{ inputs.token }}
        AWS_DEFAULT_REGION: ${{ inputs.aws-region }}
```

new_string:

```yaml
    - name: Setup aqua
      uses: aquaproj/aqua-installer@11dd79b4e498d471a9385aa9fb7f62bb5f52a73c # v4.0.4
      with:
        aqua_version: v2.48.2
      env:
        AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml

    - name: Verify required binaries
      shell: bash
      env:
        AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
      run: |
        set -euo pipefail
        missing=()
        command -v terragrunt >/dev/null || missing+=("gruntwork-io/terragrunt")
        command -v tofu       >/dev/null || missing+=("opentofu/opentofu")
        if [ ${#missing[@]} -gt 0 ]; then
          echo "::error::Missing aqua packages: ${missing[*]}. Add them to .github/aqua.yaml."
          exit 1
        fi

    - name: Execute Terragrunt
      id: terragrunt
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      env:
        TF_INPUT: 'false'
        GITHUB_TOKEN: ${{ inputs.token }}
        AWS_DEFAULT_REGION: ${{ inputs.aws-region }}
        AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        ACTION_TYPE: ${{ inputs.action-type }}
      run: |
        set -o pipefail
        out="$RUNNER_TEMP/tg-out.log"
        args=("$ACTION_TYPE" -no-color -input=false)
        [ "$ACTION_TYPE" = apply ] && args+=(-auto-approve)
        terragrunt "${args[@]}" 2>&1 | tee "$out"
        code=${PIPESTATUS[0]}
        delim="__TGEOF_$(openssl rand -hex 8)__"
        {
          echo "tg_action_exit_code=$code"
          echo "tg_action_output<<$delim"
          head -c 200000 "$out"
          echo
          echo "$delim"
        } >> "$GITHUB_OUTPUT"
        exit "$code"
```

- [ ] **Step 3: Verify replaced YAML parses and structure is intact**

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/refactor-terragrunt-run-aqua
yq -r '.runs.steps[].name // .runs.steps[].uses' terragrunt-run/action.yaml
```

Expected output（step name 順）:
```
Checkout
Validate working directory
Configure AWS credentials
Verify AWS credentials
Setup aqua
Verify required binaries
Execute Terragrunt
Parse execution results
Comment PR with Terragrunt results
```

`gruntwork-io/terragrunt-action` への参照が消えていること:

```bash
grep -c "gruntwork-io/terragrunt-action" terragrunt-run/action.yaml
```

Expected: `0`

- [ ] **Step 4: Shellcheck the inline run scripts**

```bash
for step_id in $(yq -r '.runs.steps[] | select(.run != null) | .id // .name' terragrunt-run/action.yaml); do
  echo "=== $step_id ==="
  yq -r --arg id "$step_id" '.runs.steps[] | select((.id // .name) == $id) | .run' terragrunt-run/action.yaml \
    | shellcheck -s bash - || true
done
```

Expected: shellcheck の重大な warning なし。SC1091（source not specified）等の軽微なものは無視可。
shellcheck が手元に無い場合は `brew install shellcheck` で導入。CI 側で `lint-actions.yml` の actionlint が走るので、ローカル shellcheck は best-effort。

- [ ] **Step 5: Remove `customManagers` from `.github/renovate.json`**

Target file: `panicboat-actions/.claude/worktrees/refactor-terragrunt-run-aqua/.github/renovate.json`

old_string (現 lines 47-72 を含む末尾):

```json
    {
      "description": "✅ Minor/Patch updates - enable automerge",
      "matchUpdateTypes": ["minor", "patch", "pin", "digest"],
      "automerge": true
    }
  ],

  "customManagers": [
    {
      "customType": "regex",
      "description": "Track OpenTofu version pinned in terragrunt composite action",
      "fileMatch": ["^terragrunt/action\\.yaml$"],
      "matchStrings": [
        "tofu_version:\\s*['\"](?<currentValue>[^'\"]+)['\"]"
      ],
      "datasourceTemplate": "github-releases",
      "depNameTemplate": "opentofu/opentofu",
      "extractVersionTemplate": "^v?(?<version>.+)$"
    },
    {
      "customType": "regex",
      "description": "Track Terragrunt version pinned in terragrunt composite action",
      "fileMatch": ["^terragrunt/action\\.yaml$"],
      "matchStrings": [
        "tg_version:\\s*['\"](?<currentValue>[^'\"]+)['\"]"
      ],
      "datasourceTemplate": "github-releases",
      "depNameTemplate": "gruntwork-io/terragrunt",
      "extractVersionTemplate": "^v?(?<version>.+)$"
    }
  ]
}
```

new_string:

```json
    {
      "description": "✅ Minor/Patch updates - enable automerge",
      "matchUpdateTypes": ["minor", "patch", "pin", "digest"],
      "automerge": true
    }
  ]
}
```

- [ ] **Step 6: Verify renovate.json parses**

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions/.claude/worktrees/refactor-terragrunt-run-aqua
jq -e '.customManagers // empty' .github/renovate.json
```

Expected: 出力なし（`customManagers` key が消えている）

```bash
jq '.packageRules | length' .github/renovate.json
```

Expected: `4`（既存の packageRules は手付かず）

- [ ] **Step 7: Commit**

```bash
git add terragrunt-run/action.yaml .github/renovate.json
git commit -s -m "$(cat <<'EOF'
refactor(terragrunt-run): drive opentofu/terragrunt versions from caller's aqua.yaml

Replaces gruntwork-io/terragrunt-action with aquaproj/aqua-installer +
direct terragrunt invocation. Versions are now read from the caller
repo's .github/aqua.yaml (opentofu/opentofu and gruntwork-io/terragrunt
entries). Output contract (tg_action_exit_code / tg_action_output) is
preserved, so parse-results.js and PR comment behavior are unchanged.

Adds a Verify step that fails fast with a helpful message when the
required aqua packages are missing from the caller's aqua.yaml. Also
drops the customManagers from .github/renovate.json — their fileMatch
pointed at the pre-rename path (`terragrunt/action.yaml`) and the
version pins they tracked no longer live in this repo.
EOF
)"
```

- [ ] **Step 8: Push and open draft PR**

```bash
git push -u origin HEAD
gh pr create --draft --title "refactor(terragrunt-run): drive opentofu/terragrunt versions from caller's aqua.yaml" --body "$(cat <<'EOF'
## Summary

Final part (3/3) of the rollout in `panicboat/platform docs/superpowers/plans/2026-05-16-renovate-tofu-aqua.md`.

- Replace `gruntwork-io/terragrunt-action` with `aquaproj/aqua-installer` + direct `terragrunt` invocation
- Add a Verify step that fails fast with a clear error when required aqua packages are missing in the caller's `.github/aqua.yaml`
- Preserve the `tg_action_exit_code` / `tg_action_output` step-output contract so `parse-results.js` and PR comment behavior are unchanged
- Drop `customManagers` from `.github/renovate.json` (fileMatch pointed at the pre-rename path; the pins they tracked no longer live here)

## Preconditions before marking ready-for-review

- panicboat/platform aqua.yaml PR merged (opentofu + terragrunt added)
- panicboat/monorepo aqua.yaml PR merged (file created with opentofu + terragrunt)

If those land first, the safety net is: Renovate's auto SHA-bump PRs in platform/monorepo will fail fast on the Verify step with a message pointing at the missing aqua.yaml entries — no silent breakage.

## Test plan

- [ ] `lint-actions.yml` (actionlint) green
- [ ] After merge, Renovate auto-bumps the panicboat-actions SHA pin in platform / monorepo; those PRs' CI (running real terragrunt plan) passes
- [ ] Stale platform PRs #362-#375 auto-rebase against new SHA and pass CI
EOF
)"
```

---

### Task 4: Wait for PR-A + PR-B to merge before marking PR-C ready

- [ ] **Step 1: Confirm PR-A merged**

```bash
gh pr view <PR-A-number> --repo panicboat/monorepo --json state,mergedAt
```

Expected: `"state": "MERGED"`

- [ ] **Step 2: Confirm PR-B merged**

```bash
gh pr view <PR-B-number> --repo panicboat/platform --json state,mergedAt
```

Expected: `"state": "MERGED"`

- [ ] **Step 3: Mark PR-C ready for review**

```bash
gh pr ready <PR-C-number> --repo panicboat/panicboat-actions
```

---

### Task 5: Monitor Renovate auto SHA-bump PRs (PR-D / PR-E) after PR-C merge

PR-C が merge されると panicboat-actions main の SHA が更新される。次の Renovate schedule で platform / monorepo それぞれに SHA pin 更新 PR が出る（`reusable--terragrunt-executor.yaml` の `panicboat/panicboat-actions/terragrunt-run@<SHA>` を新 SHA に bump）。Renovate を手動 trigger したい場合は dependency dashboard issue の checkbox にチェックを入れる。

- [ ] **Step 1: 一覧確認**

```bash
gh pr list --repo panicboat/platform --label "🤖 renovate" --json number,title --search "panicboat-actions in:title"
gh pr list --repo panicboat/monorepo  --label "🤖 renovate" --json number,title --search "panicboat-actions in:title"
```

- [ ] **Step 2: 各 PR の CI を待つ**

```bash
gh pr checks <PR-D-number> --repo panicboat/platform --watch
gh pr checks <PR-E-number> --repo panicboat/monorepo  --watch
```

期待: `Deploy Terragrunt (...)` matrix が全 service / 環境で green。fail-fast step が "Missing aqua packages" を出していないこと。

- [ ] **Step 3: Merge**

```bash
gh pr merge <PR-D-number> --repo panicboat/platform --squash
gh pr merge <PR-E-number> --repo panicboat/monorepo  --squash
```

---

### Task 6: Verify stale platform PRs auto-rebase and pass CI

PR-D 1 が merge されると、platform の 9 件の stale PR（#362, #363, #365, #370–#375）は Renovate の auto-rebase 機能で新しい main を base に取り込み、`reusable--terragrunt-executor.yaml` の SHA pin が新 SHA を指すようになる。これにより runtime は OpenTofu v1.12.0 となり、`required_version >= 1.12.0` と整合して CI が green になる。

- [ ] **Step 1: rebase 状況を確認**

```bash
for n in 362 363 365 370 371 372 373 374 375; do
  echo "=== #$n ==="
  gh pr view "$n" --repo panicboat/platform --json mergeable,mergeStateStatus,headRefOid
done
```

期待: `mergeStateStatus` が `BEHIND` でないこと（rebase 済み）。`headRefOid` が以前と異なる新 SHA であること。

- [ ] **Step 2: CI 結果を確認**

```bash
for n in 362 363 365 370 371 372 373 374 375; do
  echo "=== #$n ==="
  gh pr checks "$n" --repo panicboat/platform | grep -iE "(fail|error)" || echo "all green"
done
```

期待: 全 PR で `all green`。

- [ ] **Step 3: merge**

各 PR を順次 merge（automerge 設定があれば自動進行）：

```bash
for n in 362 363 365 370 371 372 373 374 375; do
  gh pr merge "$n" --repo panicboat/platform --squash --auto
done
```

---

### Task 7: Worktree cleanup

PR-A, PR-B, PR-C がそれぞれ merge された後に対応する worktree を削除。

- [ ] **Step 1: monorepo worktree 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree remove .claude/worktrees/chore-aqua-add-tofu-terragrunt
git fetch origin --prune
```

- [ ] **Step 2: platform worktree 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
git worktree remove .claude/worktrees/chore-aqua-add-tofu-terragrunt
git fetch origin --prune
```

- [ ] **Step 3: panicboat-actions worktree 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/panicboat-actions
git worktree remove .claude/worktrees/refactor-terragrunt-run-aqua
git fetch origin --prune
```

---

## Goal validation

実装完了時点で以下が成立していること（CLAUDE.md "Goal-Driven Execution" 準拠）：

- [ ] `panicboat-actions/terragrunt-run/action.yaml` に `gruntwork-io/terragrunt-action` への参照なし
- [ ] `panicboat-actions/.github/renovate.json` に `customManagers` key なし
- [ ] `platform/.github/aqua.yaml` に `opentofu/opentofu` と `gruntwork-io/terragrunt` の entry あり
- [ ] `monorepo/.github/aqua.yaml` が存在し、上記 2 entry を含む
- [ ] platform の 9 件の stale Renovate PR (#362-#375) が green / merged
- [ ] 次の OpenTofu release（仮 v1.13.0）が出た際、`aqua.yaml` と `terraform.tf` の `required_version` が同一 Renovate run で同方向に bump されることを次回 schedule で確認
