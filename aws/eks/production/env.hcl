locals {
  environment = "production"

  aws_region = "ap-northeast-1"

  # renovate: datasource=endoflife-date depName=amazon-eks versioning=loose
  cluster_version = "1.37"

  # Role assumed to manage hosted zones in the management account.
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"

  environment_tags = {
    Environment = local.environment
    Component   = "eks"
    Owner       = "panicboat"
  }
}
