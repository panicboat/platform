# OIDC Trust Tightening and Plan/Apply Role Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten OIDC trust policy, split plan/apply IAM roles, and set GitHub Actions default workflow permissions to read-only across `monorepo` and `platform` repos.

**Architecture:** Three-stage IAM rollout (add new roles → switch consumers → delete old role) with separate stages for `ci-gatekeeper.yaml` permissions tweak and GitHub default workflow permissions. Terragrunt-managed AWS module changes plus Terraform-managed GitHub repository module additions. Verification by an explicit deny-test on the apply-role.

**Tech Stack:** Terraform 1.11+, Terragrunt, hashicorp/aws ~> 6.42, integrations/github ~> 6.12, GitHub Actions, AWS IAM (OIDC).

**Spec:** `docs/superpowers/specs/2026-04-30-oidc-hardening-design.md`

---

## Files Touched

AWS module:
- `aws/github-oidc-auth/modules/variables.tf` — drop `github_branches`
- `aws/github-oidc-auth/modules/main.tf` — replace single role with plan-role and apply-role; add DynamoDB lock policy; eventually delete old role
- `aws/github-oidc-auth/modules/outputs.tf` — add new outputs; eventually delete old outputs
- `aws/github-oidc-auth/envs/develop/env.hcl` — drop `github_branches`
- `aws/github-oidc-auth/envs/develop/terragrunt.hcl` — drop `github_branches` input
- `aws/github-oidc-auth/envs/production/env.hcl` — drop `github_branches`
- `aws/github-oidc-auth/envs/production/terragrunt.hcl` — drop `github_branches` input

Workflow config:
- `workflow-config.yaml` — switch `iam_role_plan` / `iam_role_apply` ARNs

GitHub workflow:
- `.github/workflows/ci-gatekeeper.yaml` — add `permissions: actions: read`

GitHub repository module:
- `github/repository/modules/variables.tf` — extend `repositories` schema
- `github/repository/modules/main.tf` — add `github_actions_repository_permissions`
- `github/repository/envs/develop/monorepo.hcl` — opt in to read default
- `github/repository/envs/develop/platform.hcl` — opt in to read default

`aws/github-oidc-auth/envs/staging/` is empty (no `env.hcl` / `terragrunt.hcl`) and is therefore out of scope.

---

## Task 1: Verify github provider supports `default_workflow_permissions`

**Files:** none (research only)

This is a pre-condition for Task 9. If the installed `integrations/github ~> 6.12` does not support `default_workflow_permissions` on `github_actions_repository_permissions`, halt and update the spec (provider upgrade, replacement, or scope drop). Do not introduce a `null_resource` / `local-exec` workaround.

- [ ] **Step 1: Initialize the github/repository terragrunt-managed module to download the provider**

```bash
cd github/repository/envs/develop
terragrunt init
```

Expected: provider plugins are downloaded into `.terragrunt-cache/.../<some-hash>/.terraform/providers/registry.terraform.io/integrations/github/`.

- [ ] **Step 2: Check whether `default_workflow_permissions` is in the resource schema**

```bash
cd github/repository/envs/develop
terragrunt providers schema -json 2>/dev/null \
  | jq '.provider_schemas
        | to_entries[]
        | select(.key | test("integrations/github"))
        | .value.resource_schemas.github_actions_repository_permissions.block.attributes
        | has("default_workflow_permissions")'
```

Expected: `true`.

- [ ] **Step 3: Decide based on result**

If the command prints `true` → proceed to Task 2.

If `false` (or null) → STOP. Update `docs/superpowers/specs/2026-04-30-oidc-hardening-design.md` to either bump the github provider version, switch to a different provider, or remove the default-permissions requirement. Do not move on to subsequent tasks before the spec is revised and re-approved.

---

## Task 2: Phase 1 — AWS module: variables and trust condition locals

**Files:**
- Modify: `aws/github-oidc-auth/modules/variables.tf`
- Modify: `aws/github-oidc-auth/modules/main.tf`

- [ ] **Step 1: Drop `github_branches` variable**

Edit `aws/github-oidc-auth/modules/variables.tf`. Remove this block entirely:

