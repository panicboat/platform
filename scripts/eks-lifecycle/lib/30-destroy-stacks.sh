#!/usr/bin/env bash
# 30-destroy-stacks.sh - Destroy 9 EKS-related stacks in fixed order.
#
# Order:
#   eks-karpenter -> eks-holmesgpt -> eks-secrets -> eks-logs -> eks-metrics
#   -> eks-traces -> eks -> alb -> vpc
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

REGION="$(resolve_aws_region)"

# Step 10.4 (10-k8s-cleanup.sh) sweeps ALB/NLB tagged elbv2.k8s.aws/cluster
# once, early in the pipeline. When multiple Ingresses share one ALB via
# IngressGroup, `kubectl delete ingress --all` deleting them one-by-one can
# race the controller into recreating the shared ALB (+ its auto-created
# security groups) after that sweep already ran, leaving it orphaned once
# the controller itself is gone. The recreate window closes for good once
# the `eks` stack is destroyed (no controller left to reconcile), so that
# is the last safe point to sweep before it blocks `alb`/`vpc` destroy with
# IGW-detach / subnet-delete DependencyViolation errors.
sweep_lb_controller_orphans() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    return 0
  fi

  use_apply_creds  # = need elbv2 / ec2 API permissions (= operator's chain)

  local lb_arns sg_ids
  lb_arns=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --resource-type-filters "elasticloadbalancing:loadbalancer" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=eks-${ENV}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text)
  if [ -n "$lb_arns" ]; then
    warn "Found leftover load balancers (post-cluster-destroy): $lb_arns — force-deleting."
    for arn in $lb_arns; do
      aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >/dev/null
    done
    for arn in $lb_arns; do
      while aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" >/dev/null 2>&1; do
        sleep 5
      done
    done
    ok "Leftover load balancers deleted."
  fi

  # AWS Load Balancer Controller tags its auto-created security groups
  # (frontend + backend/traffic) with the same elbv2.k8s.aws/cluster key;
  # these are not terraform-managed so `terragrunt destroy` never sees them.
  sg_ids=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=eks-${ENV}" \
    --query 'SecurityGroups[].GroupId' --output text)
  if [ -n "$sg_ids" ]; then
    warn "Found leftover ALB controller security groups: $sg_ids — deleting."
    for sg in $sg_ids; do
      aws ec2 delete-security-group --region "$REGION" --group-id "$sg"
    done
    ok "Leftover ALB controller security groups deleted."
  fi
}

# eks-holmesgpt は eks より前に置く必要がある。同 stack の module "eks" が
# `data "aws_eks_cluster"` で cluster を名前引きしており、cluster 削除後に
# destroy すると plan 生成時点で "couldn't find resource" になって落ちる
# (= 順序を誤ると `-refresh=false` を付けた手動 destroy が必要になる)。
STACKS=(
  "eks-karpenter"
  "eks-holmesgpt"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks"
  "alb"
  "vpc"
)

confirm "About to DESTROY 9 stacks for ENV=${ENV}. Continue?"

for stack in "${STACKS[@]}"; do
  info "Step 30.${stack}: terragrunt destroy aws/${stack}/${ENV}"

  # Refresh credentials if expiring soon
  if creds_expiring_soon; then
    info "Credentials expiring soon, re-assuming..."
    # shellcheck source=lib/00-auth.sh
    . "${LIB_DIR}/00-auth.sh"
  fi

  if ! ( cd "${REPO_ROOT}/aws/${stack}/${ENV}" && \
         run env TG_TF_PATH=tofu terragrunt destroy -auto-approve ); then
    error "terragrunt destroy failed at aws/${stack}. Manually inspect:
    cd aws/${stack}/${ENV} && TG_TF_PATH=tofu terragrunt destroy
After resolving, re-run: make eks-teardown-aws ENV=${ENV}"
    exit 1
  fi

  ok "${stack} destroyed"

  if [ "$stack" = "eks" ]; then
    sweep_lb_controller_orphans
  fi

  if [ "${DRY_RUN:-0}" != "1" ]; then
    info "Sleeping 30s for AWS API eventual consistency..."
    sleep 30
  fi
done

ok "All 9 stacks destroyed"
