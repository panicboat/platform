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

run "skips_bedrock_role_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role.bedrock) == 0
    error_message = "The bedrock role must not exist when bedrock_models is empty."
  }
}

run "creates_bedrock_role_for_listed_models" {
  command = plan

  variables {
    bedrock_models = ["anthropic.claude-sonnet-4-6"]
    bedrock_oidc_subjects = [
      "repo:panicboat/platform:environment:renovate-major-review",
      "repo:panicboat/monorepo:environment:docs-sync-check",
    ]
  }

  assert {
    condition     = aws_iam_role.bedrock[0].name == "github-oidc-auth-master-github-actions-bedrock-role"
    error_message = "The bedrock role must use the stable name."
  }

  assert {
    condition     = jsondecode(aws_iam_role.bedrock[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == var.bedrock_oidc_subjects
    error_message = "The bedrock role must trust exactly the listed OIDC subjects."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 0 must allow only the global inference profile."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Resource) == toset([
      "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
    ])
    error_message = "Statement 1 must allow the foundation models the global profile routes to."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.bedrock_invoke[0].policy).Statement[1].Condition.StringLike["bedrock:InferenceProfileArn"] == ["arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6"]
    error_message = "Foundation model access must be limited to calls routed through the profile."
  }
}
