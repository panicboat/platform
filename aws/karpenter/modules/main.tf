# main.tf - Karpenter AWS-side infrastructure (Pod Identity authentication).
#
# This module provisions everything Karpenter needs in AWS:
# 1. Karpenter sub-module: SQS interruption queue + EventBridge rules +
#    Controller IAM role + EKS Pod Identity Association + Node IAM role +
#    EC2 Instance Profile.
# 2. karpenter_bootstrap MNG: A small EKS managed node group (t4g.small × 2)
#    that hosts only the Karpenter controller pod itself (chicken-and-egg
#    bootstrap problem). All other workloads run on Karpenter NodePool-
#    managed Graviton 4 on-demand instances after Plan 2 migration.
#
# Plan 2 では capacity-type=on-demand のみだが、SQS/EventBridge も
# provision することで将来 spot NodePool 追加時の AWS infra 変更を
# 不要にする (Future Specs: workload-spot NodePool 参照)。
#
# Authentication mode は Pod Identity を採用 (sub-module v21.19.0 default)。
# Pod Identity Association が karpenter:karpenter ServiceAccount を IAM role
# に紐付けるため、Helm chart の serviceAccount.annotations に IRSA 情報を
# 入れる必要がない。

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.19.0"

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

  # Node role: SSM Session Manager access (no SSH key, port 22 closed)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.common_tags
}

# karpenter_bootstrap managed node group.
#
# Standalone eks-managed-node-group submodule (not part of `module "eks"`)
# because we want Karpenter-related AWS resources to live in this stack
# rather than aws/eks/. See Plan 2 spec Decision 5 for rationale.

module "karpenter_bootstrap" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.19.0"

  name         = "karpenter_bootstrap"
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
  # cross-node pod traffic (e.g., bootstrap pod → CoreDNS on system node) to
  # be silently dropped. Sourced from aws/eks/lookup via tag-based discovery.
  vpc_security_group_ids = [module.eks.cluster.node_security_group_id]

  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = var.bootstrap_instance_types
  capacity_type  = "ON_DEMAND"

  min_size     = var.bootstrap_min_size
  max_size     = var.bootstrap_max_size
  desired_size = var.bootstrap_desired_size

  block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = var.bootstrap_disk_size
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }

  labels = {
    "node-role/karpenter-bootstrap" = "true"
  }

  taints = {
    karpenter-controller = {
      key    = "karpenter.sh/controller"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  update_config = {
    max_unavailable_percentage = 33
  }

  iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Same rationale as system MNG: CNI permissions are granted via IRSA
  # (vpc-cni IRSA bound to aws-node ServiceAccount), not via the node
  # IAM role.
  iam_role_attach_cni_policy = false

  tags = var.common_tags
}
