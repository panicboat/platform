include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../modules"
}

locals {
  monorepo          = read_terragrunt_config("monorepo.hcl")
  platform          = read_terragrunt_config("platform.hcl")
  deploy_actions    = read_terragrunt_config("deploy-actions.hcl")
  panicboat_actions = read_terragrunt_config("panicboat-actions.hcl")
  ansible           = read_terragrunt_config("ansible.hcl")
  dotfiles          = read_terragrunt_config("dotfiles.hcl")
}

inputs = {
  repositories = {
    monorepo          = local.monorepo.locals.repository
    platform          = local.platform.locals.repository
    deploy-actions    = local.deploy_actions.locals.repository
    panicboat-actions = local.panicboat_actions.locals.repository
    ansible           = local.ansible.locals.repository
    dotfiles          = local.dotfiles.locals.repository
  }
  github_token = get_env("GITHUB_TOKEN")
}
