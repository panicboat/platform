#!/usr/bin/env bash
# 00-auth.sh - Assume into the environment's dedicated AWS account for both
# terragrunt destroy and kubectl (admin role) operations.
#
# production lives in its own member account under the panicboat
# Organization since the account-separation migration; the operator's
# default identity (management account IAM user) has no direct
# AdministratorAccess there anymore, so every operation hops through
# OrganizationAccountAccessRole first. This mirrors the fix applied to
# eks-login.sh for the same root cause (直接 assume は AccessDenied).
#
# The GitHub OIDC apply role (= github-oidc-auth-${ENV}-github-actions-apply-role)
# trust policy allows only sts:AssumeRoleWithWebIdentity from GitHub Actions
# tokens — it cannot be assumed from an IAM user, so this script drives
# terragrunt with the OrganizationAccountAccessRole hop instead.
#
# Sets:
#   - ADMIN_CREDS_FILE (= /tmp file with eks-admin-${ENV} STS session creds)
#   - APPLY_CREDS_FILE (= /tmp file with OrganizationAccountAccessRole STS session creds, used for terragrunt)
#   - CLUSTER_EXISTS (= "true" or "false", consumed by 10-k8s-cleanup.sh)
#   - CREDS_EXPIRE_FILE (= UNIX epoch of admin creds expiration, for re-source)
#   - ~/.kube/config (= updated by `aws eks update-kubeconfig` via admin role assume;
#     KUBECONFIG env not exported)
#
# Idempotent: re-sourcing refreshes both credential sets with a new assume.

# Source common.sh from same directory
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"

require_env
require_cmd aws jq kubectl

# Environment -> dedicated AWS account ID. require_env already restricts
# ENV to "production"; keep this a case (not a bare literal) so a future
# ENV addition fails loudly here instead of silently reusing the wrong account.
case "${ENV}" in
  production) TARGET_ACCOUNT_ID="337169763788" ;;
  *)          error "no account mapping for ENV='${ENV}'"; exit 1 ;;
esac

# Helper for sub-scripts that need admin credentials (= kubectl ops in 10/60/70).
# Split declare + assign so jq failure (= file corrupted) propagates under set -e.
# Defined before the admin-role assume attempt so that CLUSTER_EXISTS=false 経路
# (= 10-k8s-cleanup.sh の AWS-API fallback など) からも safe に呼び出せる。
use_admin_creds() {
  if [ -n "${ADMIN_CREDS_FILE:-}" ] && [ -f "$ADMIN_CREDS_FILE" ]; then
    local _id _secret _token
    _id=$(jq -r .AccessKeyId "$ADMIN_CREDS_FILE")
    _secret=$(jq -r .SecretAccessKey "$ADMIN_CREDS_FILE")
    _token=$(jq -r .SessionToken "$ADMIN_CREDS_FILE")
    export AWS_ACCESS_KEY_ID="$_id"
    export AWS_SECRET_ACCESS_KEY="$_secret"
    export AWS_SESSION_TOKEN="$_token"
  fi
}

# Switch to OrganizationAccountAccessRole credentials for terragrunt
# operations (= AdministratorAccess-equivalent within the target account).
use_apply_creds() {
  if [ -n "${APPLY_CREDS_FILE:-}" ] && [ -f "$APPLY_CREDS_FILE" ]; then
    local _id _secret _token
    _id=$(jq -r .AccessKeyId "$APPLY_CREDS_FILE")
    _secret=$(jq -r .SecretAccessKey "$APPLY_CREDS_FILE")
    _token=$(jq -r .SessionToken "$APPLY_CREDS_FILE")
    export AWS_ACCESS_KEY_ID="$_id"
    export AWS_SECRET_ACCESS_KEY="$_secret"
    export AWS_SESSION_TOKEN="$_token"
  fi
}

# The panicboat.net hosted zone stays in the management account (master)
# even though production lives in its own member account; external-dns
# itself reaches it the same way, via route53-zone-access
# (trust policy: arn:aws:iam::337169763788:root, i.e. any permitted
# principal in the production account). Callers that need to inspect or
# clean up Route53 records (10-k8s-cleanup.sh Step 10.8,
# 40-orphan-verify.sh Step 40.5) must use this instead of use_apply_creds,
# whose credentials have no cross-account Route53 access.
use_route53_creds() {
  use_apply_creds
  local _creds
  _creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::559744160976:role/route53-zone-access" \
    --role-session-name "eks-lifecycle-route53-${USER:-debug}-$$" \
    --query Credentials --output json)
  export AWS_ACCESS_KEY_ID=$(echo "$_creds" | jq -r .AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$_creds" | jq -r .SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$_creds" | jq -r .SessionToken)
}

REGION="$(resolve_aws_region)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"

info "Operator IAM principal: ${CALLER_ARN}"

ORG_ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
info "Assuming ${ORG_ROLE_ARN} for terragrunt operations"
APPLY_CREDS=$(aws sts assume-role \
  --role-arn "$ORG_ROLE_ARN" \
  --role-session-name "eks-lifecycle-apply-${USER:-debug}-$$" \
  --query Credentials \
  --output json)
APPLY_CREDS_FILE="/tmp/eks-lifecycle-apply-creds-$$"
( umask 077 && : > "$APPLY_CREDS_FILE" )
echo "$APPLY_CREDS" > "$APPLY_CREDS_FILE"
export APPLY_CREDS_FILE

ADMIN_ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/eks-admin-${ENV}"

info "Assuming admin role for kubectl: ${ADMIN_ROLE_ARN}"
if ! ADMIN_CREDS=$(
  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId "$APPLY_CREDS_FILE") \
  AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey "$APPLY_CREDS_FILE") \
  AWS_SESSION_TOKEN=$(jq -r .SessionToken "$APPLY_CREDS_FILE") \
  aws sts assume-role \
    --role-arn "$ADMIN_ROLE_ARN" \
    --role-session-name "eks-lifecycle-admin-${USER:-debug}-$$" \
    --query Credentials \
    --output json 2>/dev/null
); then
  warn "Admin role not found (= cluster may already be destroyed). Setting CLUSTER_EXISTS=false."
  export CLUSTER_EXISTS="false"
  use_apply_creds
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

# Default to operator credentials for terragrunt operations
use_apply_creds
