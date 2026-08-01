# spot_datafeed.tf - AWS Spot Instance Data Feed (S3 bucket + subscription)
#
# OpenCost (aws/eks-cost stack 側の Pod Identity role 経由) が Spot instance
# の実勢価格を取得するための data feed。 `aws_spot_datafeed_subscription` は
# 1 AWS account に1つしか作成できない singleton resource
# (AWSServiceRoleForEC2Spot と同種の制約) のため、 cluster destroy/recreate
# cycle の対象外である本 stack に配置する。
#
# bucket は EKS cluster と同じ ap-northeast-1 に置く (OpenCost pod からの S3
# 読み取りで cross-region data transfer を避けるため)。 本 stack のデフォルト
# provider は Cost Optimization Hub / Compute Optimizer 向けに us-east-1
# 固定のため、 `region` 引数で resource 単位に上書きする。

data "aws_caller_identity" "current" {}

locals {
  spot_datafeed_bucket_name = "opencost-spot-datafeed-${data.aws_caller_identity.current.account_id}"
  spot_datafeed_region      = "ap-northeast-1"
}

module "spot_datafeed_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  region = local.spot_datafeed_region
  bucket = local.spot_datafeed_bucket_name

  force_destroy = true

  # Spot Data Feed は AWS が bucket ACL に write 権限を legacy 方式で付与する
  # ため、 Object Ownership を S3 デフォルトの "Bucket owner enforced"
  # (ACL 無効) から変更し ACL を有効化する必要がある。 明示的な grant は行わず
  # (= acl 変数は未設定)、 AWS 側が subscribe 時に自動でつける ACL に任せる。
  control_object_ownership = true
  object_ownership         = "BucketOwnerPreferred"

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

  # 30日: raw data feed file を長期保持する理由がないため最小化
  lifecycle_rule = [
    {
      id     = "expire-old-datafeed-files"
      status = "Enabled"
      expiration = {
        days = 30
      }
    }
  ]

  tags = var.common_tags
}

resource "aws_spot_datafeed_subscription" "this" {
  region = local.spot_datafeed_region
  bucket = module.spot_datafeed_bucket.s3_bucket_id
}
