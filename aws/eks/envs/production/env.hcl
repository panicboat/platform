# env.hcl - Environment-specific configuration for production

locals {
  # Environment-specific settings
  environment = "production"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # EKS Kubernetes version
  # renovate: datasource=endoflife-date depName=amazon-eks versioning=loose
  cluster_version = "1.36-eks-3"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "eks"
    Owner       = "panicboat"
  }
}
