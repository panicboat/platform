locals {
  environment = "master"

  # AWS configuration (Cost Optimization Hub / Compute Optimizer home region)
  aws_region = "us-east-1"

  environment_tags = {
    Environment = local.environment
    Component   = "cost-management"
    Owner       = "panicboat"
  }
}
