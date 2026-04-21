# actions.hcl - GitHub Actions role configuration for develop

locals {
  # Repository names only (no org/ prefix). Full subject will be "repo:<org>/<repo>:*"
  github_repos = ["monorepo", "platform", "deploy-actions"]

  oidc_provider_arn = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"
}