```hcl
variable "github_branches" {
  description = "List of GitHub branches that can assume the role"
  type        = list(string)
  default     = ["main", "master"]
}
```

- [ ] **Step 2: Replace trust condition locals**

Edit `aws/github-oidc-auth/modules/main.tf`. Locate the `locals` block that currently contains `repo_conditions`, `branch_conditions`, `environment_conditions`, and `all_conditions`. Replace that entire block with:

```hcl
locals {
  # plan-role: PR トリガーと main 上での plan を許可
  plan_conditions = flatten([
    for repo in var.github_repos : [
      "repo:${var.github_org}/${repo}:pull_request",
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
    ]
  ])

  # apply-role: main push と environment ゲート経由のみ
  apply_conditions = flatten([
    for repo in var.github_repos : concat(
      ["repo:${var.github_org}/${repo}:ref:refs/heads/main"],
      [for env in var.github_environments :
        "repo:${var.github_org}/${repo}:environment:${env}"]
    )
  ])
}
```

Leave the existing `oidc_provider_arn` local block untouched.

- [ ] **Step 3: Format and validate**

```bash
cd aws/github-oidc-auth
terraform fmt -recursive .
make validate ENV=develop
make validate ENV=production
```

Expected: `terraform fmt` exits silently or reformats; both `validate` calls pass.

---

## Task 3: Phase 1 — AWS module: add plan-role and DynamoDB lock policy

**Files:**
- Modify: `aws/github-oidc-auth/modules/main.tf`

- [ ] **Step 1: Add plan-role and read-only attachment**

Append to `aws/github-oidc-auth/modules/main.tf` (after the `locals` block from Task 2):

```hcl
# Plan role: read-only AWS access + Terragrunt state lock RW
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
```

- [ ] **Step 2: Add Terragrunt state lock policy and attach to plan-role**

Append to the same file:

```hcl
# DynamoDB lock table is shared across all envs and lives in ap-northeast-1
# (see aws/github-oidc-auth/root.hcl remote_state.dynamodb_table).
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
```

- [ ] **Step 3: Format and validate**

```bash
cd aws/github-oidc-auth
terraform fmt -recursive .
make validate ENV=develop
make validate ENV=production
```

Expected: pass.

---

## Task 4: Phase 1 — AWS module: add apply-role and outputs

**Files:**
- Modify: `aws/github-oidc-auth/modules/main.tf`
- Modify: `aws/github-oidc-auth/modules/outputs.tf`

- [ ] **Step 1: Add apply-role and policy attachments**

Append to `aws/github-oidc-auth/modules/main.tf`:

```hcl
# Apply role: AdministratorAccess gated by main push or environment
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
```

The existing `aws_iam_role.github_actions_role` and its policy attachments (`administrator_access`, `additional_policies`) MUST remain in the file at this stage. They will be removed in Task 7.

- [ ] **Step 2: Add new outputs**

Edit `aws/github-oidc-auth/modules/outputs.tf`. Append:

```hcl
output "plan_role_arn" {
  description = "ARN of the plan-only GitHub Actions IAM role"
  value       = aws_iam_role.plan.arn
}

output "plan_role_name" {
  description = "Name of the plan-only GitHub Actions IAM role"
  value       = aws_iam_role.plan.name
}

output "apply_role_arn" {
  description = "ARN of the apply GitHub Actions IAM role"
  value       = aws_iam_role.apply.arn
}

output "apply_role_name" {
  description = "Name of the apply GitHub Actions IAM role"
  value       = aws_iam_role.apply.name
}
```

Do NOT remove `github_actions_role_arn`, `github_actions_role_name`, or `allowed_branches` outputs yet — that happens in Task 7.

- [ ] **Step 3: Format and validate**

```bash
cd aws/github-oidc-auth
terraform fmt -recursive .
make validate ENV=develop
make validate ENV=production
```

Expected: pass.

---

## Task 5: Phase 1 — Drop `github_branches` from env configs

