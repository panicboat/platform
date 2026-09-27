variable "environment" {
  description = "Environment name used to locate the EKS cluster (matches the producer's `eks-$${environment}` naming convention)."
  type        = string
}
