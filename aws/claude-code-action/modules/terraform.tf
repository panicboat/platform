# terraform.tf - Terraform and provider configuration

terraform {
  required_version = ">= 1.14.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.32"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

provider "aws" {
  alias  = "claude_region"
  region = var.claude_model_region

  default_tags {
    tags = var.common_tags
  }
}
