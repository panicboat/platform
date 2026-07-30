# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
