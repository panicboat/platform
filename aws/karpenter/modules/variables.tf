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

# karpenter_bootstrap MNG variables
# Bootstrap MNG hosts only the Karpenter controller pod (replicas=2). All other
# workloads (CoreDNS, Cilium operator, Flux, addons, etc.) run on Karpenter
# NodePool-managed Graviton 4 on-demand instances after migration.

variable "bootstrap_instance_types" {
  description = "Instance types for the karpenter_bootstrap managed node group (only hosts Karpenter controller pods)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "bootstrap_desired_size" {
  description = "Desired number of nodes in the karpenter_bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_min_size" {
  description = "Minimum number of nodes in the karpenter_bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_max_size" {
  description = "Maximum number of nodes in the karpenter_bootstrap node group"
  type        = number
  default     = 2
}

variable "bootstrap_disk_size" {
  description = "EBS volume size (GiB) for karpenter_bootstrap node group"
  type        = number
  default     = 20
}
