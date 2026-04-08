# main.tf - Claude Code IAM Role and Bedrock Permissions

# Get current AWS account information
data "aws_caller_identity" "current" {}

locals {
  # ARNs of the cross-region inference profiles (created in claude_model_region)
  inference_profile_arns = [
    for p in var.bedrock_inference_profiles :
    "arn:aws:bedrock:${var.claude_model_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${p.profile_id}"
  ]

  # ARNs of the underlying foundation models in every source region the profile
  # may route to. Both the profile ARN and the FM ARNs must be allowed or
  # InvokeModel returns AccessDenied, but the FM ARNs are only granted when the
  # request is routed through an approved inference profile (see the
  # bedrock:InferenceProfileArn condition below).
  foundation_model_arns = flatten([
    for p in var.bedrock_inference_profiles : [
      for r in p.source_regions :
      "arn:aws:bedrock:${r}::foundation-model/${p.model_id}"
    ]
  ])
}

# IAM Role for Claude Code (local CLI)
resource "aws_iam_role" "claude_code_role" {
  name                 = "${var.project_name}-${var.environment}-role"
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.trusted_principal_arns
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-role"
    Purpose = "claude-code-bedrock"
  })
}

# Custom IAM Policy for Bedrock Claude Access
resource "aws_iam_policy" "bedrock_claude_policy" {
  name        = "${var.project_name}-${var.environment}-bedrock-claude-policy"
  description = "Policy for Claude Code to access Amazon Bedrock Claude models"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.inference_profile_arns
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.foundation_model_arns
        Condition = {
          StringEquals = {
            "bedrock:InferenceProfileArn" = local.inference_profile_arns
          }
        }
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
  role       = aws_iam_role.claude_code_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

# Attach any additional policies specified
resource "aws_iam_role_policy_attachment" "additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.claude_code_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
