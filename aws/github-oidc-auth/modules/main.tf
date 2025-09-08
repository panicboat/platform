# main.tf - GitHub OIDC Auth IAM Role and Provider

# Get current AWS account information
data "aws_caller_identity" "current" {}

# Get GitHub's OIDC thumbprint
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Create GitHub OIDC Identity Provider (if requested)
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    data.tls_certificate.github.certificates[0].sha1_fingerprint
  ]

  tags = merge(var.common_tags, {
    Name = "github-oidc-provider"
  })
}

# Local value for OIDC provider ARN
locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn
}

# Build trust policy conditions for GitHub Actions
locals {
  # Base conditions for repositories
  repo_conditions = [
    for repo in var.github_repos :
    "repo:${var.github_org}/${repo}:*"
  ]

  # Conditions for specific branches
  branch_conditions = flatten([
    for repo in var.github_repos : [
      for branch in var.github_branches :
      "repo:${var.github_org}/${repo}:ref:refs/heads/${branch}"
    ]
  ])

  # Conditions for specific environments
  environment_conditions = flatten([
    for repo in var.github_repos : [
      for env in var.github_environments :
      "repo:${var.github_org}/${repo}:environment:${env}"
    ]
  ])

  # Combine all conditions
  all_conditions = concat(
    local.repo_conditions,
    local.branch_conditions,
    local.environment_conditions
  )
}

# IAM Role for GitHub Actions OIDC
resource "aws_iam_role" "github_actions_role" {
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
            "token.actions.githubusercontent.com:sub" = local.all_conditions
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name        = "${var.project_name}-${var.environment}-github-actions-role"
    Purpose     = "github-actions-oidc"
  })
}

# Attach AdministratorAccess for full AWS access
resource "aws_iam_role_policy_attachment" "administrator_access" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Attach any additional policies specified
resource "aws_iam_role_policy_attachment" "additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.github_actions_role.name
  policy_arn = var.additional_iam_policies[count.index]
}

# CloudWatch Log Group for GitHub Actions
resource "aws_cloudwatch_log_group" "github_actions_logs" {
  name              = "/github-actions/${var.project_name}-${var.environment}"
  retention_in_days = var.environment == "production" ? 30 : 7

  tags = merge(var.common_tags, {
    LogGroup = "${var.project_name}-${var.environment}-github-actions"
  })
}
