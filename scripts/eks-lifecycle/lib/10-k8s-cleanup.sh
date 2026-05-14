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

info "Step 10.3: Deleting Karpenter NodePools (= EC2 drain + terminate)"
if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
  run kubectl delete nodepools.karpenter.sh --all --timeout=300s || warn "NodePool deletion incomplete"
fi

info "Step 10.4: Waiting for Karpenter nodes to be removed"
if [ "${DRY_RUN:-0}" != "1" ]; then
  if kubectl get nodes -l karpenter.sh/nodepool >/dev/null 2>&1; then
    kubectl wait nodes -l karpenter.sh/nodepool --for=delete --timeout=600s || \
      warn "Karpenter nodes did not all drain in 600s. Manually run: kubectl get nodes -l karpenter.sh/nodepool; kubectl delete node <name> --force"
  fi
fi

info "Step 10.5: Sanity check - listing remaining pods"
run kubectl get pods -A -o wide || true

ok "k8s cleanup complete"
