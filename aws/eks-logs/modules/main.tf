# main.tf - EKS Logs AWS-side infrastructure (S3 backend for Loki).
#
# Provides:
# 1. S3 bucket `loki-<account-id>` for Loki log chunks long-term storage
#    (Loki distributor / ingester が write、Loki querier が read)。
#    - Lifecycle: 30 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:loki`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Loki block deletion で必要)
# 3. Pod Identity Association binding `monitoring:loki` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う。
# Sub-project 3 (Loki chart 導入) は本 stack の outputs を terragrunt output
# 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "loki-${data.aws_caller_identity.current.account_id}"
  service_name   = "loki" # K8s ServiceAccount name
  retention_days = 30     # Loki log chunks retention
}

# S3 bucket for Loki log chunks
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning = {
    status = "Disabled"
  }

  lifecycle_rule = [
    {
      id     = "${var.environment}-retention"
      status = "Enabled"
      filter = {
        prefix = "${var.environment}/"
      }
      expiration = {
        days = local.retention_days
      }
    }
  ]

  tags = var.common_tags
}

# IAM role for Pod Identity Association
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

# IAM policy for S3 access (production env path scoped)
# 3 statement: BucketLevelListing (s3:prefix condition) / BucketLocation (no condition) / ObjectLevelOperations (env-scoped Resource)
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = "${var.environment}/*"
          }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        Sid    = "ObjectLevelOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
        ]
        Resource = "arn:aws:s3:::${local.bucket_name}/${var.environment}/*"
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
