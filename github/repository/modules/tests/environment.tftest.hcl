mock_provider "aws" {}

mock_provider "github" {}

variables {
  project_name = "repository"
  environment  = "master"
  github_org   = "panicboat"
  github_token = "dummy"
}

run "creates_tag_policy_for_declared_environment" {
  command = plan

  variables {
    repositories = {
      platform = {
        name        = "platform"
        description = "Platform"
        visibility  = "public"
        features = {
          issues   = true
          wiki     = false
          projects = true
        }
        environments = {
          production = { deployment_tag_patterns = ["*-v*"] }
        }
      }
    }
  }

  assert {
    condition     = keys(github_repository_environment.repository) == ["platform/production"]
    error_message = "One environment must exist per declared repository and environment."
  }

  assert {
    condition     = github_repository_environment.repository["platform/production"].environment == "production"
    error_message = "The environment must use the declared name."
  }

  assert {
    condition     = github_repository_environment.repository["platform/production"].can_admins_bypass == false
    error_message = "Admins must not bypass the deployment policy."
  }

  assert {
    condition     = github_repository_environment.repository["platform/production"].deployment_branch_policy[0].custom_branch_policies == true
    error_message = "The environment must restrict deployments with custom policies."
  }

  assert {
    condition     = github_repository_environment.repository["platform/production"].deployment_branch_policy[0].protected_branches == false
    error_message = "The environment must not rely on protected branches."
  }

  assert {
    condition     = keys(github_repository_environment_deployment_policy.repository) == ["platform/production/*-v*"]
    error_message = "One deployment policy must exist per declared tag pattern."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.repository["platform/production/*-v*"].tag_pattern == "*-v*"
    error_message = "The deployment policy must match tags, not branches."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.repository["platform/production/*-v*"].environment == "production"
    error_message = "The deployment policy must target the declared environment."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.repository["platform/production/*-v*"].repository == "platform"
    error_message = "The deployment policy must target the declared repository."
  }
}

run "creates_environment_without_policy_for_empty_patterns" {
  command = plan

  variables {
    repositories = {
      monorepo = {
        name        = "monorepo"
        description = "Monorepo"
        visibility  = "public"
        features = {
          issues   = true
          wiki     = false
          projects = true
        }
        environments = {
          production = { deployment_tag_patterns = [] }
        }
      }
    }
  }

  assert {
    condition     = keys(github_repository_environment.repository) == ["monorepo/production"]
    error_message = "One environment must exist per declared repository and environment."
  }

  assert {
    condition     = github_repository_environment.repository["monorepo/production"].can_admins_bypass == false
    error_message = "Admins must not bypass the deployment policy."
  }

  assert {
    condition     = github_repository_environment.repository["monorepo/production"].deployment_branch_policy[0].custom_branch_policies == true
    error_message = "The environment must restrict deployments with custom policies."
  }

  assert {
    condition     = github_repository_environment.repository["monorepo/production"].deployment_branch_policy[0].protected_branches == false
    error_message = "The environment must not rely on protected branches."
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.repository) == 0
    error_message = "An environment without tag patterns must have no deployment policy, so no ref can deploy."
  }
}

run "creates_no_environment_by_default" {
  command = plan

  variables {
    repositories = {
      platform = {
        name        = "platform"
        description = "Platform"
        visibility  = "public"
        features = {
          issues   = true
          wiki     = false
          projects = true
        }
      }
    }
  }

  assert {
    condition     = length(github_repository_environment.repository) == 0
    error_message = "No environment must exist when environments is not declared."
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.repository) == 0
    error_message = "No deployment policy must exist when environments is not declared."
  }
}
