# Remove Local Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `kubernetes/` から local 環境（k3d 前提の構成）と関連 CI 構成を削除し、production EKS のみを扱う構造にする。`Makefile` の hydrate ロジックは `scripts/kubernetes-hydrate/` 配下の bash script に移行する。

**Architecture:** Makefile の 3 つの hydrate target を 2 本の独立した bash script に切り出し、CI workflow (`reusable--kubernetes-hydrator.yaml`) と手元実行の双方から同じ script を呼べるようにする。その上で local 関連の cluster / component / manifest / CI matrix / README 章をまとめて削除する。

**Tech Stack:** bash, helmfile (v1.4 系), kustomize, helm, GitHub Actions, FluxCD（変更対象外、参照のみ）

**Reference:** [Spec](../specs/2026-05-13-remove-local-env-design.md)

---

## File Structure

### Created

- `scripts/kubernetes-hydrate/hydrate-component.sh` — 単一 component を hydrate (旧 Makefile `hydrate-component` target 相当)。引数: `<component> <env>`
- `scripts/kubernetes-hydrate/hydrate-index.sh` — `manifests/<env>/` 直下の集約 `kustomization.yaml` と `00-namespaces/` を再生成し orphan を削除 (旧 Makefile `hydrate-index` target 相当)。引数: `<env>`

### Modified

- `.github/workflows/reusable--kubernetes-hydrator.yaml` — `make -C kubernetes ...` を新 script の `bash` 呼び出しに置換
- `kubernetes/helmfile.yaml.gotmpl` — `local:` environment block と `cluster.isLocal` value を削除
- `workflow-config.yaml` — `local` environment entry を削除
- `kubernetes/README.md` — `## 🚀 Local Development` 章と line 122 の "local 環境では..." 文を削除

### Deleted

- `kubernetes/Makefile`
- `kubernetes/clusters/local/`
- `kubernetes/components/*/local/` (11 ディレクトリ: beyla, cilium, coredns, dashboard, fluent-bit, gateway-api, loki, opentelemetry, opentelemetry-collector, prometheus-operator, tempo)
- `kubernetes/manifests/local/`

---

## Conventions

- すべての作業は worktree `platform/.claude/worktrees/remove-local-env/`（branch `remove-local-env`）内で実施する
- commit は `-s`（signoff）必須、`Co-Authored-By` 禁止
- 各 task 完了時に commit を残す（review 単位を保つ）
- 削除系 commit の前後で `kubernetes/manifests/production/` の内容が変わっていないことを git diff で確認する

---

## Task 1: Create scripts/kubernetes-hydrate/hydrate-component.sh

**Files:**
- Create: `scripts/kubernetes-hydrate/hydrate-component.sh`
- Reference: `kubernetes/Makefile` lines 78-96（`hydrate-component` target）

**Behavior parity requirement:** 新 script は既存 Makefile target と byte-identical output を生成する。検証は「既存の `manifests/production/<comp>/manifest.yaml` を削除してから script を実行し、`git diff` がゼロであること」で確認する。

- [ ] **Step 1: Create script file**

Write file `scripts/kubernetes-hydrate/hydrate-component.sh` with mode 0755:

