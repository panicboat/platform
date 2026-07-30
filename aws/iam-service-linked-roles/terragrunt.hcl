# terragrunt.hcl - Account 単位の IAM service-linked role 管理。
#
# aws_iam_service_linked_role は account 単位の singleton resource (IAM は
# global service)。他 stack の envs/<env>/ 構成をここでは意図的に採らない:
# 複数 env フォルダを許す構造は「env を増やしてよい」という誤った前例に
# なり、2 つ目の env が apply された瞬間 EntityAlreadyExists で失敗する。
# この stack は常にこの 1 folder = 1 apply target のみ。
#
# 対象は service ごとに増えうる (現状は spot.amazonaws.com のみ)。
# 新しい service-linked role が必要になったら、新規 stack を作らず
# modules/main.tf に resource block を追加する。

locals {
  project_name = "iam-service-linked-roles"

  common_tags = {
    Project    = local.project_name
    ManagedBy  = "terragrunt"
    Repository = "monorepo"
    Component  = "iam-service-linked-roles"
    Team       = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket = "terragrunt-state-${get_aws_account_id()}"

    key    = "platform/iam-service-linked-roles/terraform.tfstate"
    region = "ap-northeast-1"

    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

terraform {
  source = "./modules"
}

inputs = {
  aws_region  = "ap-northeast-1"
  common_tags = local.common_tags
}
