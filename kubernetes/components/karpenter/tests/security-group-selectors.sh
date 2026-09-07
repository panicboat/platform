#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
rendered_file="$(mktemp)"
resource_file="$(mktemp)"
trap 'rm -f "$rendered_file" "$resource_file"' EXIT

kustomize build \
  "$repository_root/kubernetes/components/karpenter/production/kustomization" \
  >"$rendered_file"

target_count="$(awk -v output="$resource_file" '
  BEGIN { RS = "---\\n" }
  /(^|\n)kind: EC2NodeClass\n/ && /(^|\n)metadata:\n  name: system-components\n/ {
    count++
    print > output
  }
  END { print count + 0 }
' "$rendered_file" | tail -n 1)"
test "$target_count" -eq 1

selector_count="$(awk '/^  securityGroupSelectorTerms:$/ { count++ } END { print count + 0 }' "$resource_file")"
test "$selector_count" -eq 1

actual_selectors="$(awk '
  /^  securityGroupSelectorTerms:$/ { capture = 1; next }
  capture && /^  [A-Za-z]/ { exit }
  capture { print }
' "$resource_file")"
expected_selectors="$(
  printf '%s\n' \
    '  - tags:' \
    '      aws:eks:cluster-name: eks-production' \
    '  - tags:' \
    '      Name: private-trust-production'
)"
test "$actual_selectors" = "$expected_selectors"

echo "Security group selector contract passed."
