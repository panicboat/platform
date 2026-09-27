# EC2 Spot SLR is managed in iam-service-linked-roles as an account-level singleton.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.1"

  cluster_name = module.eks.cluster.name

  create_pod_identity_association = true

  namespace       = "karpenter"
  service_account = "karpenter"

  # Inline policy raises limit to 10,240 characters to prevent IAM policy size overflow.
  enable_inline_policy = true

  # Disables name prefix to keep node IAM role name deterministic across recreations.
  node_iam_role_name            = "Karpenter-eks-${var.environment}"
  node_iam_role_use_name_prefix = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.common_tags
}

# Filters private subnets to a single AZ to minimize cross-AZ traffic costs.
data "aws_subnets" "system_critical_az" {
  filter {
    name   = "vpc-id"
    values = [module.vpc.vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.compute_availability_zone]
  }
  tags = {
    Tier = "private"
  }
}

module "system_critical" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.25.1"

  name         = "eks-${var.environment}-system-critical"
  cluster_name = module.eks.cluster.name

  # Explicit cluster parameters required because standalone MNG does not auto-wire them.
  cluster_endpoint     = module.eks.cluster.endpoint
  cluster_auth_base64  = module.eks.cluster.certificate_authority_data
  cluster_service_cidr = module.eks.cluster.service_cidr
  cluster_ip_family    = module.eks.cluster.ip_family

  subnet_ids = data.aws_subnets.system_critical_az.ids

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

  # Force update prevents rolling updates from stalling on PDB eviction failures.
  force_update_version = true

  iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # CNI policy omitted from node role because Cilium operator handles Pod IPAM directly.
  iam_role_attach_cni_policy = false

  # Stable name prefix allows runtime tooling discovery while preserving existing node group.
  iam_role_use_name_prefix = false

  tags = var.common_tags
}
