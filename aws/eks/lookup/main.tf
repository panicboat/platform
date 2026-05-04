# main.tf - Lookup of the EKS cluster by name convention `eks-${environment}`.

data "aws_eks_cluster" "this" {
  name = "eks-${var.environment}"
}

data "aws_caller_identity" "current" {}

# Node security group created by terraform-aws-modules/eks parent module.
# Naming pattern: `eks-${cluster_name}-node-${random_suffix}` (terraform-aws-
# modules/eks v21 default). This SG allows node-to-node pod-network traffic
# and must be attached to MNGs (parent module auto-wires it for in-module
# MNGs, but standalone eks-managed-node-group submodule requires explicit
# pass-through via `vpc_security_group_ids`).
data "aws_security_group" "node" {
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # terraform-aws-modules/eks v21 sets the Name tag to `eks-${cluster_name}-node`
  # (no random suffix; the suffix is only on the SG's `GroupName` attribute).
  filter {
    name   = "tag:Name"
    values = ["eks-${var.environment}-node"]
  }
}
