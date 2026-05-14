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

info "Step 10.1: Deleting all Ingress resources (= ALB target group / ENI release)"
run kubectl delete ingress --all -A --timeout=180s || warn "ingress deletion incomplete (= some may need manual finalizer removal)"

info "Step 10.2: Deleting LoadBalancer Services (= NLB / ENI release)"
run kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=180s || warn "LB service deletion incomplete"

info "Step 10.3: Deleting Karpenter NodePools (= synchronous EC2 drain + terminate via --cascade=foreground)"
# --cascade=foreground waits for owned NodeClaims (= and their EC2 instances)
# to be deleted before returning. This avoids the historical failure mode where
# NodePool delete returned immediately while leaving EC2 alive, eventually
# stranded after karpenter stack destroy (= controller gone, no terminate path).
if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
  run kubectl delete nodepools.karpenter.sh --all --cascade=foreground --timeout=600s || \
    warn "NodePool foreground deletion incomplete (= will rely on AWS-tag fallback below)"
fi

info "Step 10.4: AWS-tag fallback — terminate any leftover Karpenter EC2 (= NodePool already gone but instances still alive)"
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

info "Step 10.5: Sanity check - listing remaining pods"
run kubectl get pods -A -o wide || true

ok "k8s cleanup complete"
