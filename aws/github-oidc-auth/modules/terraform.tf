# terraform.tf - Terraform configuration for GitHub OIDC Auth

terraform {
  required_version = ">= 1.14.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.38"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
  }
}

# AWS Provider configuration
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
