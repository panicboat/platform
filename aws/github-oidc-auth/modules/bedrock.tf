locals {
  bedrock_inference_profile_arns = [
    for m in var.bedrock_models :
    "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/global.${m}"
  ]

  # Global profiles route to region-less and any-region model ARNs, per `aws bedrock get-inference-profile`.
  bedrock_foundation_model_arns = flatten([
    for m in var.bedrock_models : [
      "arn:aws:bedrock:::foundation-model/${m}",
      "arn:aws:bedrock:*::foundation-model/${m}",
    ]
  ])
}

resource "aws_iam_role" "bedrock" {
  count = length(var.bedrock_models) > 0 ? 1 : 0

  name = "${var.project_name}-${var.environment}-github-actions-bedrock-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = ["repo:${var.github_org}/platform:environment:renovate-major-review"]
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-github-actions-bedrock-role"
    Purpose = "github-actions-oidc-bedrock"
  })
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  count = length(aws_iam_role.bedrock)

  name = "bedrock-invoke"
  role = aws_iam_role.bedrock[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = local.bedrock_inference_profile_arns
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = local.bedrock_foundation_model_arns
        Condition = {
          StringLike = {
            "bedrock:InferenceProfileArn" = local.bedrock_inference_profile_arns
          }
        }
      }
    ]
  })
}