**Files:**
- Modify: `aws/github-oidc-auth/envs/develop/env.hcl`
- Modify: `aws/github-oidc-auth/envs/develop/terragrunt.hcl`
- Modify: `aws/github-oidc-auth/envs/production/env.hcl`
- Modify: `aws/github-oidc-auth/envs/production/terragrunt.hcl`

- [ ] **Step 1: Remove `github_branches` from develop/env.hcl**

Edit `aws/github-oidc-auth/envs/develop/env.hcl`. Delete:

```hcl
  # GitHub branches that can assume the role in develop
  github_branches = [
    "*"
  ]
```

- [ ] **Step 2: Remove `github_branches` from develop/terragrunt.hcl**

Edit `aws/github-oidc-auth/envs/develop/terragrunt.hcl`. Delete this line from the `inputs` block:

```hcl
  github_branches          = include.env.locals.github_branches
```

- [ ] **Step 3: Remove `github_branches` from production/env.hcl**

Edit `aws/github-oidc-auth/envs/production/env.hcl`. Delete:

```hcl
  # GitHub branches that can assume the role in production (service-specific)
  github_branches = [
    "*"
  ]
```

- [ ] **Step 4: Remove `github_branches` from production/terragrunt.hcl**

Edit `aws/github-oidc-auth/envs/production/terragrunt.hcl`. Delete the `github_branches` line from `inputs`.

- [ ] **Step 5: Validate both envs**

```bash
cd aws/github-oidc-auth
make validate ENV=develop
make validate ENV=production
```

Expected: both pass.

---

## Task 6: Phase 1 — Plan, commit, apply

**Files:** none (operational)

- [ ] **Step 1: Plan develop**

```bash
cd aws/github-oidc-auth && make plan ENV=develop
```

Expected diff (creations only — no destroys):
- `aws_iam_role.plan` create
- `aws_iam_role_policy_attachment.plan_read_only` create
- `aws_iam_policy.terragrunt_state_lock` create
- `aws_iam_role_policy_attachment.plan_state_lock` create
- `aws_iam_role.apply` create
- `aws_iam_role_policy_attachment.apply_administrator_access` create
- (no `aws_iam_role_policy_attachment.apply_additional_policies` since `var.additional_iam_policies` is empty)

If the plan shows ANY destroy of `aws_iam_role.github_actions_role` or its attachments, STOP — Phase 1 is supposed to keep the legacy role intact (see Task 4 Step 1). Re-edit `main.tf` so the legacy resources are present, then re-plan.

- [ ] **Step 2: Plan production**

```bash
cd aws/github-oidc-auth && make plan ENV=production
```

Expected: same shape as develop, with `production` in resource names and tags.

- [ ] **Step 3: Commit Phase 1 changes**

```bash
cd .claude/worktrees/feat-oidc-hardening
git add aws/github-oidc-auth/
git commit -s -m "feat(aws/github-oidc-auth): add plan/apply roles alongside legacy role

Introduce new plan-role (ReadOnlyAccess + Terragrunt state lock RW) and
apply-role (AdministratorAccess) with tightened OIDC trust conditions.
The legacy github_actions_role is left in place; a follow-up commit
removes it once workflow-config.yaml has switched to the new ARNs.

Refs: docs/superpowers/specs/2026-04-30-oidc-hardening-design.md"
```

- [ ] **Step 4: Apply develop**

```bash
cd aws/github-oidc-auth && make apply ENV=develop
```

Expected: apply completes without error. New roles and policies created.

- [ ] **Step 5: Apply production**

```bash
cd aws/github-oidc-auth && make apply ENV=production
```

- [ ] **Step 6: Capture role ARNs for Task 7**

```bash
cd aws/github-oidc-auth
make output ENV=develop | grep -E 'plan_role_arn|apply_role_arn'
make output ENV=production | grep -E 'plan_role_arn|apply_role_arn'
```

Save the four ARNs locally — they are needed verbatim for Task 7.

---

## Task 7: Phase 2 — Switch `workflow-config.yaml` to new ARNs

**Files:**
- Modify: `workflow-config.yaml`

- [ ] **Step 1: Update develop entry**

Edit `workflow-config.yaml`. Replace the develop terragrunt block:

