# iam_holmesgpt.tf - IRSA role for the HolmesGPT evaluation (Bedrock inference only).
#
# HolmesGPT runs in-cluster and reads the cluster through the Kubernetes API.
# That access comes from the chart's own read-only ClusterRole, not from this
# role — this role exists solely so the agent can call Bedrock without a
# long-lived API key anywhere.
#
# Bedrock resources are enumerated rather than wildcarded because per-model
# pricing differs by an order of magnitude (Opus 5 is $5/$25 per MTok against
# Haiku 4.5 at $1.10/$5.50); a misconfigured model fails at IAM instead of on
# the invoice.
#
# `us.` inference profiles route to three regions. Listing only the profile ARN
# is not enough — the call fails on whichever region the profile picks.
#
# Opus 5 is included even though model access has not finished propagating for
# this account: the IAM grant is independent of Bedrock model-access enablement,
# so having it in place avoids a second apply once propagation completes.

resource "aws_iam_policy" "holmesgpt_bedrock" {
  name        = "eks-${var.environment}-holmesgpt-bedrock"
  description = "Bedrock invoke permissions for the HolmesGPT evaluation"
  tags        = var.common_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-5",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-5",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-5",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-5",
        ]
      }
    ]
  })
}

module "holmesgpt_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "eks-${var.environment}-holmesgpt"
  use_name_prefix = false

  policies = {
    bedrock = aws_iam_policy.holmesgpt_bedrock.arn
  }

  # chart の既定 SA 名は release 名から導出されて変わりうるため、values 側で
  # customServiceAccountName: holmesgpt を指定して固定する。trust policy が
  # 参照する namespace:serviceaccount はそれと一致させる。
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["holmesgpt:holmesgpt"]
    }
  }

  tags = var.common_tags
}
