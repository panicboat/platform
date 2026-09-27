locals {
  environment = "master"

  aws_region = "ap-northeast-1"

  # Account allowed to assume route53-zone-access.
  production_account_id = "337169763788"

  environment_tags = {
    Environment = local.environment
    Component   = "route53"
    Owner       = "panicboat"
  }
}
