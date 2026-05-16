#!/usr/bin/env bash
# =============================================================================
# Pod Identity Injection Detection (= 引き継ぎ事項 #15)
# =============================================================================
# Probe AWS EKS Pod Identity webhook が AWS_CONTAINER_CREDENTIALS_FULL_URI を
# 対象 Pod に inject しているか確認。 webhook timing race で env 不在のまま Pod
# が起動した場合 (= ESO / cilium-operator 等で observed) を検出する。
#
# Spec: docs/superpowers/specs/2026-05-17-pod-identity-injection-detection-design.md
#
# Usage:
#   eks-login           # = eks-admin role assume + AWS_ env vars export
#   bash check-pod-identity-injection.sh [cluster_name]
#
# 認証要件:
# - aws cli は eks:ListPodIdentityAssociations 権限が必要だが eks-admin role
#   には現在付与されていない (= 別 phase で role policy 修正検討)。 本 script は
#   `unset AWS_*` で IAM user creds に fallback して aws cli call、 kubectl は
#   eks-admin role env vars を保持した sub-shell で実行する mixed approach。
# - IAM user 側に AdministratorAccess (= AssumeRole + EKS describe 含む) が必要。
#
# Requires: aws cli / kubectl / jq
#
# Exit codes:
# - 0: 全 Pod injection OK
# - 1: 1 つ以上の Pod で env 不在 (= injection 失敗)
# - 2: tool 不在 / AWS API error
# =============================================================================

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

# eks-admin role env vars を保存 (= kubectl exec plugin で復元)
saved_key="${AWS_ACCESS_KEY_ID:-}"
saved_secret="${AWS_SECRET_ACCESS_KEY:-}"
saved_token="${AWS_SESSION_TOKEN:-}"

# 1. AWS から Pod Identity Association list 取得 (= IAM user creds 経由)
assocs=$(
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  aws eks list-pod-identity-associations \
    --cluster-name "$cluster_name" \
    --region "$region" \
    --query 'associations[].{ns:namespace,sa:serviceAccount}' \
    --output json
) || {
  echo "ERROR: aws eks list-pod-identity-associations failed (= IAM user creds で eks:ListPodIdentityAssociations 必要)" >&2
  exit 2
}

assoc_count=$(echo "$assocs" | jq 'length')
echo "Found $assoc_count Pod Identity Association(s)"
echo ""

# subshell scope 問題回避のため fail list を temp file に蓄積
fail_list=$(mktemp)
trap 'rm -f "$fail_list"' EXIT

# kubectl call は eks-admin role env vars で (= 上記 saved 値 が現在 env に残存)
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
