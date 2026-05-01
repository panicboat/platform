# main.tf - EKS cluster composition via terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Disable Secrets envelope encryption (spec decision: Out of Scope).
  # v21.19.0 enables encryption by default when `encryption_config != null`,
  # which would auto-create a KMS key + IAM policy + attachment via the
  # `kms` submodule. Set to `null` to skip the entire encryption_config
  # block and avoid unwanted KMS resources.
  encryption_config = null

  # Populated in Task 6 / 7
  access_entries          = local.access_entries
  eks_managed_node_groups = {}
  addons                  = null

  tags = var.common_tags
}