```yaml
  - environment: develop
    stacks:
      terragrunt:
        aws_region: us-east-1
        iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role
        iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-role
      kubernetes: {}
```

with (use the exact `plan_role_arn` and `apply_role_arn` captured in Task 6 Step 6):

```yaml
  - environment: develop
    stacks:
      terragrunt:
        aws_region: us-east-1
        iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-plan-role
        iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-apply-role
      kubernetes: {}
```

- [ ] **Step 2: Update production entry**

Same pattern for the `- environment: production` block. New ARNs:
- `iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-plan-role`
- `iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-apply-role`

`local` environment is unchanged.

- [ ] **Step 3: Commit**

```bash
git add workflow-config.yaml
git commit -s -m "chore(workflow-config): switch terragrunt iam roles to new plan/apply ARNs"
```

- [ ] **Step 4: Verify in CI**

After this commit reaches `main` (push the branch and merge per local PR workflow):

1. Open a small no-op PR that touches a `terragrunt`-stacked path under `develop` scope (e.g., a comment in `aws/github-oidc-auth/envs/develop/env.hcl`).
2. Confirm `auto-label--deploy-trigger.yaml` runs `terragrunt plan` using the new plan-role ARN and the job succeeds.
3. After merging the no-op PR to main, confirm `terragrunt apply` runs using the new apply-role ARN and succeeds.

If either step fails, do NOT proceed to Task 8. Fix the root cause first.

---

## Task 8: Phase 3 — Remove the legacy IAM role

**Files:**
- Modify: `aws/github-oidc-auth/modules/main.tf`
- Modify: `aws/github-oidc-auth/modules/outputs.tf`

- [ ] **Step 1: Remove `aws_iam_role.github_actions_role` and its attachments**

Edit `aws/github-oidc-auth/modules/main.tf`. Delete these blocks entirely:

```hcl
resource "aws_iam_role" "github_actions_role" { ... }
resource "aws_iam_role_policy_attachment" "administrator_access" { ... }
resource "aws_iam_role_policy_attachment" "additional_policies" { ... }
```

The CloudWatch log group `aws_cloudwatch_log_group.github_actions_logs` MUST stay — it is still useful and not tied to the role.

- [ ] **Step 2: Remove obsolete outputs**

Edit `aws/github-oidc-auth/modules/outputs.tf`. Delete:

```hcl
output "github_actions_role_arn" { ... }
output "github_actions_role_name" { ... }
output "allowed_branches" { ... }
```

- [ ] **Step 3: Format and validate**

```bash
cd aws/github-oidc-auth
terraform fmt -recursive .
make validate ENV=develop
make validate ENV=production
```

Expected: pass.

- [ ] **Step 4: Plan develop**

```bash
cd aws/github-oidc-auth && make plan ENV=develop
```

Expected: ONLY destroys related to `aws_iam_role.github_actions_role` and its `aws_iam_role_policy_attachment.administrator_access` (count 1) and `aws_iam_role_policy_attachment.additional_policies` (count 0 in our case → no entry to destroy). No other diffs.

If the plan touches `plan` / `apply` roles or any other resource, STOP and investigate.

- [ ] **Step 5: Plan production**

```bash
cd aws/github-oidc-auth && make plan ENV=production
```

Expected: same shape.

- [ ] **Step 6: Commit**

```bash
git add aws/github-oidc-auth/
git commit -s -m "feat(aws/github-oidc-auth): remove legacy github_actions_role

Superseded by plan-role and apply-role (PR #...). workflow-config.yaml
no longer references the legacy ARN."
```

- [ ] **Step 7: Apply develop**

```bash
cd aws/github-oidc-auth && make apply ENV=develop
```

- [ ] **Step 8: Apply production**

```bash
cd aws/github-oidc-auth && make apply ENV=production
```

---

## Task 9: Phase 4 — Add `permissions: actions: read` to ci-gatekeeper

**Files:**
- Modify: `.github/workflows/ci-gatekeeper.yaml`

- [ ] **Step 1: Insert the `permissions:` block**

Edit `.github/workflows/ci-gatekeeper.yaml`. After the `on:` block and before `jobs:`, insert:

```yaml
permissions:
  actions: read
```

