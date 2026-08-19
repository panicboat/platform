# lookups.tf - External stack lookups.
#
# route53/lookup は provider を宣言せず呼び出し側の default provider を継承する。
# aws.route53 (= 管理アカウントへの assume role) を default として渡すことで
# zone を別アカウントから解決する。

module "route53" {
  source = "../../route53/lookup"

  providers = {
    aws = aws.route53
  }
}
