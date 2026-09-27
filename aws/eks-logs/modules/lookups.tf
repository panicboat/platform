module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
