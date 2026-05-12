#!/usr/bin/env bash
# Hydrate a single Kubernetes component into kubernetes/manifests/<env>/<component>/.
#
# Behavior:
#   1. Run `helmfile template` if components/<component>/<env>/helmfile.yaml exists.
#   2. Append `kustomize build` output if components/<component>/<env>/kustomization/ exists.
#   3. Write a thin kustomization.yaml that points to manifest.yaml.
#   4. Suppress no-op churn: when the only diff against git is TLS material (cert-manager
#      regenerates ca.crt / ca.key / tls.crt / tls.key / caBundle every render), revert
#      the file so PRs do not accumulate noise commits.
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
