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
# Sonnet 5 / Opus 5 are granted but cannot currently be invoked: every
# tokens-per-minute quota for them reads 0, and the self-service increase
# requests were closed without approval (the account has no usage history to
# justify one). Only Sonnet 4.6 has non-zero quota. The IAM grant is
# independent of those quotas, so listing them costs nothing and avoids a
# second apply if the quotas are ever raised.

data "aws_caller_identity" "current" {}

locals {
  service_name = "holmesgpt" # K8s ServiceAccount name

  # Models HolmesGPT invokes. Must stay in sync with `modelList` in
  # kubernetes/components/holmesgpt/production/values.yaml.gotmpl — a model
  # present there but missing here fails at runtime with AccessDenied.
  #
  # Written once and expanded into both the inference-profile ARNs and the
  # foundation-model ARNs below. Hand-listing both forms is what let
  # `anthropic.claude-opus-4-6` (the real id carries a `-v1` suffix) sit here
  # unused while the models actually in `modelList` went ungranted.
  bedrock_models = [
    "anthropic.claude-sonnet-4-6",
    "anthropic.claude-sonnet-5",
    "anthropic.claude-opus-5",
  ]

  # Regions the `us.` cross-region profiles route to, from
  # `aws bedrock get-inference-profile --inference-profile-identifier us.<model>`
  # (models[].modelArn). Granting the profile alone is not enough: the call is
  # authorized against the foundation model in whichever region it lands on.
  bedrock_profile_regions = ["us-east-1", "us-east-2", "us-west-2"]

  bedrock_invoke_resources = concat(
    [
      for m in local.bedrock_models :
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.${m}"
    ],
    flatten([
      for m in local.bedrock_models : [
        for r in local.bedrock_profile_regions :
        "arn:aws:bedrock:${r}::foundation-model/${m}"
      ]
    ]),
  )
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
        Resource = local.bedrock_invoke_resources
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
