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

# EC2 Spot service-linked role (AWSServiceRoleForEC2Spot) は
# aws/ec2-spot-service-role で管理する (= account 単位 singleton かつ
# 複数 env 共有のため、per-env stack である eks-karpenter からは分離)。
# system-components NodePool の capacity-type [spot, on-demand] はこの role
# の存在を前提にする。

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

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
  version = "21.25.0"

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

  # The standalone module does not inherit cluster SG attachments, so both final SGs remain explicit.
  cluster_primary_security_group_id = module.eks.cluster.cluster_primary_security_group_id

  vpc_security_group_ids = [module.vpc.security_groups.private_trust.id]

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

  # The MNG base name is an external contract. `use_name_prefix` remains at
  # the module default to avoid replacing the existing MNG, so runtime tooling
  # resolves the generated physical name by its stable prefix.
  iam_role_use_name_prefix = false

  tags = var.common_tags
}
