# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
