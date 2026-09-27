#!/usr/bin/env bash
# Runs terragrunt via OrganizationAccountAccessRole because OIDC role trust policy rejects IAM users.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"

require_env
require_cmd aws jq kubectl

# Case statement ensures unmapped future environments fail explicitly rather than defaulting.
case "${ENV}" in
  production) TARGET_ACCOUNT_ID="337169763788" ;;
  *)          error "no account mapping for ENV='${ENV}'"; exit 1 ;;
esac

# Separate declaration and assignment ensures jq command failure propagates under set -e.
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

# Assumes cross-account route53-zone-access in master account where panicboat.net hosted zone resides.
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

# Creates 0600 temp file to prevent world-read leakage of STS session credentials.
ADMIN_CREDS_FILE="/tmp/eks-lifecycle-admin-creds-$$"
( umask 077 && : > "$ADMIN_CREDS_FILE" )
echo "$ADMIN_CREDS" > "$ADMIN_CREDS_FILE"
export ADMIN_CREDS_FILE

ADMIN_EXPIRATION=$(echo "$ADMIN_CREDS" | jq -r .Expiration)
date -d "$ADMIN_EXPIRATION" +%s 2>/dev/null > "$CREDS_EXPIRE_FILE" || \
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${ADMIN_EXPIRATION%+*}+0000" +%s > "$CREDS_EXPIRE_FILE"

ok "Admin role credentials valid until: $ADMIN_EXPIRATION"

# Verifies reachability in subshell where admin creds are exported for kubectl exec plugin.
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

use_apply_creds
