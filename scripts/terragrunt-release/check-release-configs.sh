#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_path="${1:-workflow-config.yaml}"

# release-targets.sh stderr is hidden below, so an unreadable config would otherwise look like "no release services"
yq '.' "${config_path}" >/dev/null

failed=0

report() {
    echo "::error::$*" >&2
    failed=1
}

shopt -s nullglob
for service_dir in aws/*/; do
    service="$(basename "${service_dir}")"
    package="aws/${service}"
    config_file="${package}/release-please-config.json"
    manifest_file="${package}/release-please-manifest.json"

    if ! targets="$(bash "${script_dir}/release-targets.sh" "${service}" "${config_path}" 2>/dev/null)"; then
        if [ -f "${config_file}" ]; then
            report "${config_file} exists but ${service} has no release environment"
        fi
        continue
    fi

    incomplete="$(jq -r '
        .[] | . as $target
        | ("aws_region", "iam_role_plan", "iam_role_apply") as $field
        | select(($target[$field] // "") == "")
        | "::error::release target \($target.service)/\($target.environment) has no \($field)"
    ' <<<"${targets}")"
    if [ -n "${incomplete}" ]; then
        echo "${incomplete}" >&2
        failed=1
    fi

    if [ ! -f "${config_file}" ]; then
        report "${config_file} is missing but ${service} has a release environment"
        continue
    fi

    component="$(jq -r --arg package "${package}" '.packages[$package].component // ""' "${config_file}")"
    if [ "${component}" != "${service}" ]; then
        report "${package}: component must be ${service} (got '${component}')"
    fi

    if [ ! -f "${manifest_file}" ] || ! jq -e --arg package "${package}" 'has($package)' "${manifest_file}" >/dev/null; then
        report "${manifest_file} must have the key ${package}"
    fi
done

exit "${failed}"