The header section should look like:

```yaml
name: 'CI Gatekeeper'

on:
  pull_request:
    types: [opened, synchronize, reopened]
    branches:
      - '**'

permissions:
  actions: read

jobs:
  ci-gatekeeper:
    name: CI Gatekeeper
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - name: Wait for other workflows
        uses: int128/wait-for-workflows-action@v1
        with:
          max-timeout-seconds: 1800 # 30 minutes
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci-gatekeeper.yaml
git commit -s -m "chore(workflows/ci-gatekeeper): declare permissions: actions: read

Required ahead of switching the repository default workflow permissions
to read-only; without this declaration int128/wait-for-workflows-action
would lose access to the workflow runs API."
```

This commit can land on main on its own — it is harmless even before the default-permissions change.

---

## Task 10: Phase 5 — github/repository module: schema and resource

**Files:**
- Modify: `github/repository/modules/variables.tf`
- Modify: `github/repository/modules/main.tf`

- [ ] **Step 1: Extend `repositories` schema**

Edit `github/repository/modules/variables.tf`. Update the `repositories` variable to add `actions_default_permissions_read`:

```hcl
variable "repositories" {
  description = "Map of repository configurations. visibility must be one of: public, private, internal"
  type = map(object({
    name                             = string
    description                      = string
    visibility                       = string
    allow_forking                    = optional(bool, true)
    actions_default_permissions_read = optional(bool, false)
    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })
  }))
}
```

- [ ] **Step 2: Add `github_actions_repository_permissions` resource**

Edit `github/repository/modules/main.tf`. Append:

```hcl
resource "github_actions_repository_permissions" "repository" {
  for_each = {
    for k, v in var.repositories :
    k => v if v.actions_default_permissions_read
  }

  repository                   = github_repository.repository[each.key].name
  enabled                      = true
  default_workflow_permissions = "read"
}
```

If Task 1 found that `default_workflow_permissions` is not supported, do NOT proceed — revisit the spec instead.

- [ ] **Step 3: Format and validate**

```bash
cd github/repository
terraform fmt -recursive .
make validate ENV=develop
```

Expected: pass.

---

## Task 11: Phase 5 — opt monorepo and platform into read default

**Files:**
- Modify: `github/repository/envs/develop/monorepo.hcl`
- Modify: `github/repository/envs/develop/platform.hcl`

- [ ] **Step 1: Set the flag for monorepo**

Edit `github/repository/envs/develop/monorepo.hcl`. Add `actions_default_permissions_read = true` inside the `repository` block, alongside `allow_forking`:

