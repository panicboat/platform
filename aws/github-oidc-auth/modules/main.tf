data "aws_caller_identity" "current" {}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

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

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn
}

locals {
  # plan-role: allow PR triggers and main-branch plan runs
  plan_conditions = flatten([
    for repo in var.github_repos : [
      "repo:${var.github_org}/${repo}:pull_request",
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
    ]
  ])

  # apply-role: only main pushes or environment-gated runs
  apply_conditions = flatten([
    for repo in var.github_repos : concat(
      ["repo:${var.github_org}/${repo}:ref:refs/heads/main"],
      [for env in var.github_environments :
      "repo:${var.github_org}/${repo}:environment:${env}"]
    )
  ])
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project_name}-${var.environment}-github-actions-plan-role"
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
            "token.actions.githubusercontent.com:sub" = local.plan_conditions
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-github-actions-plan-role"
    Purpose = "github-actions-oidc-plan"
  })
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Lock table region is fixed to ap-northeast-1 across all environments per root.hcl remote_state.
resource "aws_iam_policy" "terragrunt_state_lock" {
  name        = "${var.project_name}-${var.environment}-terragrunt-state-lock"
  description = "DynamoDB lock table RW for Terragrunt state operations"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:${data.aws_caller_identity.current.account_id}:table/terragrunt-state-locks"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "plan_state_lock" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.terragrunt_state_lock.arn
}

# ReadOnlyAccess excludes sts:AssumeRole required for cross-account lookups.
resource "aws_iam_role_policy" "plan_assume_role" {
  count = length(var.assume_role_arns) > 0 ? 1 : 0

  name = "cross-account-assume"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.assume_role_arns
      }
    ]
  })
}

resource "aws_iam_role" "apply" {
  name                 = "${var.project_name}-${var.environment}-github-actions-apply-role"
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
            "token.actions.githubusercontent.com:sub" = local.apply_conditions
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-${var.environment}-github-actions-apply-role"
    Purpose = "github-actions-oidc-apply"
  })
}

resource "aws_iam_role_policy_attachment" "apply_administrator_access" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "apply_additional_policies" {
  count      = length(var.additional_iam_policies)
  role       = aws_iam_role.apply.name
  policy_arn = var.additional_iam_policies[count.index]
}