```bash
#!/usr/bin/env bash
# Hydrate a single Kubernetes component into kubernetes/manifests/<env>/<component>/.
#
# Behavior:
#   1. Run `helmfile template` if components/<component>/<env>/helmfile.yaml exists.
#   2. Append `kustomize build` output if components/<component>/<env>/kustomization/ exists.
#   3. Write a thin kustomization.yaml that points to manifest.yaml.
#   4. Suppress no-op churn: when the only diff against git is TLS material (cert-manager
#      regenerates ca.crt / tls.key / caBundle every render), revert the file so PRs do
#      not accumulate noise commits.
#
# Usage: hydrate-component.sh <component> <env>
set -euo pipefail

component="${1:?component name required}"
env="${2:?environment name required}"

cd "$(git rev-parse --show-toplevel)"

component_dir="kubernetes/components/${component}/${env}"
out_dir="kubernetes/manifests/${env}/${component}"

mkdir -p "${out_dir}"
: > "${out_dir}/manifest.yaml"

if [ -f "${component_dir}/helmfile.yaml" ]; then
    helmfile -f "${component_dir}/helmfile.yaml" -e "${env}" template --include-crds --skip-tests >> "${out_dir}/manifest.yaml"
fi

if [ -d "${component_dir}/kustomization" ]; then
    echo "---" >> "${out_dir}/manifest.yaml"
    kustomize build "${component_dir}/kustomization" >> "${out_dir}/manifest.yaml"
fi

printf "resources:\n  - manifest.yaml\n" > "${out_dir}/kustomization.yaml"

if git ls-files --error-unmatch "${out_dir}/manifest.yaml" >/dev/null 2>&1; then
    if git diff --quiet -I '^[[:space:]]*(ca\.crt|ca\.key|tls\.crt|tls\.key|caBundle):' -- "${out_dir}/manifest.yaml"; then
        git checkout -- "${out_dir}/manifest.yaml"
    fi
fi
```

- [ ] **Step 2: Make script executable**

```bash
chmod +x scripts/kubernetes-hydrate/hydrate-component.sh
```

- [ ] **Step 3: Regression test against one component (cilium)**

cilium は helmfile のみ（kustomization なし）を使う standard ケース。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/remove-local-env
rm -f kubernetes/manifests/production/cilium/manifest.yaml kubernetes/manifests/production/cilium/kustomization.yaml
bash scripts/kubernetes-hydrate/hydrate-component.sh cilium production
git status --porcelain -- kubernetes/manifests/production/cilium/
```

Expected: 出力は空（= ファイルは git の committed 内容と byte-identical に再生成された）

- [ ] **Step 4: Regression test against a component that uses kustomization (gateway-api)**

gateway-api は helmfile + kustomization 両方を持つ。両 path を通すケース。

```bash
rm -f kubernetes/manifests/production/gateway-api/manifest.yaml kubernetes/manifests/production/gateway-api/kustomization.yaml
bash scripts/kubernetes-hydrate/hydrate-component.sh gateway-api production
git status --porcelain -- kubernetes/manifests/production/gateway-api/
```

Expected: 出力は空

- [ ] **Step 5: Regression test against cert-manager (TLS churn suppression path)**

cert-manager は CA bundle を render 毎に regenerate するため、script 末尾の `git checkout` ロジックが効くケース。

```bash
rm -f kubernetes/manifests/production/cert-manager/manifest.yaml kubernetes/manifests/production/cert-manager/kustomization.yaml
bash scripts/kubernetes-hydrate/hydrate-component.sh cert-manager production
git status --porcelain -- kubernetes/manifests/production/cert-manager/
```

Expected: 出力は空（TLS 差分のみだったため `git checkout` で committed 内容に戻った）

- [ ] **Step 6: Commit**

```bash
git add scripts/kubernetes-hydrate/hydrate-component.sh
git commit -s -m "feat(scripts/kubernetes-hydrate): add hydrate-component.sh"
```

---

## Task 2: Create scripts/kubernetes-hydrate/hydrate-index.sh

**Files:**
- Create: `scripts/kubernetes-hydrate/hydrate-index.sh`
- Reference: `kubernetes/Makefile` lines 99-130（`hydrate-index` target）

- [ ] **Step 1: Create script file**

Write file `scripts/kubernetes-hydrate/hydrate-index.sh` with mode 0755:

```bash
#!/usr/bin/env bash
# Regenerate the top-level kustomization index and namespace aggregation for
# kubernetes/manifests/<env>/, and prune orphan component subdirectories whose source
# under kubernetes/components/<comp>/<env>/ no longer exists.
#
# Behavior:
#   1. Aggregate each component's namespace.yaml (env-specific override or default)
#      into manifests/<env>/00-namespaces/namespaces.yaml.
#   2. Delete manifests/<env>/<comp>/ directories that lack a source.
#   3. Write manifests/<env>/kustomization.yaml listing 00-namespaces and all
#      surviving component directories in sorted order.
#
# Usage: hydrate-index.sh <env>
set -euo pipefail

