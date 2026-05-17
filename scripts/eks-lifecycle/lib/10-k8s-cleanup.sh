#!/usr/bin/env bash
# 10-k8s-cleanup.sh - Pre-teardown k8s resource cleanup.
#
# Deletes Ingress / LoadBalancer Service / PVC / Karpenter NodePool to
# release AWS resources (target groups / ENIs / EBS volumes / EC2
# instances / external-dns Route53 records) BEFORE we run terragrunt
# destroy on the EKS cluster itself. Skipped if cluster is not reachable,
# except for the AWS-API fallbacks which run regardless to mop up
# resources whose owning controller is already gone.

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
  # StatefulSet delete (= helmfile destroy 等) は PVC を残す default 仕様。
  # ここで明示削除しないと NodePool drain 後に EBS が 'available' で残り、
  # 後段 terragrunt eks destroy で IAM/CSI controller が消えると orphan 化する。
  # cluster + ebs-csi-driver pod が alive なうちに reclaim を走らせる必要がある (= Step 10.5 NodePool delete より前)。
  run kubectl delete pvc --all -A --timeout=600s || warn "PVC deletion incomplete (= will rely on AWS-tag fallback in Step 10.7)"
fi

info "Step 10.4: AWS-tag fallback — delete leftover ALB / NLB tagged for this cluster"
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
  if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
    use_admin_creds  # = back to kubectl creds
  fi
fi

if [ "${CLUSTER_EXISTS:-}" = "true" ]; then
  info "Step 10.5: Deleting Karpenter NodePools (= synchronous EC2 drain + terminate via --cascade=foreground)"
  # --cascade=foreground waits for owned NodeClaims (= and their EC2 instances)
  # to be deleted before returning. This avoids the historical failure mode where
  # NodePool delete returned immediately while leaving EC2 alive, eventually
  # stranded after karpenter stack destroy (= controller gone, no terminate path).
  if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
    run kubectl delete nodepools.karpenter.sh --all --cascade=foreground --timeout=600s || \
      warn "NodePool foreground deletion incomplete (= will rely on AWS-tag fallback below)"
  fi
fi

info "Step 10.6: AWS-tag fallback — terminate any leftover Karpenter EC2 (= NodePool already gone but instances still alive)"
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
fi

info "Step 10.7: AWS-tag fallback — delete leftover EBS volumes tagged for this cluster"
# StatefulSet delete が PVC を残した場合、 Step 10.3 で kubectl が届かない (= cluster 既消失)
# 経路でも EBS は 'available' で生存する。 ebs-csi-driver は dynamic PVC volume に
# tag:KubernetesCluster=<name> を付与するため、 controller 不在でも tag 経由で回収できる。
if [ "${DRY_RUN:-0}" != "1" ]; then
  REGION="$(resolve_aws_region)"
  use_apply_creds  # = need EC2 permissions (= operator's chain)
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
# external-dns は cluster 内で動作し A/AAAA/CNAME 削除を Ingress finalizer 経由で実行する。
# Ingress 削除 (= Step 10.1) 時点で external-dns pod が未稼働 (= 既 destroy / pending) だった
# 場合、 Route53 上に owner=eks-${ENV} marker の TXT registry record + 対応 A/AAAA/CNAME が
# 残る。 cluster destroy 後は external-dns 経路で消せないので、 ownership marker tag を頼りに
# AWS API で直接削除する。
if [ "${DRY_RUN:-0}" != "1" ]; then
  use_apply_creds  # = need route53 permissions (= operator's chain)
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name panicboat.net --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')
  if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
    # external-dns の TXT registry name format は "<rtype>-<host>" (= txtPrefix 未設定時の default)。
    # ownership marker (= heritage=external-dns,external-dns/owner=eks-<env>) を持つ TXT を起点に、
    # 関連 A/AAAA/CNAME (= prefix 除去で導出した host name) を集めて一括 DELETE する。
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
  use_admin_creds  # = back to kubectl creds for sanity check
  info "Step 10.9: Sanity check - listing remaining pods"
  run kubectl get pods -A -o wide || true
fi

ok "k8s cleanup complete"
