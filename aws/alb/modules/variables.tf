# variables.tf - Inputs for the alb module.

variable "environment" {
  description = "Environment name (e.g., production)"
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

variable "route53_zone_role_arn" {
  description = "Role in the management account assumed to read/write the hosted zones"
  type        = string
}
