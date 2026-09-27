locals {
  project_name = "secrets-manager"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "secrets-manager"
    Team        = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket = "terragrunt-state-${get_aws_account_id()}"

    key    = "platform/secrets-manager/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    dynamodb_table = "terragrunt-state-locks"

    encrypt = true
  }
}

inputs = {
  environment = local.environment
  common_tags = local.common_tags
}
