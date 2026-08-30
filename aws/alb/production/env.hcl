# env.hcl - Environment-specific configuration for production

locals {
  # Environment-specific settings
  environment = "production"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # 管理アカウントの hosted zone を操作するための assume 先。
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "alb"
    Owner       = "panicboat"
  }
}
