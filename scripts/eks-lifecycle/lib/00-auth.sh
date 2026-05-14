#!/usr/bin/env bash
# 00-auth.sh - Assume apply role + admin role, configure kubeconfig.
#
# Sources common.sh for utilities. Sets:
#   - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
#     (= apply role credentials, used by terragrunt apply/destroy)
#   - KUBECONFIG (= updated to talk to eks-${ENV} via admin role assume)
#   - CLUSTER_EXISTS (= "true" or "false", consumed by 10-k8s-cleanup.sh)
#
# Idempotent: re-sourcing replaces credentials with a fresh assume.

# Source common.sh from same directory
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"

require_env
require_cmd aws jq kubectl

REGION="$(resolve_aws_region)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

APPLY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-oidc-auth-${ENV}-github-actions-apply-role"
ADMIN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/eks-admin-${ENV}"

info "Assuming apply role: ${APPLY_ROLE_ARN}"
APPLY_CREDS=$(aws sts assume-role \
  --role-arn "$APPLY_ROLE_ARN" \
  --role-session-name "eks-lifecycle-${USER:-debug}-$$" \
  --query Credentials \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$APPLY_CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$APPLY_CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$APPLY_CREDS" | jq -r .SessionToken)
EXPIRATION=$(echo "$APPLY_CREDS" | jq -r .Expiration)
date -d "$EXPIRATION" +%s 2>/dev/null > "$CREDS_EXPIRE_FILE" || \
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${EXPIRATION%+*}+0000" +%s > "$CREDS_EXPIRE_FILE"

ok "Apply role credentials valid until: $EXPIRATION"

info "Assuming admin role for kubectl: ${ADMIN_ROLE_ARN}"
if ! ADMIN_CREDS=$(aws sts assume-role \
  --role-arn "$ADMIN_ROLE_ARN" \
  --role-session-name "eks-lifecycle-admin-${USER:-debug}-$$" \
  --query Credentials \
  --output json 2>/dev/null); then
  warn "Admin role not found (= cluster may already be destroyed). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
  return 0 2>/dev/null || exit 0
fi

# Save admin creds to a temp file (separate from apply creds)
ADMIN_CREDS_FILE="/tmp/eks-lifecycle-admin-creds-$$"
echo "$ADMIN_CREDS" > "$ADMIN_CREDS_FILE"
export ADMIN_CREDS_FILE

# Use admin creds in a sub-shell to update kubeconfig
(
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
  AWS_SESSION_TOKEN=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if aws eks update-kubeconfig --region "$REGION" --name "eks-${ENV}" >/dev/null 2>&1; then
    exit 0
  else
    exit 1
  fi
) && CLUSTER_REACHABLE="true" || CLUSTER_REACHABLE="false"

if [ "$CLUSTER_REACHABLE" = "true" ] && kubectl get nodes >/dev/null 2>&1; then
  ok "Cluster reachable via admin role"
  export CLUSTER_EXISTS="true"
else
  warn "Cluster not reachable (= already destroyed?). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
fi

# Helper for sub-scripts that need admin credentials (= kubectl ops in 60/70)
use_admin_creds() {
  if [ -f "$ADMIN_CREDS_FILE" ]; then
    export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
    export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
    export AWS_SESSION_TOKEN=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
  fi
}

use_apply_creds() {
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<< "$APPLY_CREDS")
  export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<< "$APPLY_CREDS")
  export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<< "$APPLY_CREDS")
}

# Default to apply creds for terragrunt operations
use_apply_creds
