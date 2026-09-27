module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
