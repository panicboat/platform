# main.tf - Claude Code Action IAM Role and Bedrock Permissions

# Get current AWS account information
data "aws_caller_identity" "current" {}

# Use existing OIDC provider ARN
locals {
  oidc_provider_arn = var.oidc_provider_arn

  # ARNs of the cross-region inference profiles (created in claude_model_region)
  inference_profile_arns = [
    for p in var.bedrock_inference_profiles :
    "arn:aws:bedrock:${var.claude_model_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${p.profile_id}"
  ]

  # ARNs of the underlying foundation models in every source region the profile
  # may route to. Both the profile ARN and the FM ARNs must be allowed or
  # InvokeModel returns AccessDenied.
  foundation_model_arns = flatten([
    for p in var.bedrock_inference_profiles : [
      for r in p.source_regions :
      "arn:aws:bedrock:${r}::foundation-model/${p.model_id}"
    ]
  ])

  bedrock_invoke_resources = concat(
    local.inference_profile_arns,
    local.foundation_model_arns,
  )
}

# IAM Role for Claude Code Action
resource "aws_iam_role" "claude_code_action_role" {
  name                 = "${var.project_name}-${var.environment}-github-actions-role"
  max_session_duration = var.max_session_duration

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
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              for repo in var.github_repos : "repo:${var.github_org}/${repo}:*"
            ]
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name        = "${var.project_name}-${var.environment}-github-actions-role"
    GitHubOrg   = var.github_org
    GitHubRepos = join(",", var.github_repos)
    Purpose     = "claude-code-action-bedrock"
  })
}

# Custom IAM Policy for Bedrock Claude Access
resource "aws_iam_policy" "bedrock_claude_policy" {
  name        = "${var.project_name}-${var.environment}-bedrock-claude-policy"
  description = "Policy for Claude Code Action to access Amazon Bedrock Claude models"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.bedrock_invoke_resources
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-bedrock-claude-policy"
    Purpose = "bedrock-claude-access"
  })
}

# Attach Bedrock Claude policy to the role
resource "aws_iam_role_policy_attachment" "bedrock_claude_policy_attachment" {
  role       = aws_iam_role.claude_code_action_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

# Attach any additional policies specified
resource "aws_iam_role_policy_attachment" "additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.claude_code_action_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
