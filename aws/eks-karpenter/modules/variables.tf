# variables.tf - Inputs for the karpenter module.

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

# system_critical MNG variables.
# Bootstrap-critical workloads (Karpenter controller, cilium-operator, CoreDNS)
# run on this MNG. Application workloads (Flux, observability stack, app pods 等)
# run on Karpenter-managed instances (system-components NodePool).

variable "system_critical_instance_types" {
  description = "Instance types for the system_critical managed node group (hosts Karpenter controller / cilium-operator / CoreDNS)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "system_critical_desired_size" {
  description = "Desired number of nodes in the system_critical node group"
  type        = number
  default     = 2
}

variable "system_critical_min_size" {
  description = "Minimum number of nodes in the system_critical node group"
  type        = number
  default     = 2
}

variable "system_critical_max_size" {
  description = "Maximum number of nodes in the system_critical node group"
  type        = number
  default     = 2
}

variable "system_critical_disk_size" {
  description = "EBS volume size (GiB) for system_critical node group"
  type        = number
  default     = 20
}
