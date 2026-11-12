mock_provider "aws" {
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/terragrunt-state-lock"
    }
  }
}

mock_provider "tls" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

variables {
  project_name         = "github-oidc-auth"
  environment          = "master"
  github_org           = "panicboat"
  github_repos         = ["monorepo", "platform"]
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "skips_bedrock_invoke_role_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role.bedrock_invoke) == 0
    error_message = "The bedrock-invoke role must not exist when bedrock_invoke_oidc_subjects is empty."
  }

  assert {
    condition     = length(aws_iam_role_policy.bedrock_invoke) == 0
    error_message = "The bedrock-invoke policy must not exist when bedrock_invoke_oidc_subjects is empty."
  }

  assert {
    condition     = output.bedrock_invoke_role_arn == null
    error_message = "The bedrock-invoke role ARN output must be null when the role is skipped."
  }
}

run "creates_bedrock_invoke_role_for_listed_subjects" {
  command = apply

  variables {
    bedrock_invoke_oidc_subjects = ["repo:panicboat/monorepo:environment:dystopia-e2e"]
    claude_code_bedrock_models   = ["anthropic.claude-sonnet-4-6"]
  }

  assert {
    condition     = aws_iam_role.bedrock_invoke[0].name == "github-oidc-auth-master-github-actions-bedrock-invoke-role"
    error_message = "The bedrock-invoke role must use the stable name."
  }

  assert {
    condition     = jsondecode(aws_iam_role.bedrock_invoke[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == var.bedrock_invoke_oidc_subjects
    error_message = "The bedrock-invoke role must trust exactly the listed OIDC subjects."
  }

  assert {
    condition     = jsondecode(aws_iam_role.bedrock_invoke[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The bedrock-invoke role must accept only the STS audience."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 0 must allow only the global inference profiles."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Resource) == toset([
      "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 1 must allow the foundation models the global profiles route to."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Condition.StringLike["bedrock:InferenceProfileArn"]) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Foundation model access must be limited to calls routed through the profiles."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement) == 2
    error_message = "The policy must have only the two Bedrock statements."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.bedrock_invoke[0].policy, "secretsmanager")
    error_message = "The bedrock-invoke role must not be able to read any secret."
  }

  assert {
    condition     = length(aws_iam_role.claude_code) == 0 && length(aws_secretsmanager_secret.claude_code_oauth_token) == 0
    error_message = "The bedrock-invoke subjects must not enable the claude-code role or its secret."
  }
}
