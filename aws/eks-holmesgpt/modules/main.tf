# main.tf - HolmesGPT AWS-side infrastructure (IAM role + Pod Identity for Bedrock invoke).
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

data "aws_caller_identity" "current" {}

locals {
  service_name = "holmesgpt" # K8s ServiceAccount name
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-holmesgpt"

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

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.pod_identity.id

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
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-4-6",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-6",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-4-6",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-4-6",
        ]
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = local.service_name
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
