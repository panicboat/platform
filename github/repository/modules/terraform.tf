terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.43"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
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
