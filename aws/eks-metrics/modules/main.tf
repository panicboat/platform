# main.tf - EKS Metrics AWS-side infrastructure (S3 backend for Thanos sidecar).
#
# Provides:
# 1. S3 bucket `thanos-<account-id>` for long-term Prometheus metrics storage
#    (Thanos sidecar が write、Thanos compactor が read で compaction)。
#    - Lifecycle: 90 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:prometheus`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Thanos compaction で必要)
# 3. Pod Identity Association binding `monitoring:prometheus` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う:
# - production: s3://thanos-<account-id>/production/...
# - 将来 staging を同 account で構築する場合: 別 IAM role + 別 Pod Identity Association を staging path 用に追加
#
# Sub-project 2 (kube-prometheus-stack chart 導入) は本 stack の outputs
# (bucket_name / bucket_path_prefix / pod_identity_role_name) を terragrunt output
# 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "thanos-${data.aws_caller_identity.current.account_id}"
  service_name   = "prometheus" # K8s ServiceAccount name (override of chart default)
  retention_days = 90           # Thanos long-term metrics retention
}

# S3 bucket for Thanos long-term metrics storage
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

  # Public access block: 4 settings all true (production standard, Decision 6)
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # SSE-S3 (AES256) by default (Decision 5)
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  # Versioning Disabled (Decision 7, immutable write pattern)
  versioning = {
    status = "Disabled"
  }

  # Lifecycle: env path filter + retention (Decision 4)
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

# IAM role for Pod Identity Association (Decision 10)
# Trust policy: pods.eks.amazonaws.com service principal で AssumeRole + TagSession
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

# IAM policy for S3 access (Decision 11, production env path scoped)
# Bucket-level: ListBucket + GetBucketLocation with s3:prefix condition for env scope
# Object-level: Get / Put / Delete on env path only
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

# Pod Identity Association binding K8s SA → IAM role (Decision 10)
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
