# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks-metrics"
    Owner       = "panicboat"
  }
}
