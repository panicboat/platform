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

variable "node_instance_types" {
  description = "Instance types for the system managed node group"
  type        = list(string)
  default     = ["m6g.large"]
}

variable "node_desired_size" {
  description = "Desired number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the system node group"
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "EBS volume size (GiB) for node group"
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days for control plane logs"
  type        = number
  default     = 7
}
