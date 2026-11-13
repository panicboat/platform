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
  ansible        = read_terragrunt_config("ansible.hcl")
  dotfiles       = read_terragrunt_config("dotfiles.hcl")
  dot_github     = read_terragrunt_config("dot-github.hcl")
}

inputs = {
  repositories = {
    monorepo       = local.monorepo.locals.repository
    platform       = local.platform.locals.repository
    deploy-actions = local.deploy_actions.locals.repository
    ansible        = local.ansible.locals.repository
    dotfiles       = local.dotfiles.locals.repository
    dot-github     = local.dot_github.locals.repository
  }
  github_token = get_env("GITHUB_TOKEN")
}

# TODO: Remove after the first apply; kept out of modules because tofu test cannot import with mock providers.
generate "imports" {
  path      = "imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    import {
      for_each = { for k, v in var.repositories : k => v.name if contains(keys(v.variables), "APP_ID") }

      to = github_actions_variable.repository["$${each.key}/APP_ID"]
      id = "$${each.value}:APP_ID"
    }
  EOF
}
