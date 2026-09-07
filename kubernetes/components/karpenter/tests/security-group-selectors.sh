#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
rendered_file="$(mktemp)"
selector_file="$(mktemp)"
trap 'rm -f "$rendered_file" "$selector_file"' EXIT

kustomize build \
  "$repository_root/kubernetes/components/karpenter/production/kustomization" \
  >"$rendered_file"

awk '
  /^  securityGroupSelectorTerms:$/ { capture = 1; next }
  capture && /^  [A-Za-z]/ { exit }
  capture { print }
' "$rendered_file" >"$selector_file"

test "$(grep -c '^  - tags:$' "$selector_file")" -eq 2
grep -Fxq '      aws:eks:cluster-name: eks-production' "$selector_file"
grep -Fxq '      Name: private-trust-production' "$selector_file"

if grep -Fq 'kubernetes.io/cluster/' "$selector_file"; then
  echo "The private trust selector must not use a Kubernetes cluster tag." >&2
  exit 1
fi

echo "Security group selector contract passed."
