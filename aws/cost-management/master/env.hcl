# env.hcl - Environment-specific configuration for master

locals {
  # Environment-specific settings
  environment = "master"

  # AWS configuration (Cost Optimization Hub / Compute Optimizer home region)
  aws_region = "us-east-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "cost-management"
    Owner       = "panicboat"
  }
}
