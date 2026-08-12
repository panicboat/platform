# iam_opensre.tf - IAM role for the OpenSRE evaluation (read-only investigation).
#
# OpenSRE runs as a local CLI and assumes this role for two purposes: reading
# the cluster through the Kubernetes API (RBAC granted via Access Entry, see
# access_entries.tf) and invoking Bedrock for inference. Keeping both on one
# role is what lets the evaluation run without storing a long-lived API key.
#
# Bedrock resources are enumerated rather than wildcarded because per-model
# pricing differs by more than an order of magnitude; a misconfigured model in
# OpenSRE fails at IAM instead of on the invoice.
#
# Trust policy mirrors iam_admin.tf: it delegates to the account root, and the
# actual assume permission is governed on the user side outside this repository.

resource "aws_iam_role" "opensre_investigator" {
  name                 = "opensre-investigator-${var.environment}"
  max_session_duration = 3600
  tags                 = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensre_describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.opensre_investigator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/eks-${var.environment}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensre_bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.opensre_investigator.id

  # `jp.` inference profiles keep inference inside Japan: get-inference-profile
  # reports they route only to ap-northeast-1 and ap-northeast-3. Both regions'
  # foundation models must be listed or the call fails on whichever region the
  # profile picks.
  #
  # Opus tier and the 5 generation are not enabled on this account, so Sonnet
  # 4.6 is the strongest model available. list-inference-profiles reports every
  # profile as ACTIVE regardless, so availability was established by invoking
  # each one.
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
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/jp.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/jp.anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:ap-northeast-3::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:ap-northeast-3::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        ]
      }
    ]
  })
}
