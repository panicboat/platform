#!/usr/bin/env bash
set -euo pipefail

component="${1:?component name required}"
env="${2:?environment name required}"

cd "$(git rev-parse --show-toplevel)"

component_dir="kubernetes/components/${component}/${env}"
out_dir="kubernetes/manifests/${env}/${component}"

# Explicit --kube-version prevents template divergence caused by varying default helm binary versions.
env_hcl="aws/eks/${env}/env.hcl"
if [ ! -f "${env_hcl}" ]; then
    echo "hydrate-component.sh: ${env_hcl} not found; cannot determine cluster version" >&2
    exit 1
fi
kube_version=$(sed -n 's/^[[:space:]]*cluster_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${env_hcl}")
if [ -z "${kube_version}" ]; then
    echo "hydrate-component.sh: cluster_version not set in ${env_hcl}" >&2
    exit 1
fi

mkdir -p "${out_dir}"
: > "${out_dir}/manifest.yaml"

if [ -f "${component_dir}/helmfile.yaml" ]; then
    helmfile -f "${component_dir}/helmfile.yaml" -e "${env}" template \
        --include-crds --skip-tests --kube-version "${kube_version}" >> "${out_dir}/manifest.yaml"
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
