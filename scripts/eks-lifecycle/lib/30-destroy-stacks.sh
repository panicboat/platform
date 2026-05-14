#!/usr/bin/env bash
# 30-destroy-stacks.sh - Destroy 8 EKS-related stacks in fixed order.
#
# Order:
#   karpenter -> eks-secrets -> eks-logs -> eks-metrics -> eks-traces
#   -> eks -> alb -> vpc
#
# Each stack runs `terragrunt destroy -auto-approve`. On failure, fail
# fast with a diagnostic. 30s sleep between stacks for AWS API
# eventual consistency.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd terragrunt tofu

STACKS=(
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks"
  "alb"
  "vpc"
)

confirm "About to DESTROY 8 stacks for ENV=${ENV}. Continue?"

for stack in "${STACKS[@]}"; do
  info "Step 30.${stack}: terragrunt destroy aws/${stack}/envs/${ENV}"

  # Refresh credentials if expiring soon
  if creds_expiring_soon; then
    info "Credentials expiring soon, re-assuming..."
    # shellcheck source=lib/00-auth.sh
    . "${LIB_DIR}/00-auth.sh"
  fi

  if ! ( cd "${REPO_ROOT}/aws/${stack}/envs/${ENV}" && \
         run env TG_TF_PATH=tofu terragrunt destroy -auto-approve ); then
    error "terragrunt destroy failed at aws/${stack}. Manually inspect:
    cd aws/${stack}/envs/${ENV} && TG_TF_PATH=tofu terragrunt destroy
After resolving, re-run: make eks-teardown-aws ENV=${ENV}"
    exit 1
  fi

  ok "${stack} destroyed"

  if [ "${DRY_RUN:-0}" != "1" ]; then
    info "Sleeping 30s for AWS API eventual consistency..."
    sleep 30
  fi
done

ok "All 8 stacks destroyed"
