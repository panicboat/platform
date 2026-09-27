#!/usr/bin/env bash

# Probes whether Pod Identity webhook injected AWS_CONTAINER_CREDENTIALS_FULL_URI into matching pods.

set -euo pipefail

cluster_name="${1:-eks-production}"
region="${AWS_REGION:-ap-northeast-1}"

for cmd in aws kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd not found in PATH" >&2
    exit 2
  fi
done

echo "Probing Pod Identity injection on cluster=$cluster_name region=$region"
echo ""

# Saved credentials allow restoring eks-admin context after unsetting AWS env vars.
saved_key="${AWS_ACCESS_KEY_ID:-}"
saved_secret="${AWS_SECRET_ACCESS_KEY:-}"
saved_token="${AWS_SESSION_TOKEN:-}"

# Unset role credentials to query EKS associations using caller IAM credentials.
assocs=$(
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  aws eks list-pod-identity-associations \
    --cluster-name "$cluster_name" \
    --region "$region" \
    --query 'associations[].{ns:namespace,sa:serviceAccount}' \
    --output json
) || {
  echo "ERROR: aws eks list-pod-identity-associations failed" >&2
  exit 2
}

assoc_count=$(echo "$assocs" | jq 'length')
echo "Found $assoc_count Pod Identity Association(s)"
echo ""

# Accumulate failures across subshell loop in temp file.
fail_list=$(mktemp)
trap 'rm -f "$fail_list"' EXIT

echo "$assocs" | jq -c '.[]' | while read -r assoc; do
  ns=$(echo "$assoc" | jq -r '.ns')
  sa=$(echo "$assoc" | jq -r '.sa')

  pods=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
    jq -r --arg sa "$sa" '.items[] | select(.spec.serviceAccountName == $sa) | .metadata.name') || pods=""

  if [ -z "$pods" ]; then
    echo "INFO: ns=$ns sa=$sa: no Pods using this SA"
    continue
  fi

  for pod in $pods; do
    has_creds=$(kubectl get pod -n "$ns" "$pod" -o json | \
      jq '[.spec.containers[].env? // [] | .[] | select(.name == "AWS_CONTAINER_CREDENTIALS_FULL_URI")] | length')

    if [ "$has_creds" = "0" ]; then
      echo "FAIL: ns=$ns sa=$sa pod=$pod: AWS_CONTAINER_CREDENTIALS_FULL_URI not injected"
      echo "$ns/$pod" >> "$fail_list"
    else
      echo "OK:   ns=$ns sa=$sa pod=$pod"
    fi
  done
done

echo ""

fail_count=$(wc -l < "$fail_list" | tr -d ' ')
if [ "$fail_count" != "0" ]; then
  echo "Detected $fail_count Pod(s) without Pod Identity env injection" >&2
  exit 1
fi

echo "All Pod Identity associated Pods have AWS_CONTAINER_CREDENTIALS_FULL_URI injected"
