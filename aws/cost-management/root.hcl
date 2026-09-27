locals {
  project_name = "cost-management"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "cost-management"
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

    key    = "platform/cost-management/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    dynamodb_table = "terragrunt-state-locks"

    encrypt = true
  }
}

# aws_region is intentionally omitted; the cost-management module pins region to us-east-1.
inputs = {
  environment = local.environment
  common_tags = local.common_tags
}
