# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.42"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
