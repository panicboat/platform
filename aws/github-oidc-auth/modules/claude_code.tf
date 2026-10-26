locals {
  claude_code_enabled = length(var.claude_code_oidc_subjects) > 0

  claude_code_inference_profile_arns = [
    for m in var.claude_code_bedrock_models :
    "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/global.${m}"
  ]

  # Global profiles route to region-less and any-region model ARNs, per `aws bedrock get-inference-profile`.
  claude_code_foundation_model_arns = flatten([
    for m in var.claude_code_bedrock_models : [
      "arn:aws:bedrock:::foundation-model/${m}",
      "arn:aws:bedrock:*::foundation-model/${m}",
    ]
  ])
}

# Terraform owns only the container; the value is put by hand so the token never lands in the state.
resource "aws_secretsmanager_secret" "claude_code_oauth_token" {
  count = local.claude_code_enabled ? 1 : 0

  name        = "${var.project_name}-${var.environment}-claude-code-oauth-token"
  description = "Claude subscription OAuth token for claude-code-action"

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-claude-code-oauth-token"
    Purpose = "github-actions-claude-code"
  })
}

resource "aws_iam_role" "claude_code" {
  count = local.claude_code_enabled ? 1 : 0

  name = "${var.project_name}-${var.environment}-github-actions-claude-code-role"

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
            "token.actions.githubusercontent.com:sub" = var.claude_code_oidc_subjects
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-github-actions-claude-code-role"
    Purpose = "github-actions-claude-code"
  })
}

resource "aws_iam_role_policy" "claude_code" {
  count = length(aws_iam_role.claude_code)

  name = "claude-code"
  role = aws_iam_role.claude_code[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = local.claude_code_inference_profile_arns
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = local.claude_code_foundation_model_arns
        Condition = {
          StringLike = {
            "bedrock:InferenceProfileArn" = local.claude_code_inference_profile_arns
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.claude_code_oauth_token[0].arn
      }
    ]
  })
}
