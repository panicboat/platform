#!/usr/bin/env bash
# 60-flux-bootstrap.sh - Prompt operator to update RECREATE-marked values,
# then re-hydrate, push to main, and apply Flux bootstrap manifests.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd kubectl flux git make grep

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  error "Cluster not reachable. Run make eks-recreate-aws ENV=${ENV} first."
  exit 1
fi

use_admin_creds

info "Step 60.1: Wait for system MNG nodes to be Ready"
run kubectl wait --for=condition=Ready node --all --timeout=300s

info "Step 60.2: List # RECREATE: markers in helmfile + kustomization sources"
# RECREATE marker convention is documented in kubernetes/helmfile.yaml.gotmpl:
#   # RECREATE: <command>
#   <key>: <value>
# Operator runs the command, replaces the next-line value.
echo ""
echo "================================================================="
echo " The following values must be updated MANUALLY before continuing."
echo " For each '# RECREATE: <command>' line, run the command and"
echo " replace the next line's value with the command's stdout."
echo "================================================================="
echo ""
RECREATE_FILES=$(grep -REl '# RECREATE:' \
  "${REPO_ROOT}/kubernetes/helmfile.yaml.gotmpl" \
  "${REPO_ROOT}/kubernetes/components" 2>/dev/null)
for f in $RECREATE_FILES; do
  rel="${f#"${REPO_ROOT}"/}"
  echo "## $rel"
  grep -n -B0 -A1 '# RECREATE:' "$f" | sed 's/^/  /'
  echo ""
done

if [ "${DRY_RUN:-0}" = "1" ]; then
  info "[DRY-RUN] Skipping operator prompt and downstream steps."
  exit 0
fi

confirm "Have you updated all RECREATE-marked values? (y to continue)"

info "Step 60.3: Audit pass - any RECREATE-marked file unchanged from origin/main?"
# Sanity check: warn if no RECREATE-marked file got modified. operator may
# have skipped editing.
DIFF_FILES=$(cd "$REPO_ROOT" && git diff --name-only origin/main -- kubernetes/ 2>/dev/null)
if [ -z "$DIFF_FILES" ]; then
  warn "No file changed under kubernetes/. Either values are already correct, or operator skipped editing."
  confirm "Continue anyway? (y to proceed)"
fi

info "Step 60.4: Re-hydrate kubernetes/manifests/${ENV}/"
use_apply_creds  # = hydrate may need terragrunt output (= legacy paths)
COMPONENTS=$(find "${REPO_ROOT}/kubernetes/components" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
for comp in $COMPONENTS; do
  if [ -d "${REPO_ROOT}/kubernetes/components/${comp}/${ENV}" ]; then
    info "Hydrating ${comp}..."
    run bash "${REPO_ROOT}/scripts/kubernetes-hydrate/hydrate-component.sh" "$comp" "$ENV"
  fi
done
run bash "${REPO_ROOT}/scripts/kubernetes-hydrate/hydrate-index.sh" "$ENV"

info "Step 60.5: Show diff and confirm git commit"
( cd "$REPO_ROOT" && run git status kubernetes/ )
( cd "$REPO_ROOT" && run git diff --stat kubernetes/ )

if [ -n "$(cd "$REPO_ROOT" && git status --porcelain kubernetes/)" ]; then
  confirm "Commit + push helmfile + hydrated manifests to main?"
  ( cd "$REPO_ROOT" && \
    git add kubernetes/ && \
    git commit -s -m "chore(kubernetes): refresh helmfile + manifests after cluster recreate

Phase 3 lifecycle script (60-flux-bootstrap.sh) で operator が
RECREATE-marked 値を手動更新後、hydrate を実行した結果。

Flux が次の reconcile で pickup する。" && \
    git push origin main )
else
  info "No changes (= helmfile values already match new cluster, recreate likely no-op)."
fi

use_admin_creds  # = back to admin for kubectl ops

info "Step 60.6: Apply Flux bootstrap manifests"
run kubectl apply -k "${REPO_ROOT}/kubernetes/clusters/${ENV}/"

info "Step 60.7: Wait for flux-system Kustomization to be Ready"
run kubectl wait kustomization/flux-system -n flux-system \
  --for=condition=Ready --timeout=300s

run flux get sources git -A
run flux get kustomizations -A

ok "Flux bootstrap complete"
