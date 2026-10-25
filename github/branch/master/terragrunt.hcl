include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

locals {
  monorepo       = read_terragrunt_config("monorepo.hcl")
  platform       = read_terragrunt_config("platform.hcl")
  deploy_actions = read_terragrunt_config("deploy-actions.hcl")
  dot_github     = read_terragrunt_config("dot-github.hcl")
}

inputs = {
  repositories = {
    monorepo       = local.monorepo.locals.repository
    platform       = local.platform.locals.repository
    deploy-actions = local.deploy_actions.locals.repository
    dot-github     = local.dot_github.locals.repository
  }
  github_token = get_env("GITHUB_TOKEN")
}
