# env.hcl - Environment-specific configuration for develop

locals {
  # Environment-specific settings
  environment = "develop"

  # AWS configuration (Cost Optimization Hub / Compute Optimizer home region)
  aws_region = "us-east-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "cost-management"
    Owner       = "panicboat"
  }
}
