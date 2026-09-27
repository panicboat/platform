#!/usr/bin/env bash
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
    # Sort by full path in C locale so prefix pairs like opentelemetry-collector precede opentelemetry.
    for dir in "${env_dir}"/*/; do
        [ -d "${dir}" ] || continue
        name=$(basename "${dir}")
        [ "${name}" = "00-namespaces" ] && continue
        printf '%s\n' "${dir}"
    done | LC_ALL=C sort | while IFS= read -r dir; do
        echo "  - ./$(basename "${dir}")"
    done
} > "${env_dir}/kustomization.yaml"
