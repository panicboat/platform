# actions.hcl - GitHub Actions role configuration for develop

locals {
  # Repository names only (no org/ prefix). Full subject will be "repo:<org>/<repo>:*"
  github_repos = ["*"]

  oidc_provider_arn = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"
}
