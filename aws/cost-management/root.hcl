# root.hcl - Root Terragrunt configuration for cost-management
# This file contains common settings shared across all environments

locals {
  # Project metadata
  project_name = "cost-management"

  # Parse environment from the directory path
  # This assumes environments are in envs/<environment>/ directories
  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  # Common tags applied to all resources
  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "cost-management"
    Team        = "panicboat"
  }
}

# Remote state configuration using shared S3 bucket
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    # Shared bucket for all monorepo services
    bucket = "terragrunt-state-${get_aws_account_id()}"

    # Service-specific path: cost-management/<environment>/terraform.tfstate
    key    = "platform/cost-management/${local.environment}/terraform.tfstate"
    region = "ap-northeast-1"

    # Shared DynamoDB table for state locking across all services
    dynamodb_table = "terragrunt-state-locks"

    # Enable server-side encryption
    encrypt = true
  }
}

# Common inputs passed to all Terraform modules
# aws_region is intentionally omitted; the cost-management module pins region to us-east-1.
inputs = {
  environment = local.environment
  common_tags = local.common_tags
}
