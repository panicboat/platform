# Secret containers only; secret values are unmanaged to prevent plaintext leakage in state and git.
locals {
  secrets = {
    fluxcd-bot             = { name = "github-app/fluxcd-bot" }
    alertmanager-slack     = { name = "eks/alertmanager/slack" }
    grafana-admin          = { name = "eks/grafana/admin" }
    keycloak-admin         = { name = "eks/keycloak/admin" }
    oauth2-proxy-google    = { name = "eks/oauth2-proxy/google" }
    holmesgpt-alertmanager = { name = "eks/holmesgpt/alertmanager" }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name = each.value.name

  tags = var.common_tags
}
