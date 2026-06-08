# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.49.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
