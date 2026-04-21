# actions.hcl - GitHub Actions role configuration for develop

locals {
  github_repos = ["monorepo", "platform", "deploy-actions"]

  oidc_provider_arn = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"
}
