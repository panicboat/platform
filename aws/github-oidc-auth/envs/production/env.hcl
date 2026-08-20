# env.hcl - Production environment configuration
locals {
  # Environment metadata
  environment = "production"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org  = "panicboat"
  github_repos = ["monorepo","platform"]

  # GitHub environments that can assume the role
  github_environments = [
    "production"
  ]

  # Additional IAM policies for production (if needed)
  additional_iam_policies = [
    # Example: Add specific policies for production environment
    # "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  # OIDC provider settings
  # 専用アカウントなので provider も自前で持つ (= develop / master も同様)。
  create_oidc_provider = true
  oidc_provider_arn    = ""

  # Session duration (4 hours for production)
  max_session_duration = 14400

  # Hosted zone は管理アカウントに残しているため、plan 時の
  # data.aws_route53_zone 解決に cross-account assume が要る。
  assume_role_arns = [
    "arn:aws:iam::559744160976:role/route53-zone-access",
  ]

  # Production-specific resource tags
  additional_tags = {
    Component  = "github-oidc-auth"
    Owner      = "panicboat"
  }
}
