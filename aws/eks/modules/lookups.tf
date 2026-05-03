# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}

module "route53" {
  source = "../../route53/lookup"
}
