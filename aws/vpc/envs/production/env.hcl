# env.hcl - Environment-specific configuration for production

locals {
  # Environment-specific settings
  environment = "production"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "platform-network"
    CostCenter  = "engineering"
    Owner       = "panicboat"
  }
}
