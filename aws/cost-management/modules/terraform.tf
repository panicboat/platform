# terraform.tf - OpenTofu and provider configuration
# Cost Optimization Hub and Compute Optimizer APIs are only available in us-east-1.
# Region is pinned here so the service does not depend on env aws_region.

terraform {
  required_version = "1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.46.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = var.common_tags
  }
}
