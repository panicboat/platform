# lookups.tf - External stack lookups.

# EKS cluster info (for Karpenter sub-module + controller_host MNG)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}

# VPC info (for controller_host MNG private subnet IDs)
module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
