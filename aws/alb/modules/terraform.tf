# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.60.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

# Hosted zone は管理アカウントに残しているため、zone の読み取りと ACM DNS
# validation レコードの書き込みはこの alias 経由で行う。
provider "aws" {
  alias  = "route53"
  region = var.aws_region

  assume_role {
    role_arn = var.route53_zone_role_arn
  }

  default_tags {
    tags = var.common_tags
  }
}
