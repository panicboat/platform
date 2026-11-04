include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

terraform {
  source = "../modules"
}

# Environment-specific inputs
inputs = {
  aws_region              = include.env.locals.aws_region
  github_org              = include.env.locals.github_org
  github_repos            = include.env.locals.github_repos
  github_environments     = include.env.locals.github_environments
  additional_iam_policies = include.env.locals.additional_iam_policies
  create_oidc_provider    = include.env.locals.create_oidc_provider
  oidc_provider_arn       = include.env.locals.oidc_provider_arn
  max_session_duration    = include.env.locals.max_session_duration
  assume_role_arns        = include.env.locals.assume_role_arns
}
