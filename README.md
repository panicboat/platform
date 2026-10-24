# Platform

**English** | [🇯🇵 日本語](README-ja.md)

## 📖 Overview

A monorepo that manages three deployment surfaces from a single label-driven CI pipeline:

- **AWS infrastructure** — Terragrunt + OpenTofu (`aws/`)
- **GitHub configuration** — Terragrunt for repo / branch / ruleset settings (`github/`)
- **Kubernetes platform** — Helmfile-rendered manifests applied by Flux CD (`kubernetes/`)

A PR labeled by `panicboat/deploy-actions` is resolved against `workflow-config.yaml` to expand into concrete deploy targets, and the matching reusable workflow runs.

## 📂 Structure

```
.
├── .github/
│   ├── scripts/         # Scripts run by workflows (hydration, terragrunt release)
│   └── workflows/       # Reusable executors, deploy trigger, hydrator/builder, etc.
├── aws/                 # Terragrunt stacks per service ({environment})
├── github/              # Terragrunt stacks for GitHub repo / branch settings
├── kubernetes/
│   ├── clusters/        # Flux bootstrap (per cluster)
│   ├── components/      # Helmfile sources (per environment)
│   └── manifests/       # Rendered output that Flux applies
├── docs/                # Runbooks and design notes
├── scripts/             # EKS lifecycle helpers
├── Makefile             # EKS teardown entry points
└── workflow-config.yaml # Environments and stack conventions (source of truth)
```

## 🚢 Deployment

### Trigger

- `auto-label--deploy-trigger.yaml` runs on PR labels and on push to `main`.
- `panicboat/deploy-actions/label-resolver` reads `workflow-config.yaml` to expand each label into one or more `{service}/{environment}` targets.
- Terragrunt environments with `apply_trigger: merge` are applied on push to `main`.
- Terragrunt environments with `apply_trigger: release` are applied by `auto-release--trigger.yaml` when the `aws/{service}` release is published.
  - The release PR runs `terragrunt plan` through `auto-release--plan.yaml`; to re-plan, use "Re-run all jobs" on that `auto-release--plan` run.
  - To re-apply a release, run `auto-release--trigger` with `workflow_dispatch` on the release tag ref and pass the same tag: `gh workflow run auto-release--trigger.yaml --ref {service}-vX.Y.Z -f tag={service}-vX.Y.Z`.
- A `{service}/{environment}` pair matched by a rule in `exclude` of the `terragrunt` stack in `workflow-config.yaml` gets no target from `label-resolver` (PR plan, apply on push to `main`) and no release plan / apply.
  - A rule matches a pair when every key (`service`, `environment`) equals the pair's value; a rule with only `environment` covers every service.
  - The release PR is still created, but merging it applies nothing: `auto-release--plan.yaml` and `auto-release--trigger.yaml` skip `plan` / `apply` when `release-targets.sh` returns no target.
- Changes to files outside environment directories under `aws/{service}/` (modules, `root.hcl`, ...) are detected through the `terragrunt-shared` stack and target every environment of that service.
- A service with an `apply_trigger: release` environment directory needs `aws/{service}/release-please-config.json` and `release-please-manifest.json`; `check-release-configs.sh` fails CI otherwise.
  - Commits that change only `apply_trigger: merge` environment directories are kept out of the release through `exclude-paths` in `release-please-config.json`.
  - `check-release-configs.sh` compares `exclude-paths` with the `apply_trigger: merge` environments in `workflow-config.yaml`.

### Stacks

| Stack | Path convention | Tooling |
|-------|-----------------|---------|
| AWS infrastructure | `aws/{service}/{environment}` | Terragrunt + OpenTofu (`reusable--terragrunt-executor.yaml`) |
| GitHub configuration | `github/{service}/{environment}` | Terragrunt + OpenTofu (`reusable--terragrunt-executor.yaml`) |
| Kubernetes platform | `kubernetes/components/{service}/{environment}` | Helmfile → Kustomize hydration (`reusable--kubernetes-hydrator.yaml` / `reusable--kubernetes-builder.yaml`) → Flux CD |

### Environments and authentication

