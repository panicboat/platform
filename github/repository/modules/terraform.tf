terraform {
  required_version = "1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
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
