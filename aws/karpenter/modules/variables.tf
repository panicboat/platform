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

# karpenter_controller_host MNG variables
# Controller host MNG hosts only the Karpenter controller pod (replicas=2). All other
# workloads (CoreDNS, Cilium operator, Flux, addons, etc.) run on Karpenter
# NodePool-managed instances (system-components NodePool) after migration.

variable "controller_host_instance_types" {
  description = "Instance types for the karpenter_controller_host managed node group (only hosts Karpenter controller pods)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "controller_host_desired_size" {
  description = "Desired number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_min_size" {
  description = "Minimum number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_max_size" {
  description = "Maximum number of nodes in the karpenter_controller_host node group"
  type        = number
  default     = 2
}

variable "controller_host_disk_size" {
  description = "EBS volume size (GiB) for karpenter_controller_host node group"
  type        = number
  default     = 20
}
