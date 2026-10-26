mock_provider "aws" {
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/terragrunt-state-lock"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:github-oidc-auth-master-claude-code-oauth-token-AbCdEf"
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

run "skips_claude_code_role_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role.claude_code) == 0
    error_message = "The claude-code role must not exist when claude_code_oidc_subjects is empty."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.claude_code_oauth_token) == 0
    error_message = "The OAuth token secret must not exist when claude_code_oidc_subjects is empty."
  }
}

run "creates_claude_code_role_for_listed_subjects" {
  command = apply

  variables {
    claude_code_oidc_subjects = [
      "repo:panicboat/monorepo:environment:claude-code-action",
      "repo:panicboat/platform:environment:claude-code-action",
    ]
    claude_code_bedrock_models = [
      "anthropic.claude-haiku-4-5-20251001-v1:0",
      "anthropic.claude-sonnet-4-6",
    ]
  }

  assert {
    condition     = aws_iam_role.claude_code[0].name == "github-oidc-auth-master-github-actions-claude-code-role"
    error_message = "The claude-code role must use the stable name."
  }

  assert {
    condition     = jsondecode(aws_iam_role.claude_code[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == var.claude_code_oidc_subjects
    error_message = "The claude-code role must trust exactly the listed OIDC subjects."
  }

  assert {
    condition     = jsondecode(aws_iam_role.claude_code[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The claude-code role must accept only the STS audience."
  }

  assert {
    condition     = aws_secretsmanager_secret.claude_code_oauth_token[0].name == "github-oidc-auth-master-claude-code-oauth-token"
    error_message = "The OAuth token secret must use the stable name."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 0 must allow only the global inference profiles."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement[1].Resource) == toset([
      "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
      "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 1 must allow the foundation models the global profiles route to."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement[1].Condition.StringLike["bedrock:InferenceProfileArn"]) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Foundation model access must be limited to calls routed through the profiles."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement[2].Action == ["secretsmanager:GetSecretValue"]
    error_message = "Statement 2 must allow only reading the secret value."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement[2].Resource == aws_secretsmanager_secret.claude_code_oauth_token[0].arn
    error_message = "Statement 2 must allow only the OAuth token secret."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.claude_code[0].policy).Statement) == 3
    error_message = "The policy must have only the Bedrock and secret statements."
  }
}
