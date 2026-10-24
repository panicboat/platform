#!/usr/bin/env bash
set -euo pipefail

service="${1:?usage: release-targets.sh <service> [config_path]}"
config_path="${2:-workflow-config.yaml}"

candidates="$(yq -o=json '.' "${config_path}" | jq -c --arg service "${service}" '
    .stacks[]
    | select(.name == "terragrunt")
    | (.exclude // []) as $exclude
    | .environments | to_entries[]
    | select(.value.apply_trigger == "release")
    | {service: $service, environment: .key} as $values
    | {
        service: $service,
        environment: .key,
        working_directory: "aws/\($service)/\(.key)",
        aws_region: .value.aws_region,
        iam_role_plan: .value.iam_role_plan,
        iam_role_apply: .value.iam_role_apply,
        excluded: any($exclude[]; to_entries | all(.[]; . as $pair | $values | has($pair.key) and .[$pair.key] == $pair.value))
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

jq -c 'map(select(.excluded | not) | del(.excluded))' <<<"${targets}"
