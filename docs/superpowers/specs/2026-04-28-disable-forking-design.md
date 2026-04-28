# Disable Forking on Selected Public Repositories

## Background

Terraform/Terragrunt manages our GitHub repositories under `github/repository/`. The `github_repository` resource currently does not configure `allow_forking`, so all repositories implicitly allow forks (relevant for public repositories; private/internal forking is governed at the org level).

We want to disable forking on specific public repositories while keeping the option open per repository.

## Goals

- Allow each repository to opt out of forking via its per-repository `.hcl` configuration.
- Disable forking for `monorepo` and `platform` in this change.
- Keep existing behavior (fork allowed) for all other repositories.

## Non-Goals

- Changing organization-level fork policies.
- Changing visibility, branch protection, or any other repository setting.
- Restructuring how per-repository configuration is wired through `terragrunt.hcl`.

## Design

### Module schema change

`github/repository/modules/variables.tf`

Add `allow_forking` as an optional boolean field on the `repositories` map values, defaulting to `true` to preserve current behavior.

```hcl
variable "repositories" {
  description = "Map of repository configurations. visibility must be one of: public, private, internal"
  type = map(object({
    name          = string
    description   = string
    visibility    = string
    allow_forking = optional(bool, true)
    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })
  }))
}
```

### Resource change

`github/repository/modules/main.tf`

Pass `allow_forking` to the `github_repository` resource. Place it near `vulnerability_alerts` since both relate to repository-level access/security rather than collaboration features.

```hcl
resource "github_repository" "repository" {
  ...
  vulnerability_alerts = true
  allow_forking        = each.value.allow_forking
  ...
}
```

### Per-repository configuration

Set `allow_forking = false` in the two `.hcl` files for repositories that should not be forkable:

- `github/repository/envs/develop/monorepo.hcl`
- `github/repository/envs/develop/platform.hcl`

Other `.hcl` files (`deploy-actions.hcl`, `panicboat-actions.hcl`, `ansible.hcl`, `dotfiles.hcl`) are left unchanged and inherit the default `true`.

Example after change:

```hcl
locals {
  repository = {
    name          = "monorepo"
    description   = "Monorepo for multiple services and infrastructure configurations."
    visibility    = "public"
    allow_forking = false
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
```

## Verification

1. `terragrunt plan` under `github/repository/envs/develop/`:
   - `monorepo` and `platform` show `allow_forking: true -> false`.
   - The other four repositories show no change for `allow_forking`.
2. After `terragrunt apply`, confirm in the GitHub UI that the "Allow forking" setting is unchecked for `monorepo` and `platform` and unchanged elsewhere.

## Rollback

Revert the commit. `terragrunt apply` will restore `allow_forking = true` on the affected repositories.
