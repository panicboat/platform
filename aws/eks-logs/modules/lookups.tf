# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
