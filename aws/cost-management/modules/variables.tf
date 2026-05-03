# variables.tf - Variables for cost-management module

variable "environment" {
  description = "Environment name (e.g., develop, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
