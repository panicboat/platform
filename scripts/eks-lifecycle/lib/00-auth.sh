#!/usr/bin/env bash
# 00-auth.sh - Use operator's IAM principal for AWS calls + assume admin role for kubectl.
#
# Design spec §3 Decision 1 prerequisite: operator's IAM principal has
# sufficient AWS permissions for terragrunt apply/destroy. panicboat IAM
# user holds AdministratorAccess.
#
# The GitHub OIDC apply role (= github-oidc-auth-${ENV}-github-actions-apply-role)
# trust policy allows only sts:AssumeRoleWithWebIdentity from GitHub Actions
# tokens — it cannot be assumed from an IAM user, so we use the operator's
# default credential chain directly for terragrunt operations.
#
# Sets:
#   - ADMIN_CREDS_FILE (= /tmp file with eks-admin-${ENV} STS session creds)
#   - CLUSTER_EXISTS (= "true" or "false", consumed by 10-k8s-cleanup.sh)
#   - CREDS_EXPIRE_FILE (= UNIX epoch of admin creds expiration, for re-source)
#   - ~/.kube/config (= updated by `aws eks update-kubeconfig` via admin role assume;
#     KUBECONFIG env not exported)
#
# Idempotent: re-sourcing refreshes admin credentials with a new assume.

# Source common.sh from same directory
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"

require_env
require_cmd aws jq kubectl

# Capture operator's original AWS credentials env state so use_apply_creds
# can restore it after use_admin_creds temporarily overrides the env.
ORIG_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
ORIG_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
ORIG_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
export ORIG_AWS_ACCESS_KEY_ID ORIG_AWS_SECRET_ACCESS_KEY ORIG_AWS_SESSION_TOKEN

REGION="$(resolve_aws_region)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

ADMIN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/eks-admin-${ENV}"

info "Operator IAM principal: ${CALLER_ARN}"

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

# Save admin creds to a temp file (= AWS STS session credentials; protect with 0600 to avoid world-read leakage on shared /tmp)
ADMIN_CREDS_FILE="/tmp/eks-lifecycle-admin-creds-$$"
( umask 077 && : > "$ADMIN_CREDS_FILE" )
echo "$ADMIN_CREDS" > "$ADMIN_CREDS_FILE"
export ADMIN_CREDS_FILE

ADMIN_EXPIRATION=$(echo "$ADMIN_CREDS" | jq -r .Expiration)
date -d "$ADMIN_EXPIRATION" +%s 2>/dev/null > "$CREDS_EXPIRE_FILE" || \
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${ADMIN_EXPIRATION%+*}+0000" +%s > "$CREDS_EXPIRE_FILE"

ok "Admin role credentials valid until: $ADMIN_EXPIRATION"

# Update kubeconfig + verify cluster reachability with admin creds in a
# sub-shell. kubectl exec plugin (= aws eks get-token) inherits caller's
# AWS env at invocation time、 so the reachability check (= `kubectl get
# nodes`) must also run inside the same subshell where admin creds are
# active. 親 shell の operator IAM principal は EKS aws-auth に未登録の
# ケースが多く、 subshell 外で kubectl test すると 401 で誤判定される。
(
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
  AWS_SESSION_TOKEN=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if aws eks update-kubeconfig --region "$REGION" --name "eks-${ENV}" >/dev/null 2>&1 && \
     kubectl get nodes >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
) && CLUSTER_REACHABLE="true" || CLUSTER_REACHABLE="false"

if [ "$CLUSTER_REACHABLE" = "true" ]; then
  ok "Cluster reachable via admin role"
  export CLUSTER_EXISTS="true"
else
  warn "Cluster not reachable (= already destroyed?). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
fi

# Helper for sub-scripts that need admin credentials (= kubectl ops in 60/70).
# Split declare + assign so jq failure (= file corrupted) propagates under set -e.
use_admin_creds() {
  if [ -f "$ADMIN_CREDS_FILE" ]; then
    local _id _secret _token
    _id=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
    _secret=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
    _token=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
    export AWS_ACCESS_KEY_ID="$_id"
    export AWS_SECRET_ACCESS_KEY="$_secret"
    export AWS_SESSION_TOKEN="$_token"
  fi
}

# Restore operator's default credential state for terragrunt operations.
# When operator uses AWS_PROFILE / IAM Identity Center / instance profile,
# unsetting AWS_*_KEY env returns the SDK to its default lookup chain.
# When operator had AWS_*_KEY set directly, restore the captured values.
use_apply_creds() {
  if [ -n "${ORIG_AWS_ACCESS_KEY_ID}" ]; then
    export AWS_ACCESS_KEY_ID="$ORIG_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$ORIG_AWS_SECRET_ACCESS_KEY"
    if [ -n "${ORIG_AWS_SESSION_TOKEN}" ]; then
      export AWS_SESSION_TOKEN="$ORIG_AWS_SESSION_TOKEN"
    else
      unset AWS_SESSION_TOKEN
    fi
  else
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
  fi
}

# Default to operator credentials for terragrunt operations
use_apply_creds
