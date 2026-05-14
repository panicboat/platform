#!/usr/bin/env bash
# 50-apply-stacks.sh - Apply 8 EKS-related stacks in fixed order.
#
# Order:
#   vpc -> alb -> eks -> karpenter -> eks-secrets
#   -> eks-logs -> eks-metrics -> eks-traces
#
# Each stack runs `terragrunt apply -auto-approve`. On failure, fail
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
  "vpc"
  "alb"
  "eks"
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
)

confirm "About to APPLY 8 stacks for ENV=${ENV}. Continue?"

for stack in "${STACKS[@]}"; do
  info "Step 50.${stack}: terragrunt apply aws/${stack}/envs/${ENV}"

  # Refresh credentials if expiring soon
  if creds_expiring_soon; then
    info "Credentials expiring soon, re-assuming..."
    # shellcheck source=lib/00-auth.sh
    . "${LIB_DIR}/00-auth.sh"
  fi

  if ! ( cd "${REPO_ROOT}/aws/${stack}/envs/${ENV}" && \
         run env TG_TF_PATH=tofu terragrunt apply -auto-approve ); then
    error "terragrunt apply failed at aws/${stack}. Common causes:
  - eventual consistency (= retry after 30s)
  - missing dependency from previous stack
Manually inspect:
  cd aws/${stack}/envs/${ENV} && TG_TF_PATH=tofu terragrunt apply
After resolving, re-run: make eks-recreate-aws ENV=${ENV}"
    exit 1
  fi

  ok "${stack} applied"

  if [ "${DRY_RUN:-0}" != "1" ]; then
    info "Sleeping 30s for AWS API eventual consistency..."
    sleep 30
  fi
done

ok "All 8 stacks applied"