env="${1:?environment name required}"

cd "$(git rev-parse --show-toplevel)"

env_dir="kubernetes/manifests/${env}"

mkdir -p "${env_dir}/00-namespaces"
: > "${env_dir}/00-namespaces/namespaces.yaml"

for comp_dir in kubernetes/components/*/"${env}"/; do
    [ -d "${comp_dir}" ] || continue
    comp_name=$(basename "$(dirname "${comp_dir}")")
    if [ -f "kubernetes/components/${comp_name}/${env}/namespace.yaml" ]; then
        echo "---" >> "${env_dir}/00-namespaces/namespaces.yaml"
        cat "kubernetes/components/${comp_name}/${env}/namespace.yaml" >> "${env_dir}/00-namespaces/namespaces.yaml"
    elif [ -f "kubernetes/components/${comp_name}/namespace.yaml" ]; then
        echo "---" >> "${env_dir}/00-namespaces/namespaces.yaml"
        cat "kubernetes/components/${comp_name}/namespace.yaml" >> "${env_dir}/00-namespaces/namespaces.yaml"
    fi
done

printf "resources:\n  - namespaces.yaml\n" > "${env_dir}/00-namespaces/kustomization.yaml"

for dir in $(ls -d "${env_dir}"/*/ 2>/dev/null); do
    name=$(basename "${dir}")
    if [ "${name}" = "00-namespaces" ]; then
        continue
    fi
    if [ ! -d "kubernetes/components/${name}/${env}" ]; then
        rm -rf "${dir}"
    fi
done

