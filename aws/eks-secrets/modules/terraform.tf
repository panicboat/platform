terraform {
  required_version = "1.13.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.68.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
