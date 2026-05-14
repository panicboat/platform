#!/usr/bin/env bash
# 40-orphan-verify.sh - Detect orphan AWS resources after teardown.
#
# Reports (does NOT delete) any resources tagged with the production EKS
# environment that survived terragrunt destroy. Exits non-zero if any
# orphan is found, with example deletion commands for the operator.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/00-auth.sh
. "${LIB_DIR}/00-auth.sh"

require_env
require_cmd aws jq

REGION="$(resolve_aws_region)"
ORPHAN_FOUND=0

info "Step 40.1: ENI (= VPC CNI / Cilium / ALB controller / Karpenter)"
ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=tag:Project,Values=eks" "Name=tag:Environment,Values=${ENV}" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
if [ -n "$ENI_IDS" ]; then
  warn "Orphan ENIs: $ENI_IDS"
  warn "  delete: aws ec2 delete-network-interface --network-interface-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.2: EBS volumes (= released by PVC reclaimPolicy=Delete)"
EBS_IDS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:KubernetesCluster,Values=eks-${ENV}" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text)
if [ -n "$EBS_IDS" ]; then
  warn "Orphan EBS volumes: $EBS_IDS"
  warn "  delete: aws ec2 delete-volume --volume-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.3: Target groups (= ALB controller created)"
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName, 'k8s-')].TargetGroupArn" --output text)
if [ -n "$TG_ARNS" ]; then
  warn "Orphan target groups: $TG_ARNS"
  warn "  delete: aws elbv2 delete-target-group --target-group-arn <arn>"
  ORPHAN_FOUND=1
fi

info "Step 40.4: Security groups"
# shellcheck disable=SC2016
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:Environment,Values=${ENV}" "Name=tag:Project,Values=eks" \
  --query 'SecurityGroups[?GroupName != `default`].GroupId' --output text)
if [ -n "$SG_IDS" ]; then
  warn "Orphan SGs: $SG_IDS"
  warn "  delete: aws ec2 delete-security-group --group-id <id>"
  ORPHAN_FOUND=1
fi

info "Step 40.5: Route53 stale external-dns records"
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name panicboat.net --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')
if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
  STALE_RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?starts_with(Name, '_external-dns.') || (Type == 'A' && contains(Name, '.panicboat.net'))].[Name,Type]" \
    --output text)
  if [ -n "$STALE_RECORDS" ]; then
    warn "Stale Route53 records (= external-dns owned, not auto-cleaned):"
    # shellcheck disable=SC2001
    echo "$STALE_RECORDS" | sed 's/^/    /'
    warn "  delete: aws route53 change-resource-record-sets --hosted-zone-id ${HOSTED_ZONE_ID} --change-batch ..."
    ORPHAN_FOUND=1
  fi
fi

info "Step 40.6: CloudWatch log groups"
LG_NAMES=$(aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/eks/eks-${ENV}" \
  --query 'logGroups[].logGroupName' --output text)
if [ -n "$LG_NAMES" ]; then
  warn "Orphan CloudWatch log groups: $LG_NAMES"
  warn "  delete: aws logs delete-log-group --log-group-name <name>"
  ORPHAN_FOUND=1
fi

if [ "$ORPHAN_FOUND" -eq 1 ]; then
  error "Orphan resources detected. Resolve manually using the delete commands above, then re-run make eks-teardown-verify to confirm."
  exit 1
fi

ok "No orphan resources detected. Teardown complete."
