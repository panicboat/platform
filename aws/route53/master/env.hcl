# env.hcl - Environment-specific configuration for master

locals {
  # Environment-specific settings
  environment = "master"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # route53-zone-access を assume する側のアカウント。
  production_account_id = "337169763788"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "route53"
    Owner       = "panicboat"
  }
}
