locals {
  project_name = "workload-identity"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  project = read_terragrunt_config("${get_repo_root()}/gcp/project.hcl")
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket = "terragrunt-state-${get_aws_account_id()}"

    key    = "platform/gcp/workload-identity/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    dynamodb_table = "terragrunt-state-locks"

    encrypt = true
  }
}

terraform {
  extra_arguments "gcp_credentials" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = local.project.locals.terraform_env_vars
  }
}

inputs = {
  project_id = local.project.locals.project_id
}
