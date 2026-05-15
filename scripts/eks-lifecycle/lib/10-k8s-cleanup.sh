#!/usr/bin/env bash
# 10-k8s-cleanup.sh - Pre-teardown k8s resource cleanup.
#
# Deletes Ingress / LoadBalancer Service / Karpenter NodePool to release
# AWS resources (target groups / ENIs / EC2 instances) BEFORE we run
# terragrunt destroy on the EKS cluster itself. Skipped if cluster is
# not reachable.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  warn "CLUSTER_EXISTS=false. Skipping k8s cleanup."
  exit 0
fi

use_admin_creds

info "Step 10.1: Deleting all Ingress resources (= ALB target group / ENI release; finalizer 完了まで最大 600s 待機)"
run kubectl delete ingress --all -A --timeout=600s || warn "ingress deletion incomplete (= will rely on AWS-tag fallback in Step 10.3)"

info "Step 10.2: Deleting LoadBalancer Services (= NLB / ENI release; finalizer 完了まで最大 600s 待機)"
run kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=600s || warn "LB service deletion incomplete (= will rely on AWS-tag fallback in Step 10.3)"

info "Step 10.3: AWS-tag fallback — delete leftover ALB / NLB tagged for this cluster"
# AWS Load Balancer Controller は ALB / NLB に tag:elbv2.k8s.aws/cluster=<name>
# を付与する。 Step 10.1 / 10.2 で finalizer が完了せず ALB / NLB が残った場合、
# 後段の Karpenter NodePool delete で ALB controller pod が巻き込まれて
# 残 finalizer が永久 stuck → terragrunt alb destroy が
# ACM cert in-use で fail する pattern (= 過去事故 patterns) を防ぐ。
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds  # = need elbv2 / tag API permissions (= operator's chain)
  LEFTOVER_LB_ARNS=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --resource-type-filters "elasticloadbalancing:loadbalancer" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=eks-${ENV}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text)
  if [ -n "$LEFTOVER_LB_ARNS" ]; then
    warn "Found leftover load balancers: $LEFTOVER_LB_ARNS — force-deleting."
    for arn in $LEFTOVER_LB_ARNS; do
      aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >/dev/null
    done
    info "Waiting for load balancers to fully delete (= listeners / cert references released)..."
    for arn in $LEFTOVER_LB_ARNS; do
      while aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" >/dev/null 2>&1; do
        sleep 5
      done
    done
    ok "Leftover load balancers deleted."
  else
    info "No leftover load balancers found."
  fi
  use_admin_creds  # = back to kubectl creds
fi

info "Step 10.4: Deleting Karpenter NodePools (= synchronous EC2 drain + terminate via --cascade=foreground)"
# --cascade=foreground waits for owned NodeClaims (= and their EC2 instances)
# to be deleted before returning. This avoids the historical failure mode where
# NodePool delete returned immediately while leaving EC2 alive, eventually
# stranded after karpenter stack destroy (= controller gone, no terminate path).
if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
  run kubectl delete nodepools.karpenter.sh --all --cascade=foreground --timeout=600s || \
    warn "NodePool foreground deletion incomplete (= will rely on AWS-tag fallback below)"
fi

info "Step 10.5: AWS-tag fallback — terminate any leftover Karpenter EC2 (= NodePool already gone but instances still alive)"
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds  # = need EC2 permissions (= operator's chain), not eks-admin (kubectl-only)
  LEFTOVER_IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
              "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$LEFTOVER_IDS" ]; then
    warn "Found leftover Karpenter-managed EC2: $LEFTOVER_IDS — force-terminating."
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "$REGION" --instance-ids $LEFTOVER_IDS >/dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $LEFTOVER_IDS
    ok "Leftover Karpenter EC2 terminated."
  else
    info "No leftover Karpenter EC2 found."
  fi
  use_admin_creds  # = back to kubectl creds for sanity check
fi

info "Step 10.6: Sanity check - listing remaining pods"
run kubectl get pods -A -o wide || true

ok "k8s cleanup complete"
