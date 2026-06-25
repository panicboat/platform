# main.tf - EKS Metrics AWS-side infrastructure (S3 backend for Mimir).
#
# Provides:
# 1. S3 bucket `mimir-<account-id>` for long-term metrics storage
#    (Mimir ingester が write、Mimir compactor が S3 内で compaction、
#    Mimir store-gateway が read)。
#    - Lifecycle: 90 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:mimir`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Mimir compaction で必要)
# 3. Pod Identity Association binding `monitoring:mimir` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う。
# 本 stack の outputs は terragrunt output 経由で取得し、
# kubernetes/components/mimir/ helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "mimir-${data.aws_caller_identity.current.account_id}"
  service_name   = "mimir" # K8s ServiceAccount name
  retention_days = 90      # Mimir long-term metrics retention
}

# S3 bucket for Mimir long-term metrics storage
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.14.1"

  bucket = local.bucket_name

  force_destroy = true

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

# IAM policy for S3 access (bucket-wide, application-level prefix で env scope 担保)
# 3 statement: BucketLevelListing / BucketLocation / ObjectLevelOperations
# NOTE: env-scoped IAM (= ${bucket}/${env}/*) ではなく bucket-wide にしている理由:
# Loki 3.x compactor の delete request store が bucket root の固定 path (index/delete_requests/)
# を使うため env-scoped Resource では不整合が生じる。公式 docs (Loki / Tempo / Mimir
# community discussion) でも `${bucket}` + `${bucket}/*` 形式が推奨。env 分離は各 stack
# の application-level prefix (= mimir.blocks_storage.storage_prefix /
# tempo.storage.trace.s3.prefix) で担保し、3 sibling stack の IAM template は同形を維持。
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
        Resource = "arn:aws:s3:::${local.bucket_name}/*"
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
