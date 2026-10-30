# Platform

**English** | [🇯🇵 日本語](README-ja.md)

## 📖 Overview

A monorepo that manages four deployment surfaces from a single label-driven CI pipeline:

- **AWS infrastructure** — Terragrunt + OpenTofu ([aws/](aws/))
- **GitHub configuration** — Terragrunt for repo / branch / ruleset settings ([github/](github/))
- **GCP infrastructure** — Terragrunt + OpenTofu ([gcp/](gcp/))
- **Kubernetes platform** — Helmfile-rendered manifests applied by Flux CD ([kubernetes/](kubernetes/))

A PR labeled by `panicboat/deploy-actions` is resolved against [workflow-config.yaml](workflow-config.yaml) to expand into concrete deploy targets, and the matching reusable workflow runs.

## 📂 Structure

```
.
├── .github/
│   └── workflows/       # Workflows that call the shared workflows of panicboat/.github
├── aws/                 # Terragrunt stacks per service ({environment})
├── github/              # Terragrunt stacks for GitHub repo / branch settings
├── gcp/                 # Terragrunt stacks, one directory per GCP project display name
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

| Event | Workflow | Terragrunt |
|-------|----------|------------|
| `deploy:{service}` label added to a PR | [label-base-deploy--resolver.yaml](.github/workflows/label-base-deploy--resolver.yaml) | plan every target |
| Push to `main` | [label-base-deploy--resolver.yaml](.github/workflows/label-base-deploy--resolver.yaml) | apply non-production targets |
| Release PR opened / updated | [release--plan.yaml](.github/workflows/release--plan.yaml) | plan the service's production environment |
| Release published | [release--deploy.yaml](.github/workflows/release--deploy.yaml) | apply the service's production environment |

#### Targets

- [label-base-deploy--dispatcher.yaml](.github/workflows/label-base-deploy--dispatcher.yaml) adds `deploy:{service}` to a PR when it is opened or updated; release-please branches get no label.
  - Any change under `aws/{service}/`, including modules and `root.hcl`, adds the label.
- `label-resolver` reads `services[].stacks` of [workflow-config.yaml](workflow-config.yaml) and expands the label into every environment of that service.
- Each target goes to the workflow for its `type` attribute (`terragrunt` or `helmfile`).
- A `{service}/{environment}` pair matched by `exclude` of the `terragrunt` stack is never planned or applied, including by releases.
  - A rule with only `environment` covers every service.

#### Releases

- Each `aws/{service}` with a production environment has its own release-please config (`release-please-config.json` / `release-please-manifest.json`).
  - [test-terragrunt-release.yaml](.github/workflows/test-terragrunt-release.yaml) fails CI when a config is missing.
- Commits that touch only non-production environment directories count as changes of the service's release-please package.
- While the production environment is excluded, the release PR is still created, but nothing is planned or applied.
- To re-plan, use "Re-run all jobs" on the `Release - Plan` run.
- To re-apply, run `gh workflow run release--deploy.yaml --ref {service}-vX.Y.Z -f tag={service}-vX.Y.Z`.

### Stacks

| Stack | Path convention | Tooling |
|-------|-----------------|---------|
| AWS infrastructure | `aws/{service}/{environment}` | Terragrunt + OpenTofu |
| GitHub configuration | `github/{service}/{environment}` | Terragrunt + OpenTofu |
| GCP infrastructure | `gcp/{project}/{service}/{environment}` | Terragrunt + OpenTofu |
| Kubernetes platform | `kubernetes/components/{service}/{environment}` | Helmfile → Kustomize hydration → Flux CD |

### Environments and authentication

- Environments are declared per stack in `services[].stacks[].environments` of [workflow-config.yaml](workflow-config.yaml); AWS regions and IAM roles live in its `profiles`, which an environment references with `use`. Adding or removing an environment means editing that file.
- The `terragrunt` stack applies the environment named `production` when the service release is published, and every other environment on push to `main`.
- Authentication uses GitHub OIDC. [aws/github-oidc-auth/](aws/github-oidc-auth/) issues per-environment plan / apply roles that the executors assume.
- GCP stacks reuse the master plan / apply roles: [gcp/github-actions-master/workload-identity/](gcp/github-actions-master/workload-identity/) creates the CI project and lets them exchange their AWS credentials for GCP credentials through Workload Identity Federation, configured by [gcp/credential-configuration.json](gcp/credential-configuration.json) in CI only. Local runs use the gcloud application default credentials.
- `{project}` is the display name of the GCP project; `{project}/project.hcl` holds its ID, which can differ from the display name.
- The workload-identity stack of the CI project is applied from a local machine first, because CI cannot reach GCP before it exists. The organization and billing account roles of the CI principals (project creation and billing use for apply, read-only for plan) are granted by hand, so that the apply role does not need to administer organization IAM.
- Give every `{service}` a name that no other stack uses, across `aws/`, `github/` and every GCP project: the `deploy:{service}` label and the tfcmt target include neither the provider nor the GCP project, so equal names plan both stacks and overwrite each other's plan comment.
- The GitHub environment `production` of both `platform` and `monorepo` accepts deployments only from refs that match the tag pattern `*-v*`. The settings are managed in [github/repository/](github/repository/).
- Terragrunt remote state lives in S3 + DynamoDB; bucket and lock-table names are defined in each `aws/{service}/root.hcl` (and the equivalent under [github/](github/) and [gcp/](gcp/)). The state key is `platform/<unit path from the repository root>/terraform.tfstate`, so it never collides across providers.

### Pipeline Flow

```mermaid
flowchart LR
  subgraph Triggers
    PRevent[PR open/sync]
    ReleasePR[release PR open/sync]
    Mainpush[push main]
    Release[release published]
  end

  subgraph Labeling
    Dispatcher[label-base-deploy--dispatcher<br/>panicboat/deploy-actions/label-dispatcher]
    Trigger[label-base-deploy--resolver<br/>on: pull_request labeled]
    Resolver[label-resolver]
  end

  subgraph KubernetesCI [Kubernetes CI]
    Group[group targets by env]
    Hydrator[helmfile hydration<br/>per env]
    Commit[auto-commit<br/>kubernetes/manifests/]
    Builder[kustomize diff<br/>per service x env]
    IndexComment[(PR comment<br/>kubernetes-index-env)]
    CompComment[(PR comment<br/>kubernetes-service-env)]
  end

  subgraph Terragrunt
    PlanTrigger[release--plan]
    ReleaseTrigger[release--deploy]
    TG[terragrunt]
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
  Resolver -->|type: terragrunt| TG
  ReleasePR --> PlanTrigger
  PlanTrigger --> TG
  Release --> ReleaseTrigger
  ReleaseTrigger --> TG
  TG -->|on PR or release PR| Plan
  TG -->|on push main or release published| Apply
  Plan --> PRComment
  Apply --> AWS
  Resolver -->|type: helmfile| Group
  Group --> Hydrator
  Hydrator --> Commit
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
- When [kubernetes/components/](kubernetes/components/) changes, CI renders the components, commits the rendered output to [kubernetes/manifests/](kubernetes/manifests/), and posts the diff as a PR comment. Flux applies the change once merged.
