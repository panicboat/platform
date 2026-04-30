# terraform.tf - Version constraints for the VPC lookup module.
# This module does not declare a provider; consumers supply the aws provider.

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
