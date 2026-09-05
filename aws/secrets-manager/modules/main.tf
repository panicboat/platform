# main.tf - AWS Secrets Manager secrets (container のみ)。
#
# terraform が管理するのは secret container (name/tags) のみ。実際の secret
# value (aws_secretsmanager_secret_version) は対象外とし、これまで通り手動
# 運用のままにする (tfstate/git に平文 secret を持ち込まないため)。
#
# 新しい secret が必要になったら、この module 内の local.secrets に entry を
# 追加する (stack を分けない。理由は ../README.md 参照)。

locals {
  secrets = {
    fluxcd-bot             = { name = "github-app/fluxcd-bot" }
    holmes-bot             = { name = "github-app/holmes-bot" }
    alertmanager-slack     = { name = "eks/alertmanager/slack" }
    grafana-admin          = { name = "eks/grafana/admin" }
    keycloak-admin         = { name = "eks/keycloak/admin" }
    oauth2-proxy-google    = { name = "eks/oauth2-proxy/google" }
    holmesgpt-alertmanager = { name = "eks/holmesgpt/alertmanager" }
    holmesgpt-slack        = { name = "eks/holmesgpt/slack" }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name = each.value.name

  tags = var.common_tags
}
