# iam_admin.tf - IAM role for human kubectl admin access via Access Entry.
#
# Humans assume this role to obtain short-lived credentials for kubectl. The
# role itself only grants eks:DescribeCluster (needed for `aws eks
# update-kubeconfig`); Kubernetes RBAC permissions are granted separately via
# Access Entry (see access_entries.tf).
#
# Trust policy delegates to the account root. Whether an IAM user can
# actually assume this role is governed by sts:AssumeRole permissions on the
# user side (managed outside this repository).

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "eks_admin" {
  name                 = "eks-admin-${var.environment}"
  max_session_duration = 3600
  tags                 = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eks_admin_describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.eks_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/eks-${var.environment}"
      }
    ]
  })
}
