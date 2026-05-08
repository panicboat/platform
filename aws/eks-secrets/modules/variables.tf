# variables.tf - Inputs for the eks-secrets module

variable "environment" {
  description = "Environment name (e.g., production). Used in IAM role name."
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
