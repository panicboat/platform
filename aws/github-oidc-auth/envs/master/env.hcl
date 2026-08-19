# env.hcl - Master environment configuration
#
# master = 管理アカウント (= 559744160976) に残る横断資産の env。
# production / develop は専用アカウントへ分離済で、Route53 hosted zone・
# GitHub 設定・支払アカウント単位の cost-management がここに集まる。
locals {
  # Environment metadata
  environment = "master"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org   = "panicboat"
  github_repos = ["monorepo", "platform"]

  github_environments = [
    "master"
  ]

  additional_iam_policies = []

  # 管理アカウントの OIDC provider は本 env が所有する
  # (= 1 アカウントに 1 つしか作れないため、develop 移設時に引き取った)。
  create_oidc_provider = true
  oidc_provider_arn    = ""

  # Session duration (4 hours, production と同水準)
  max_session_duration = 14400

  additional_tags = {
    Component = "github-oidc-auth"
    Owner     = "panicboat"
  }
}
