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

for dir in "${env_dir}"/*/; do
    [ -d "${dir}" ] || continue
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
    # Sort by full path so that name pairs sharing a prefix follow the path-separator
    # ordering (`-` < `/` in C locale → `opentelemetry-collector/` precedes
    # `opentelemetry/`). Sorting bare names instead would invert this pair.
    for dir in "${env_dir}"/*/; do
        [ -d "${dir}" ] || continue
        name=$(basename "${dir}")
        [ "${name}" = "00-namespaces" ] && continue
        printf '%s\n' "${dir}"
    done | LC_ALL=C sort | while IFS= read -r dir; do
        echo "  - ./$(basename "${dir}")"
    done
} > "${env_dir}/kustomization.yaml"
