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

# Charts branch on .Capabilities.KubeVersion (opentelemetry-operator selects the
# nodes/pods vs nodes/proxy RBAC rule at >=1.33, for one). Without --kube-version helm
# substitutes a built-in default that tracks the helm release rather than the cluster:
# helm 3.17.3 reports v1.32.0 and helm 4.2.3 reports v1.36.0. Leaving it implicit makes
# the rendered output depend on which helm binary ran, and renders capability-gated
# templates against the wrong Kubernetes version. Take the version from the Terraform
# stack that owns the cluster so there is one source for it.
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
