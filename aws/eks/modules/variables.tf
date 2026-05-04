# variables.tf - Variables for EKS module

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
  default     = {}
}

variable "cluster_version" {
  description = "EKS Kubernetes version (e.g., \"1.33\")"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days for control plane logs"
  type        = number
  default     = 7
}
