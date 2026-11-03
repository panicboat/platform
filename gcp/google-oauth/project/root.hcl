locals {
  project     = read_terragrunt_config(find_in_parent_folders("project.hcl"))
  credentials = read_terragrunt_config("${get_repo_root()}/gcp/credentials.hcl")
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket = "terragrunt-state-${get_aws_account_id()}"

    key    = "platform/${get_path_from_repo_root()}/terraform.tfstate"
    region = "ap-northeast-1"

    dynamodb_table = "terragrunt-state-locks"

    encrypt = true
  }
}

terraform {
  extra_arguments "gcp_credentials" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = local.credentials.locals.terraform_env_vars
  }
}

inputs = {
  project_id = local.project.locals.project_id
}
