# Region is pinned to us-east-1 because Cost Optimization Hub and Compute Optimizer APIs only exist there.

terraform {
  required_version = "1.13.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.68.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = var.common_tags
  }
}
