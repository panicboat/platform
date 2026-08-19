# variables.tf - Inputs for the route53 module.

variable "environment" {
  description = "Environment name (e.g., master)"
  type        = string
}

variable "production_account_id" {
  description = "AWS account ID allowed to assume route53-zone-access"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
}
