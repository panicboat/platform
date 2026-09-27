variable "environment" {
  description = "Environment name used to locate the VPC (matches the producer's `vpc-$${environment}` Name tag)."
  type        = string
}
