terraform {
  required_version = "1.13.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.66.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

# Cross-account provider alias manages validation records in management account hosted zones.
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