{
    echo "resources:"
    echo "  - ./00-namespaces"
    for dir in $(ls -d "${env_dir}"/*/ 2>/dev/null | grep -v "/00-namespaces/$" | sort); do
        echo "  - ./$(basename "${dir}")"
    done
} > "${env_dir}/kustomization.yaml"
```

- [ ] **Step 2: Make script executable**

```bash
chmod +x scripts/kubernetes-hydrate/hydrate-index.sh
```

- [ ] **Step 3: Regression test against production**

```bash
rm -f kubernetes/manifests/production/kustomization.yaml
rm -rf kubernetes/manifests/production/00-namespaces
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --porcelain -- kubernetes/manifests/production/kustomization.yaml kubernetes/manifests/production/00-namespaces/
```

Expected: 出力は空（再生成された内容が committed 版と一致）

- [ ] **Step 4: Commit**

```bash
git add scripts/kubernetes-hydrate/hydrate-index.sh
git commit -s -m "feat(scripts/kubernetes-hydrate): add hydrate-index.sh"
```

---

## Task 3: Update reusable--kubernetes-hydrator.yaml to use new scripts

**Files:**
- Modify: `.github/workflows/reusable--kubernetes-hydrator.yaml` lines 66-79

- [ ] **Step 1: Read current state of the two `run:` blocks**

```bash
sed -n '66,80p' .github/workflows/reusable--kubernetes-hydrator.yaml
```

Confirm the two blocks call `make -C kubernetes hydrate-component` and `make -C kubernetes hydrate-index`.

- [ ] **Step 2: Replace the "Hydrate changed components" step**

Edit `.github/workflows/reusable--kubernetes-hydrator.yaml`. Replace:

```yaml
      - name: Hydrate changed components
        env:
          SERVICES_JSON: ${{ inputs.services }}
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: |
          set -euo pipefail
          for svc in $(echo "$SERVICES_JSON" | jq -r '.[]'); do
            make -C kubernetes hydrate-component COMPONENT="$svc" ENV="${{ inputs.environment }}"
          done
```

with:

```yaml
      - name: Hydrate changed components
        env:
          SERVICES_JSON: ${{ inputs.services }}
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: |
          set -euo pipefail
          for svc in $(echo "$SERVICES_JSON" | jq -r '.[]'); do
            bash scripts/kubernetes-hydrate/hydrate-component.sh "$svc" "${{ inputs.environment }}"
          done
```

- [ ] **Step 3: Replace the "Hydrate index" step**

In the same file, replace:

```yaml
      - name: Hydrate index
        env:
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: make -C kubernetes hydrate-index ENV=${{ inputs.environment }}
```

with:

```yaml
      - name: Hydrate index
        env:
          AQUA_CONFIG: ${{ github.workspace }}/.github/aqua.yaml
        run: bash scripts/kubernetes-hydrate/hydrate-index.sh "${{ inputs.environment }}"
```

- [ ] **Step 4: Verify no other workflow references the Makefile**

```bash
git grep -nE 'make -C kubernetes|kubernetes/Makefile' .github/
```

Expected: 出力は空

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/reusable--kubernetes-hydrator.yaml
git commit -s -m "ci(kubernetes-hydrator): call bash scripts instead of make targets"
```

---

## Task 4: Delete kubernetes/Makefile

**Files:**
- Delete: `kubernetes/Makefile`

- [ ] **Step 1: Verify Makefile is no longer referenced**

```bash
git grep -n 'make -C kubernetes\|kubernetes/Makefile' .
```

Expected: README.md にのみ hit する（README は Task 9 で削除予定）。`.github/` には hit しない。

- [ ] **Step 2: Delete the file**

```bash
git rm kubernetes/Makefile
```

- [ ] **Step 3: Commit**

```bash
git commit -s -m "chore(kubernetes): remove Makefile (logic moved to scripts/kubernetes-hydrate/)"
```

---

## Task 5: Remove local environment from workflow-config.yaml

**Files:**
- Modify: `workflow-config.yaml` lines 1-6

順序: 後続 task で `components/*/local/` を削除する。その時点で CI matrix が `local` を含み続けると hydrate workflow が空配列を受け取って失敗するため、components 削除より前に matrix から除外する必要がある。

- [ ] **Step 1: Edit workflow-config.yaml**

Replace:

```yaml
environments:
  - environment: local
    # local environment is kubernetes-only
    stacks:
      kubernetes: {}

  - environment: develop
```

with:

```yaml
environments:
  - environment: develop
```

- [ ] **Step 2: Verify result**

```bash
grep -nE '^\s*-\s*environment:' workflow-config.yaml
```

Expected: 2 行のみ hit (`develop`, `production`)

- [ ] **Step 3: Commit**

```bash
git add workflow-config.yaml
git commit -s -m "chore(workflow-config): remove local environment entry"
```

---

## Task 6: Delete local environment trees

**Files:**
- Delete: `kubernetes/clusters/local/`
- Delete: `kubernetes/components/*/local/` (11 ディレクトリ)
- Delete: `kubernetes/manifests/local/`

11 component の local ディレクトリ: beyla, cilium, coredns, dashboard, fluent-bit, gateway-api, loki, opentelemetry, opentelemetry-collector, prometheus-operator, tempo

- [ ] **Step 1: Delete `kubernetes/clusters/local/`**

```bash
git rm -r kubernetes/clusters/local
```

- [ ] **Step 2: Delete all `kubernetes/components/*/local/` directories**

```bash
for comp in beyla cilium coredns dashboard fluent-bit gateway-api loki opentelemetry opentelemetry-collector prometheus-operator tempo; do
    git rm -r "kubernetes/components/${comp}/local"
done
```

- [ ] **Step 3: Remove now-empty component parent dirs**

`coredns/` と `fluent-bit/` は local 以外のサブディレクトリを持たないため、`local/` を削除すると親ディレクトリが空になる。空のままだと「使われていない component が存在する」誤解を生むので、親ごと削除する。git は空ディレクトリを tracked しないので `rmdir` で十分（git status には影響しない）。

```bash
rmdir kubernetes/components/coredns
rmdir kubernetes/components/fluent-bit
```

Expected: エラーなし（両ディレクトリが空であることが確認できる）

- [ ] **Step 4: Delete `kubernetes/manifests/local/`**

```bash
git rm -r kubernetes/manifests/local
```

- [ ] **Step 5: Verify all local-related directories are gone**

```bash
find kubernetes -type d -name local
```

Expected: 出力は空（`clusters/local`, `manifests/local`, `components/*/local` のいずれも残っていない）

```bash
ls -d kubernetes/components/coredns kubernetes/components/fluent-bit 2>&1
```

Expected: 両方とも `No such file or directory` エラー

- [ ] **Step 6: Verify production manifests untouched**

```bash
git status --porcelain -- kubernetes/manifests/production/
```

Expected: 出力は空（production 側は触っていない）

- [ ] **Step 7: Commit**

```bash
git commit -s -m "chore(kubernetes): remove local environment (clusters, components, manifests)"
```

---

## Task 7: Update kubernetes/helmfile.yaml.gotmpl

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl` lines 14-19, 43

- [ ] **Step 1: Remove the `local:` environment block**

Edit `kubernetes/helmfile.yaml.gotmpl`. Replace:

```yaml
environments:
  local:
    values:
      - cluster:
          name: k8s-local
          isLocal: true
  production:
```

with:

```yaml
environments:
  production:
```

- [ ] **Step 2: Remove `isLocal` from the production block**

In the same file, find:

```yaml
      - cluster:
          name: eks-production
          isLocal: false
```

and replace with:

```yaml
      - cluster:
          name: eks-production
```

- [ ] **Step 3: Verify `isLocal` no longer appears anywhere**

```bash
git grep -n 'isLocal' kubernetes/
```

Expected: 出力は空

- [ ] **Step 4: Regression test — production hydrate is byte-identical**

```bash
for comp_dir in kubernetes/components/*/production/; do
    comp=$(basename "$(dirname "${comp_dir}")")
    bash scripts/kubernetes-hydrate/hydrate-component.sh "${comp}" production
done
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --porcelain -- kubernetes/manifests/production/
```

Expected: 出力は空（helmfile.yaml.gotmpl の編集は production の hydrate 結果を変えていない）

- [ ] **Step 5: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "chore(kubernetes/helmfile): remove local environment and isLocal value"
```

---

## Task 8: Update kubernetes/README.md

**Files:**
- Modify: `kubernetes/README.md` lines 138-256 (the entire `## 🚀 Local Development` section through to but not including `## 🏢 Production Operations`)
- Modify: `kubernetes/README.md` line 122 (sentence about local PVC backend)

- [ ] **Step 1: Identify exact range of `## 🚀 Local Development` section**

```bash
awk 'NR==138, NR==256' kubernetes/README.md | head -3
awk 'NR==138, NR==256' kubernetes/README.md | tail -3
```

Confirm the range starts with `## 🚀 Local Development` and ends with the last line before `## 🏢 Production Operations` (line 257).

- [ ] **Step 2: Delete the `## 🚀 Local Development` section**

Edit `kubernetes/README.md`. Remove lines 138-256 inclusive. The line immediately after the removal should be `## 🏢 Production Operations` (which was line 257).

- [ ] **Step 3: Remove the "local 環境では..." sentence**

In the same file, find the line:

```
local 環境では同じ backend が local PVC で動作する (= dev サイクル短期 retention で S3 不要)。production-specific な storage choice。
```

and remove it entirely (the whole sentence including trailing newline). The bullet list above (`- **durability**: ...` etc.) explains why production uses S3; the comparison to local is no longer relevant.

- [ ] **Step 4: Verify the section headers are correct after edits**

```bash
grep -nE '^##\s' kubernetes/README.md
```

Expected: `## Overview`, `## 🏗️ Architecture`, `## 💡 Design principles`, `## 🏢 Production Operations`, `## Incident investigation examples` 等が並び、`## 🚀 Local Development` は存在しない。

- [ ] **Step 5: Verify k3d / *.local hostname references are gone**

```bash
git grep -nE 'k3d|\.local\b' kubernetes/README.md
```

Expected: 出力は空（k3d への参照と `grafana.local` / `hubble.local` 等のホスト名が消えている）

- [ ] **Step 6: Verify other local mentions are only the "node-local" sense**

```bash
git grep -n 'local' kubernetes/README.md
```

Expected: hit は "local PVC (gp3 EBS)" や "EBS は AZ-local" 等の **node/AZ ローカルの意味** のみ。「local 環境」「local cluster」「local development」のような **環境** を指す用例は残っていない。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "docs(kubernetes/README): remove Local Development section"
```

---

## Task 9: Final Verification

**Files:** No file changes. Pure verification.

- [ ] **Step 1: Grep — k3d / isLocal must be gone**

```bash
git grep -nE 'k3d|isLocal' kubernetes/ .github/ workflow-config.yaml 2>/dev/null
```

Expected: 出力は空

- [ ] **Step 2: Grep — manual review of remaining `local` hits in kubernetes/**

```bash
git grep -n 'local' kubernetes/
```

Expected: hit はあっても production の説明文中の一般用語（"local PVC"、"AZ-local"）のみ。環境を指す "local 環境" / "local cluster" / "local development" 等が無いことを目視確認。

- [ ] **Step 3: Verify no Makefile references remain**

```bash
git grep -nE 'make -C kubernetes|kubernetes/Makefile' .
```

Expected: 出力は空

- [ ] **Step 4: Verify clusters/components/manifests have only production**

```bash
ls kubernetes/clusters/ kubernetes/manifests/
ls -d kubernetes/components/*/
```

Expected: clusters/manifests には `production` のみ。components は 22 component dir が全て残る（local subdir は削除済みだが component dir 自体は production subdir を持つ）。

- [ ] **Step 5: Full regression — hydrate all production components and verify zero diff**

```bash
for comp_dir in kubernetes/components/*/production/; do
    comp=$(basename "$(dirname "${comp_dir}")")
    bash scripts/kubernetes-hydrate/hydrate-component.sh "${comp}" production
done
bash scripts/kubernetes-hydrate/hydrate-index.sh production
git status --porcelain -- kubernetes/manifests/production/
```

Expected: 出力は空（全 production hydrate が byte-identical に再生成され、`Makefile` から script への移行と local 削除を経ても production の挙動が変わっていない）

- [ ] **Step 6: Push and open Draft PR**

```bash
git push -u origin remove-local-env
gh pr create --draft --title "chore: remove local environment" \
  --body "$(cat <<'EOF'
## Summary

Remove the local (k3d) environment from kubernetes/ and consolidate hydrate logic into bash scripts.

See spec: `docs/superpowers/specs/2026-05-13-remove-local-env-design.md`
See plan: `docs/superpowers/plans/2026-05-13-remove-local-env.md`

## Changes

- New: `scripts/kubernetes-hydrate/{hydrate-component,hydrate-index}.sh` extracted from `kubernetes/Makefile`
- CI: `reusable--kubernetes-hydrator.yaml` calls bash scripts instead of `make`
- Removed: `kubernetes/Makefile`, `kubernetes/clusters/local/`, `kubernetes/components/*/local/` (11), `kubernetes/manifests/local/`
- Updated: `kubernetes/helmfile.yaml.gotmpl` (drop local env + isLocal), `workflow-config.yaml` (drop local env), `kubernetes/README.md` (drop Local Development section)

## Verification

- All production hydrate outputs are byte-identical to pre-PR state (`git status` clean after `bash scripts/kubernetes-hydrate/hydrate-component.sh ...` for all components + `hydrate-index.sh production`)
- `git grep -nE 'k3d|isLocal' kubernetes/ .github/ workflow-config.yaml` returns nothing
EOF
)"
```

---

## Out of Scope (do not implement in this plan)

- `clusters/`, `components/`, `manifests/` の production 側構造変更
- 既存 production component の values 修正
- README.md の production 部分のリライト（local 章削除以外）
- 将来 spec で予定されている `scripts/eks-lifecycle/60-flux-bootstrap.sh` の実装
