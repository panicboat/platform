# main.tf - OpenCost AWS-side infrastructure (Pod Identity for Spot Data Feed read access).
#
# Provides:
# 1. IAM role bound by Pod Identity Association to K8s SA `monitoring:opencost`
#    - S3 read-only access scoped to the Spot Instance Data Feed bucket
#      created by aws/cost-management (spot_datafeed.tf). That bucket's name
#      is deterministic (`opencost-spot-datafeed-<account_id>`, same
#      convention as `mimir-<account_id>` referenced from
#      kubernetes/components/mimir/), so it is hardcoded here rather than
#      pulled via a live cross-stack Terragrunt `dependency` block.
#    - AWS on-demand pricing comes from a public, unauthenticated HTTPS
#      endpoint (verified against opencost.io/docs/configuration/aws), so no
#      IAM permission is needed or granted for it.
# 2. Pod Identity Association binding `monitoring:opencost` SA → IAM role

data "aws_caller_identity" "current" {}

locals {
  service_name             = "opencost" # K8s ServiceAccount name
  spot_datafeed_bucket_arn = "arn:aws:s3:::opencost-spot-datafeed-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-${local.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# Least-privilege read access to the Spot Data Feed bucket only. Split into
# bucket-level vs object-level statements (same 2-statement shape as
# aws/eks-metrics' s3_access policy) rather than the flat single-Resource
# example in OpenCost's own docs, which incorrectly lists object-level
# actions (s3:GetObject, s3:HeadObject) against a bucket-level ARN.
resource "aws_iam_role_policy" "spot_datafeed_read" {
  name = "spot-datafeed-read"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:HeadBucket", "s3:GetBucketLocation"]
        Resource = local.spot_datafeed_bucket_arn
      },
      {
        Sid      = "ObjectLevelRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${local.spot_datafeed_bucket_arn}/*"
      },
      {
        Sid      = "SpotPriceHistoryFallbackRead"
        Effect   = "Allow"
        Action   = ["ec2:DescribeSpotPriceHistory"]
        Resource = "*"
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
