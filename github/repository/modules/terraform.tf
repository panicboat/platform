terraform {
  required_version = ">= 1.14.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.41"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