- Environments, AWS regions, and IAM roles are defined in `workflow-config.yaml`. Adding or removing an environment means editing that file.
- `apply_trigger` in `workflow-config.yaml` decides when an environment is applied: `merge` applies on push to `main`, `release` applies when the service release is published.
- Authentication uses GitHub OIDC. `aws/github-oidc-auth/` issues per-environment plan / apply roles that the executors assume.
- The GitHub environment `production` of `platform` accepts deployments only from refs that match the tag pattern `*-v*`, and that of `monorepo` accepts deployments from no ref. The settings are managed in `github/repository/`.
- Terragrunt remote state lives in S3 + DynamoDB; bucket and lock-table names are defined in each `aws/{service}/root.hcl` (and the equivalent under `github/`).

### Pipeline Flow

```mermaid
flowchart LR
  subgraph Triggers
    PRevent[PR open/sync]
    Mainpush[push main]
    Release[release published]
  end

  subgraph Labeling
    Dispatcher[auto-label--label-dispatcher<br/>panicboat/deploy-actions/label-dispatcher]
    Trigger[auto-label--deploy-trigger<br/>on: pull_request labeled]
    Resolver[label-resolver]
  end

  subgraph KubernetesCI [Kubernetes CI]
    Group[kubernetes-targets-group<br/>group by env]
    Hydrator[reusable--kubernetes-hydrator<br/>matrix: env<br/>concurrency: hydrate-PR-env]
    Commit[auto-commit<br/>kubernetes/manifests/]
    Builder[reusable--kubernetes-builder<br/>matrix: service x env<br/>diff only]
    IndexComment[(PR comment<br/>kubernetes-index-env)]
    CompComment[(PR comment<br/>kubernetes-service-env)]
  end

  subgraph Terragrunt
    ReleaseTrigger[auto-release--trigger]
    TG[reusable--terragrunt-executor]
    Plan[terragrunt plan]
    Apply[terragrunt apply]
    PRComment[(PR comment)]
  end

  subgraph Runtime
    AWS[(AWS)]
    FluxCD[Flux CD<br/>polls platform + monorepo]
    Cluster[(cluster)]
  end

  PRevent --> Dispatcher
  Dispatcher --> Trigger
  Trigger --> Resolver
  Resolver -->|stack: terragrunt| TG
  Release --> ReleaseTrigger
  ReleaseTrigger --> TG
  TG -->|on pull_request| Plan
  TG -->|on push main or release published| Apply
  Plan --> PRComment
  Apply --> AWS
  Resolver -->|stack: kubernetes| Group
  Group --> Hydrator
  Hydrator -->|hydrate-component.sh<br/>+ hydrate-index.sh| Commit
  Hydrator -->|index diff| IndexComment
  Commit --> Builder
  Builder --> CompComment
  Mainpush -.-> FluxCD
  FluxCD --> Cluster
  Commit -.->|on diff: re-fires synchronize| Dispatcher
```

### GitOps Sync (Flux CD)

- Flux bootstrap lives in `kubernetes/clusters/{cluster}/flux-system/`. The cluster's root Kustomization aggregates the rendered manifests under `kubernetes/manifests/{cluster}/` and any external `GitRepository` (currently the application monorepo).
- Platform and application repositories are pulled independently and stay loosely coupled. Sync intervals and source URLs are configured in `kubernetes/clusters/{cluster}/` — treat those manifests as the source of truth.
- When `kubernetes/components/` changes, CI runs `.github/scripts/kubernetes-hydrate/`, commits the rendered output to `kubernetes/manifests/`, and posts the diff as a PR comment. Flux applies the change once merged.

### EKS Lifecycle

EKS teardown / recreate is operator-driven and runs outside the deploy pipeline.

- `make eks-teardown ENV=<environment>` runs Kubernetes cleanup → Terragrunt destroy → orphan verify (`scripts/eks-lifecycle/`). `DRY_RUN=1` echoes commands without executing them.
- Recreate is a manual procedure — see `docs/runbooks/eks-production-recreate.md`.

### Claude Code Integration

`@claude` comments trigger `.github/workflows/claude-code-action.yaml`, which assumes the `ai-assistant` IAM role to invoke Bedrock Claude. The role is defined under `aws/ai-assistant/`.
