# role_actions.tf - GitHub Actions IAM role for CI/CD

resource "aws_iam_role" "actions_role" {
  name                 = "${var.project_name}-${var.environment}-github-actions-role"
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
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
    GitHubRepos = join("+", var.github_repos)
    Purpose     = "bedrock-claude-github-actions"
  })
}

resource "aws_iam_role_policy_attachment" "actions_bedrock_policy" {
  role       = aws_iam_role.actions_role.name
  policy_arn = aws_iam_policy.bedrock_claude_policy.arn
}

resource "aws_iam_role_policy_attachment" "actions_additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.actions_role.name
  policy_arn = var.additional_iam_policies[count.index]
}
