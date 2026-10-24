#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="${here}/.."
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; failures=$((failures + 1)); }
expect_contains() { if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1"; sed 's/^/# /' "$3"; fi; }
expect_absent() { if grep -qF -- "$2" "$3"; then fail "$1"; sed 's/^/# /' "$3"; else pass "$1"; fi; }

write_deployment() {
    local dir="$1" name="$2" image="$3"
    mkdir -p "${dir}/kustomization"
    printf 'resources:\n  - deployment.yaml\n' > "${dir}/kustomization/kustomization.yaml"
    cat > "${dir}/kustomization/deployment.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
spec:
  template:
    spec:
      containers:
        - name: ${name}
          image: ${image}
YAML
}

repo="${work}/repo"
mkdir -p "${repo}/scripts/kubernetes-hydrate" "${repo}/aws/eks/production"
cp "${scripts}"/hydrate-component.sh "${scripts}"/render-diff.sh "${scripts}"/summarize-manifest-diff.sh "${repo}/scripts/kubernetes-hydrate/"
printf 'locals {\n  cluster_version = "1.33"\n}\n' > "${repo}/aws/eks/production/env.hcl"
write_deployment "${repo}/kubernetes/components/demo/production" demo nginx:1.0
write_deployment "${repo}/kubernetes/components/gone/production" gone busybox:1.36
write_deployment "${repo}/kubernetes/components/untouched/production" untouched redis:7
touch "${repo}/kubernetes/components/demo/namespace.yaml"
git -C "${repo}" init -q -b main
git -C "${repo}" -c user.name=test -c user.email=test@example.com add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.com commit -q -m base

write_deployment "${repo}/kubernetes/components/demo/production" demo nginx:1.1
echo "# changed" >> "${repo}/kubernetes/components/demo/namespace.yaml"
git -C "${repo}" rm -q -r kubernetes/components/gone
write_deployment "${repo}/kubernetes/components/broken/staging" broken busybox:1.36
git -C "${repo}" -c user.name=test -c user.email=test@example.com add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.com commit -q -m head

out="${work}/out"
(cd "${repo}" && bash scripts/kubernetes-hydrate/render-diff.sh HEAD^ "${out}") > "${work}/stdout" 2>&1 || { fail "render-diff exits 0"; sed 's/^/# /' "${work}/stdout"; }
summary="${out}/summary.md"

expect_contains "lists a changed component" "## demo (production)" "${summary}"
expect_contains "reports the changed image" "| nginx | 1.0 | 1.1 |" "${summary}"
expect_contains "links the full diff" "production/demo/manifest.diff" "${summary}"
expect_contains "writes the full diff" "+      - image: nginx:1.1" "${out}/production/demo/manifest.diff"
expect_contains "lists a deleted component" "## gone (production)" "${summary}"
expect_contains "reports resources of a deleted component as removed" "- Deployment gone" "${summary}"
expect_contains "reports a render failure instead of aborting" "Rendering failed" "${summary}"
expect_absent "skips components without changes" "untouched" "${summary}"
if [ -z "$(git -C "${repo}" status --porcelain)" ] && [ "$(git -C "${repo}" worktree list | wc -l)" -eq 1 ]; then
    pass "leaves the checkout and worktree list clean"
else
    fail "leaves the checkout and worktree list clean"
    git -C "${repo}" status --porcelain | sed 's/^/# /'
fi

echo "# changed" >> "${repo}/README.md"
git -C "${repo}" -c user.name=test -c user.email=test@example.com add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.com commit -q -m docs
(cd "${repo}" && bash scripts/kubernetes-hydrate/render-diff.sh HEAD^ "${work}/out-none") > /dev/null 2>&1 || fail "render-diff exits 0 without components"
expect_contains "reports when no component changed" "No Kubernetes components changed." "${work}/out-none/summary.md"

exit "${failures}"
