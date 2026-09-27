#!/usr/bin/env bash

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env

if [ "${CLUSTER_EXISTS:-}" != "true" ]; then
  warn "CLUSTER_EXISTS=false. Skipping cluster-side cleanup; running AWS-API fallbacks only."
fi

if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
  use_admin_creds

  info "Step 10.1: Deleting all Ingress resources (= ALB target group / ENI / external-dns Route53 release; finalizer 完了まで最大 600s 待機)"
  run kubectl delete ingress --all -A --timeout=600s || warn "ingress deletion incomplete (= will rely on AWS-tag fallback in Step 10.4)"

  info "Step 10.2: Deleting LoadBalancer Services (= NLB / ENI release; finalizer 完了まで最大 600s 待機)"
  run kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=600s || warn "LB service deletion incomplete (= will rely on AWS-tag fallback in Step 10.4)"

  info "Step 10.3: Deleting all PVCs (= ebs-csi-driver volume reclaim via reclaimPolicy=Delete; finalizer 完了まで最大 600s 待機)"
  # Explicitly delete PVCs to trigger volume reclaim before the CSI driver and nodes terminate.
  run kubectl delete pvc --all -A --timeout=600s || warn "PVC deletion incomplete (= will rely on AWS-tag fallback in Step 10.7)"
fi

info "Step 10.4: AWS-tag fallback — delete leftover ALB / NLB tagged for this cluster"
# FALLBACK: sweep tagged LBs directly to avoid orphan resources if controller finalizers hung.
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds
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
  if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
    use_admin_creds
  fi
fi

if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
  info "Step 10.5: Deleting Karpenter NodePools (= synchronous EC2 drain + terminate via --cascade=foreground)"
  # Foreground cascade ensures instances terminate before the controller itself is destroyed.
  if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
    run kubectl delete nodepools.karpenter.sh --all --cascade=foreground --timeout=600s || \
      warn "NodePool foreground deletion incomplete (= will rely on AWS-tag fallback below)"
  fi
fi

info "Step 10.6: AWS-tag fallback — terminate any leftover Karpenter EC2 (= NodePool already gone but instances still alive)"
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds
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
fi

info "Step 10.7: AWS-tag fallback — delete leftover EBS volumes tagged for this cluster"
# FALLBACK: sweep tagged available EBS volumes directly if PVC cleanup was unreachable.
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds
  LEFTOVER_VOL_IDS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:KubernetesCluster,Values=eks-${ENV}" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text)
  if [ -n "$LEFTOVER_VOL_IDS" ]; then
    warn "Found leftover EBS volumes: $LEFTOVER_VOL_IDS — force-deleting."
    for vol in $LEFTOVER_VOL_IDS; do
      aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
    done
    ok "Leftover EBS volumes deleted."
  else
    info "No leftover EBS volumes found."
  fi
fi

info "Step 10.8: AWS-API fallback — delete leftover external-dns Route53 records owned by this cluster"
# FALLBACK: delete Route53 records directly if external-dns pods were inactive during Ingress deletion.
if [ "${DRY_RUN:-0}" != "1" ]; then
  use_route53_creds
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name panicboat.net --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')
  if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
    # Derives associated records from TXT registry markers for atomic batch deletion.
    OWNED_BATCH=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --output json | \
      jq -c --arg owner "eks-${ENV}" '
        .ResourceRecordSets as $all
        | ($all | map(select(.Type == "TXT" and (.ResourceRecords | map(.Value) | join(" ") | contains("external-dns/owner=" + $owner))))) as $txt
        | ($txt | map(.Name | sub("^[a-z]+-"; "")) | unique) as $hosts
        | ($all | map(select((.Type == "A" or .Type == "AAAA" or .Type == "CNAME") and (.Name | IN($hosts[]))))) as $assoc
        | {Changes: (($txt + $assoc) | map({Action: "DELETE", ResourceRecordSet: .}))}
      ')
    OWNED_COUNT=$(echo "$OWNED_BATCH" | jq '.Changes | length')
    if [ "$OWNED_COUNT" -gt 0 ]; then
      warn "Found leftover external-dns Route53 records: ${OWNED_COUNT} entries — force-deleting."
      BATCH_FILE="/tmp/eks-lifecycle-route53-delete-$$.json"
      ( umask 077 && : > "$BATCH_FILE" )
      echo "$OWNED_BATCH" > "$BATCH_FILE"
      aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${BATCH_FILE}" >/dev/null
      rm -f "$BATCH_FILE"
      ok "Leftover external-dns Route53 records deleted."
    else
      info "No leftover external-dns Route53 records found."
    fi
  fi
fi

if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
  use_admin_creds
  info "Step 10.9: Sanity check - listing remaining pods"
  run kubectl get pods -A -o wide || true
fi

ok "k8s cleanup complete"
