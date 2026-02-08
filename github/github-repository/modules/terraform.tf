# terraform.tf - Terraform configuration for GitHub Repository Management

terraform {
  required_version = ">= 1.14.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.31"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.10"
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

# GitHub Provider configuration
provider "github" {
  owner = var.github_org
  token = var.github_token
}
