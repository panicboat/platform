# HolmesGPT Source Code Investigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let HolmesGPT read `panicboat/monorepo` and `panicboat/platform` source code (read-only) when cluster state alone doesn't explain a root cause, by extending its existing `bash` toolset's allowlist — no new toolset, no new infrastructure.

**Architecture:** HolmesGPT's `bash` toolset already supports an `allow` field (command prefixes merged with the builtin allowlist). Add read-only git subcommands (`git clone`, `git log`, `git show`, `git diff`, `git blame`, `git ls-files`, `git grep`) plus `cat`/`find` (needed to read cloned file contents — `builtin_allowlist` stays `core`, not `extended`). Both target repos are public, so no credentials are needed for `git clone` over HTTPS.

**Tech Stack:** Helmfile (HolmesGPT chart), Kustomize.

## Global Constraints

- `builtin_allowlist` stays `"core"` — do not change it to `"extended"`. Only `cat` and `find` are added individually via `allow`, not the full extended set (`ls`/`stat`/`du`/`df`/tar family) — those aren't needed for reading git-cloned source and would widen the allowed surface unnecessarily.
- Do not allow any write/state-changing git subcommand (`git push`, `git commit`, `git config`, etc.) — only the read-only subcommands listed above.
- No PVC, no new Secret, no new toolset — this is a values-file-only change (verified in the design doc: both repos are public and small, ~7-8MB each, so on-demand ephemeral clone is sufficient).
- Design doc: `docs/superpowers/specs/2026-08-16-holmes-source-investigation-design.md`.

---

## Task 1: Add git read-only subcommands and cat/find to the bash toolset allowlist

**Files:**
- Modify: `kubernetes/components/holmesgpt/production/values.yaml.gotmpl:82-90` (the `bash:` toolset block and its header comment — exact line numbers may have shifted slightly; locate by the `bash:` key under `toolsets:`)

**Interfaces:** none (standalone Helm values change, no other task depends on this).

- [ ] **Step 1: Confirm the current block before editing**

Run: `grep -n -A 8 "^  bash:" kubernetes/components/holmesgpt/production/values.yaml.gotmpl`
Expected output (confirm this matches before proceeding — if it doesn't, stop and report the actual content instead of guessing):

```yaml
  bash:
    enabled: true
    config:
      builtin_allowlist: "core"
```

- [ ] **Step 2: Replace the `bash:` toolset block and its header comment**

In `kubernetes/components/holmesgpt/production/values.yaml.gotmpl`, find:

```yaml
  # chart 既定は extended。差分の 11 コマンド (cat / base64 / ls / find / stat /
  # du / df / tar -tf / gzip -l / zcat / zgrep) は調査対象である cluster では
  # なく HolmesGPT 自身のコンテナを向いている。core でも kubectl get/describe/
  # logs と jq / grep が残るため調査は成立する。
  # 不足すればレポートに拒否として現れるので、見てから上げる。
  bash:
    enabled: true
    config:
      builtin_allowlist: "core"
```

Replace with:

```yaml
  # chart 既定は extended。差分の 11 コマンド (cat / base64 / ls / find / stat /
  # du / df / tar -tf / gzip -l / zcat / zgrep) は当初、調査対象である cluster
  # ではなく HolmesGPT 自身のコンテナを向いていたため core に絞っていた。
  # ソースコード調査 (git clone 後の読み取り) のため cat / find だけを allow で
  # 個別追加する。extended 全体 (ls / stat / du / df / tar 系) までは不要。
  # git の書き込み系サブコマンド (push / commit / config 等) は allow に含めない
  # — prefix マッチしないコマンドは HolmesGPT 側で自動的に拒否される。
  # 対象は panicboat/monorepo・panicboat/platform (両方 public、認証不要)。
  bash:
    enabled: true
    config:
      builtin_allowlist: "core"
      allow:
        - "git clone"
        - "git log"
        - "git show"
        - "git diff"
        - "git blame"
        - "git ls-files"
        - "git grep"
        - "cat"
        - "find"
```

- [ ] **Step 3: Hydrate and inspect the diff**

Run: `./scripts/kubernetes-hydrate/hydrate-component.sh holmesgpt production && git diff kubernetes/manifests/production/holmesgpt`
Expected: the rendered manifest's HolmesGPT config (likely embedded in a ConfigMap or Secret — check whichever resource contains the `toolsets:` block) gains the `allow` list under the `bash` toolset entry, with the 9 read-only command prefixes listed above and no others. No other resource or toolset entry changes.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/holmesgpt/production/values.yaml.gotmpl kubernetes/manifests/production/holmesgpt
git commit -s -m "feat(holmesgpt): allow read-only git commands for source investigation"
```

---

## Task 2: Open Draft PR

**Files:** none (git/GitHub operations only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/holmesgpt-source-investigation
```

- [ ] **Step 2: Open a Draft PR**

```bash
gh pr create --draft --title "feat(holmesgpt): allow read-only git commands for source investigation" --body "$(cat <<'EOF'
## Summary
- Extend HolmesGPT's `bash` toolset `allow` list with read-only git subcommands (`git clone`/`log`/`show`/`diff`/`blame`/`ls-files`/`grep`) plus `cat`/`find`, so it can clone and read `panicboat/monorepo`/`panicboat/platform` source when investigating a root cause that cluster state alone doesn't explain.
- `builtin_allowlist` stays `core` — only the specific commands needed for source reading are added, not the full `extended` set.
- No new infrastructure: both target repos are public (no credentials needed) and small (~7-8MB each), so on-demand ephemeral clone (no PVC/caching) is sufficient.

## Dependencies
- A companion change to `panicboat/monorepo`'s holmes service (separate plan) tells HolmesGPT about these two repos and when to use source investigation, via its `additional_system_prompt`. Without that companion change, this PR alone just makes the capability available — HolmesGPT won't know to use it.

## Test plan
- [ ] `hydrate-component.sh holmesgpt production` diff reviewed — only the bash toolset's allow list changed
- [ ] After merge and the companion monorepo change: ask holmes something that requires source-level investigation and confirm HolmesGPT clones and reads the relevant repo

Design: docs/superpowers/specs/2026-08-16-holmes-source-investigation-design.md
EOF
)"
```

- [ ] **Step 3: Report the PR URL back to the user.**

---

## Self-Review Notes

- **Spec coverage**: the design doc's Component 1 (bash toolset allowlist extension, exact command list, `builtin_allowlist` staying `core`, no write git subcommands, no PVC/credentials) is fully covered by Task 1.
- **Placeholder scan**: none — the YAML block is the complete, literal content to write.
- **Scope boundary**: Component 2 (holmes's `additional_system_prompt` addition, `panicboat/monorepo`) is explicitly out of scope for this plan — separate plan, separate repo, called out in the Draft PR's Dependencies section so a reviewer isn't surprised the capability sits unused until that lands too.
