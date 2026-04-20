# env.hcl - Common environment configuration for develop

locals {
  environment          = "develop"
  aws_region           = "ap-northeast-1"
  claude_model_region  = "us-west-2"
  max_session_duration = 7200 # 2 hours for development work

  additional_iam_policies = []

  environment_tags = {
    Environment = local.environment
    Purpose     = "bedrock-claude"
    Owner       = "panicboat"
  }
}
