#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-workflow-config.yaml}"

errors="$(yq -o=json '.' "${config_path}" | jq -r --arg q "'" '
    .stacks | to_entries[]
    | select(.value.name == "terragrunt")
    | .key as $index
    | .value.environments | to_entries[]
    | select(.value.apply_trigger | IN("merge", "release") | not)
    | "::error::stacks[\($index)].environments.\(.key).apply_trigger must be merge or release (got \($q)\(.value.apply_trigger)\($q))"
')"

if [ -n "${errors}" ]; then
    echo "${errors}" >&2
    exit 1
fi