```hcl
locals {
  repository = {
    name                             = "monorepo"
    description                      = "Monorepo for multiple services and infrastructure configurations."
    visibility                       = "public"
    allow_forking                    = false
    actions_default_permissions_read = true
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

- [ ] **Step 2: Set the flag for platform**

Edit `github/repository/envs/develop/platform.hcl`. Add the same field:

```hcl
locals {
  repository = {
    name                             = "platform"
    description                      = "Platform for multiple services and infrastructure configurations"
    visibility                       = "public"
    allow_forking                    = false
    actions_default_permissions_read = true
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

- [ ] **Step 3: Plan**

```bash
cd github/repository && make plan ENV=develop
```

Expected diff:
- `module.monorepo.github_actions_repository_permissions.repository["monorepo"]` create
- `module.platform.github_actions_repository_permissions.repository["platform"]` create
- (No diffs for `deploy-actions`, `panicboat-actions`, `ansible`, `dotfiles`)

If any other repository shows a diff, STOP and investigate.

- [ ] **Step 4: Commit**

```bash
git add github/repository/
git commit -s -m "feat(github/repository): default workflow permissions = read for monorepo and platform"
```

- [ ] **Step 5: Apply**

```bash
cd github/repository && make apply ENV=develop
```

- [ ] **Step 6: Verify in GitHub UI**

For each of `monorepo` and `platform`:

1. Open `https://github.com/panicboat/<repo>/settings/actions`
2. Under "Workflow permissions", confirm "Read repository contents and packages permissions" is selected.

For `deploy-actions`, `panicboat-actions`, `ansible`, `dotfiles`: confirm "Read and write permissions" is still selected (no change).

- [ ] **Step 7: Verify ci-gatekeeper completes**

Open a small no-op PR (e.g., touch a comment in any file). Confirm `ci-gatekeeper.yaml` runs to completion without permission errors.

If `ci-gatekeeper` fails because of an additional permission, add it to its `permissions:` block via a follow-up commit on Task 9 and re-test.

---

## Task 12: Verify apply-role denial from PR trigger

This is an out-of-band verification: temporarily install a workflow that tries to assume the apply-role from a PR and confirm it gets `AccessDenied`. Then remove the workflow.

**Files:**
- Create (temporary): `.github/workflows/_test-apply-role-deny.yaml`
- Delete (after verification): same file
- Branch: dedicated short-lived branch off main, e.g., `chore/apply-role-deny-test`

- [ ] **Step 1: Branch off main and create the test workflow**

```bash
cd .claude/worktrees/feat-oidc-hardening
git fetch origin
git switch -c chore/apply-role-deny-test origin/main
```

Create `.github/workflows/_test-apply-role-deny.yaml`:

```yaml
name: 'TEST - apply-role denial'

on:
  pull_request:
    paths:
      - '.github/workflows/_test-apply-role-deny.yaml'

permissions:
  id-token: write
  contents: read

jobs:
  test-deny:
    runs-on: ubuntu-latest
    steps:
      - name: Attempt to assume apply-role (expected to fail)
        id: assume
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::559744160976:role/github-oidc-auth-develop-github-actions-apply-role
          aws-region: us-east-1
        continue-on-error: true

      - name: Verify the assume step failed
        run: |
          if [[ "${{ steps.assume.outcome }}" == "success" ]]; then
            echo "::error::apply-role was assumable from a PR — trust policy is too permissive"
            exit 1
          fi
          echo "OK: apply-role assumption was denied from PR as expected"
```

- [ ] **Step 2: Commit and push**

```bash
git add .github/workflows/_test-apply-role-deny.yaml
git commit -s -m "test(workflows): temporary apply-role denial check"
git push -u origin HEAD
```

- [ ] **Step 3: Open PR (Draft) and observe**

```bash
gh pr create --draft --title "test: apply-role denial check (do not merge)" \
  --body "Temporary PR to verify apply-role trust policy denies PR-triggered assumption. Will be closed without merging."
```

Watch the `TEST - apply-role denial` workflow on the PR.

Expected:
- "Attempt to assume apply-role (expected to fail)" step: outcome = `failure` (showing `AccessDenied` in logs).
- "Verify the assume step failed" step: outcome = `success`.

If the assume step succeeds (i.e., apply-role was assumed from a PR), STOP — the trust policy is not enforcing the intended denial. Investigate immediately and fix before continuing.

- [ ] **Step 4: Close the PR and delete the test branch**

```bash
gh pr close --delete-branch
```

The denial test is verified by the workflow run history; nothing needs to land on `main`.

- [ ] **Step 5: Switch back to the feature worktree branch**

```bash
git switch feat-oidc-hardening
```

---

## Self-Review

After completing all tasks, confirm against the spec:

- [ ] Trust policy: `aws/github-oidc-auth/modules/main.tf` no longer constructs a condition list with `repo:.../*`; only `plan_conditions` and `apply_conditions` are used.
- [ ] plan-role has `ReadOnlyAccess` and the DynamoDB lock policy attached. apply-role has `AdministratorAccess` and any `additional_iam_policies`.
- [ ] `workflow-config.yaml` references plan-role for plan and apply-role for apply, in both develop and production.
- [ ] `ci-gatekeeper.yaml` declares `permissions: actions: read`.
- [ ] `monorepo` and `platform` show "Read repository contents and packages permissions" in GitHub UI; the other four repositories are unchanged.
- [ ] The apply-role denial test workflow ran with the assume step failing as expected.
- [ ] The legacy `aws_iam_role.github_actions_role` no longer exists in either env (verify via `aws iam get-role --role-name github-oidc-auth-develop-github-actions-role` returns NoSuchEntity).
