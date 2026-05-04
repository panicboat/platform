# lookups.tf - External stack lookups.

# EKS cluster info (for Karpenter sub-module + bootstrap MNG)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}

# VPC info (for bootstrap MNG private subnet IDs)
module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
