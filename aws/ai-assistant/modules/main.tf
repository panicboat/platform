# main.tf - Data sources, locals, and shared Bedrock policy

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
  foundation_model_arns = distinct(flatten([
    for p in var.bedrock_inference_profiles : [
      for r in p.source_regions :
      "arn:aws:bedrock:${r}::foundation-model/${p.model_id}"
    ]
  ]))
}

# Shared IAM Policy for Bedrock Claude Access
resource "aws_iam_policy" "bedrock_claude_policy" {
  name        = "${var.project_name}-${var.environment}-ai-assistant-policy"
  description = "Policy for Bedrock Claude model access via cross-region inference profiles"

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
          StringLike = {
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
          "aws-marketplace:ViewSubscriptions"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-ai-assistant-policy"
    Purpose = "bedrock-claude-access"
  })
}
