locals {
  environment = "production"

  aws_region = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Component   = "iam-service-linked-roles"
    Owner       = "panicboat"
  }
}
