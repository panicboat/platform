# role_cli.tf - CLI IAM role for local development

resource "aws_iam_role" "cli_role" {
  name                 = "${var.project_name}-${var.environment}-cli-role"
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
    Name    = "${var.project_name}-${var.environment}-cli-role"
    Purpose = "bedrock-claude-cli"
  })
}

resource "aws_iam_role_policy_attachment" "cli_bedrock_policy" {
  role       = aws_iam_role.cli_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

resource "aws_iam_role_policy_attachment" "cli_additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.cli_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
