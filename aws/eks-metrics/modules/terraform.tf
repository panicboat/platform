# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.51.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
