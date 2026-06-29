# main.tf - Karpenter AWS-side infrastructure (Pod Identity authentication).
#
# This module provisions everything Karpenter needs in AWS:
# 1. Karpenter sub-module: SQS interruption queue + EventBridge rules +
#    Controller IAM role + EKS Pod Identity Association + Node IAM role +
#    EC2 Instance Profile.
# 2. system_critical MNG: A small EKS managed node group (t4g.small × 2)
#    that hosts cluster bootstrap-critical workloads — Karpenter
#    controller (chicken-and-egg: Karpenter cannot provision the nodes
#    it itself runs on), cilium-operator (Cilium native CNI ENI mode で
#    cluster の Pod IPAM を全担当する control plane、Karpenter-provisioned
#    node が Ready になるためにも先に動いている必要あり), CoreDNS (cluster
#    内 DNS resolution の前提)。 application workload は Karpenter
#    NodePool-managed instances (system-components NodePool) で動く。
#
# capacity-type は system-components NodePool 側で [spot, on-demand] を
# 採用しており、SQS interruption queue が spot 中断 (2-min warning) を
# 受けて Karpenter controller が gracefully drain & replace する経路を
# 提供する。
#
# Authentication mode は Pod Identity を採用 (sub-module v21.19.0 default)。
# Pod Identity Association が karpenter:karpenter ServiceAccount を IAM role
# に紐付けるため、Helm chart の serviceAccount.annotations に IRSA 情報を
# 入れる必要がない。

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = module.eks.cluster.name

  create_pod_identity_association = true

  # Pod Identity Association namespace + service account (must match
  # kubernetes/components/karpenter/production/values.yaml.gotmpl)
  namespace       = "karpenter"
  service_account = "karpenter"

  # Karpenter v1.x の controller IAM policy は accumulated permissions により
  # standard IAM policy size limit (6,144 chars) を超過する。inline role
  # policy にすると 10,240 chars 上限になりエラー回避できる (sub-module の
  # variable description が直接このユースケースを推奨)。
  enable_inline_policy = true

  # Karpenter sub-module v21.19.0: by default node_iam_role_use_name_prefix = true
  # which appends a timestamp suffix. Setting both name + use_name_prefix=false yields
  # a deterministic name "Karpenter-eks-${var.environment}" that survives
  # destroy/recreate cycles. Required for kubernetes/helmfile.yaml.gotmpl exec
  # terragrunt output -raw node_role_name to be stable across recreates.
  node_iam_role_name            = "Karpenter-eks-${var.environment}"
  node_iam_role_use_name_prefix = false

  # Node role: SSM Session Manager access (no SSH key, port 22 closed)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.common_tags
}

# system_critical managed node group.
#
# Standalone eks-managed-node-group submodule (not part of `module "eks"`)
# because Karpenter-related AWS resources are scoped to this stack to keep
# EKS cluster management (aws/eks/) separate from workload scheduling infra.
# Karpenter controller / cilium-operator / CoreDNS をまとめて bootstrap-host
# 役割で持つため、karpenter stack 側に置く (= Karpenter MNG と同じ stack で
# lifecycle を共有させ、recreate 時の手数を減らす)。

module "system_critical" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.24.0"

  name         = "eks-${var.environment}-system-critical"
  cluster_name = module.eks.cluster.name

  # Cluster info required by AL2023 user data generator. The standalone
  # eks-managed-node-group submodule does NOT auto-wire these from the
  # cluster name (unlike when MNGs live inside `module "eks"`), so we
  # must pass them explicitly. Sourced from aws/eks/lookup module.
  cluster_endpoint     = module.eks.cluster.endpoint
  cluster_auth_base64  = module.eks.cluster.certificate_authority_data
  cluster_service_cidr = module.eks.cluster.service_cidr
  cluster_ip_family    = module.eks.cluster.ip_family

  subnet_ids = module.vpc.subnets.private.ids

  # Cluster primary SG must be attached to nodes for cluster API access
  cluster_primary_security_group_id = module.eks.cluster.cluster_security_group_id

  # Node SG (from parent module "eks") required for node-to-node pod-network
  # traffic. Standalone eks-managed-node-group submodule does NOT attach this
  # automatically (unlike when MNGs live inside `module "eks"`), causing
  # cross-node pod traffic (e.g., bootstrap-host pod → CoreDNS on the same
  # MNG) to be silently dropped. Sourced from aws/eks/lookup via tag-based
  # discovery.
  vpc_security_group_ids = [module.eks.cluster.node_security_group_id]

  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = var.system_critical_instance_types
  capacity_type  = "ON_DEMAND"

  min_size     = var.system_critical_min_size
  max_size     = var.system_critical_max_size
  desired_size = var.system_critical_desired_size

  block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = var.system_critical_disk_size
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }

  labels = {
    "node-role/system-critical" = "true"
  }

  # 役割を「Karpenter controller 専用」から「system-critical 全般」に拡張
  # したため、taint key も role-explicit に変更。 chart 側の tolerations
  # (Karpenter / cilium-operator / CoreDNS) を `dedicated=system-critical`
  # に揃える。
  taints = {
    system-critical = {
      key    = "dedicated"
      value  = "system-critical"
      effect = "NO_SCHEDULE"
    }
  }

  update_config = {
    max_unavailable_percentage = 33
  }

  # LT version 変更 (= 例: common_tags 経由の tag_specifications 更新) で MNG が
  # rolling update を trigger した際、 PDB が evict を阻止すると PodEvictionFailure
  # で update が Failed 状態で停止する。 force_update_version=true で PDB タイムアウト
  # 後に AWS が force kill して update を完遂させる。
  # system_critical workload (Karpenter / cilium-operator / CoreDNS) は stateless
  # で 1-2 分の forced restart を許容する設計。
  force_update_version = true

  iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Cilium native CNI (ENI mode) では Pod IPAM を cilium-operator が
  # IRSA 経由で実行するため、node IAM role に CNI policy を attach する
  # 必要はない。
  iam_role_attach_cni_policy = false

  # Use fixed IAM role name (not name_prefix) because the auto-generated
  # name_prefix would exceed the AWS IAM name_prefix 38-chars limit when
  # combined with the MNG name. With use_name_prefix=false, the sub-module
  # assigns a deterministic role name `eks-${var.environment}-system-critical-eks-node-group`
  # (within the 64-chars IAM role name limit).
  #
  # The AWS physical name `eks-${var.environment}-system-critical` is fixed
  # by external contract (eks-login script / dashboard references), so a
  # deterministic role name is used.
  #
  # Side effect: a fixed IAM role name is immutable, so a future rename of
  # this MNG would make create_before_destroy fail with a role-name conflict.
  # If renamed, destroy the old role first, then apply (a 2-step operation).
  iam_role_use_name_prefix = false

  tags = var.common_tags
}
