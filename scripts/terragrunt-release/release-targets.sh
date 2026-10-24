#!/usr/bin/env bash
set -euo pipefail

service="${1:?usage: release-targets.sh <service> [config_path]}"
config_path="${2:-workflow-config.yaml}"

candidates="$(yq -o=json '.' "${config_path}" | jq -c --arg service "${service}" '
    .stacks[]
    | select(.name == "terragrunt")
    | .environments | to_entries[]
    | select(.value.apply_trigger == "release")
    | {
        service: $service,
        environment: .key,
        working_directory: "aws/\($service)/\(.key)",
        aws_region: .value.aws_region,
        iam_role_plan: .value.iam_role_plan,
        iam_role_apply: .value.iam_role_apply
    }
')"

targets="$(
    while IFS= read -r candidate; do
        [ -n "${candidate}" ] || continue
        if [ -d "$(jq -r '.working_directory' <<<"${candidate}")" ]; then
            echo "${candidate}"
        fi
    done <<<"${candidates}" | jq -c -s '.'
)"

if [ "$(jq 'length' <<<"${targets}")" -eq 0 ]; then
    echo "::error::no release targets for ${service}" >&2
    exit 1
fi

echo "${targets}"
