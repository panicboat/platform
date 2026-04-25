# Platform

**English** | [🇯🇵 日本語](README-ja.md)

## 📖 Overview

## 📂 Structure

```
.
├── .github/workflows/         # GitHub Actions (Terragrunt executor, deploy trigger, etc.)
├── aws/                       # Terragrunt stacks (module + envs/{environment})
│   ├── claude-code/
│   ├── claude-code-action/
│   ├── github-oidc-auth/
│   └── vpc/
├── kubernetes/
│   ├── clusters/k3d/          # Flux bootstrap (flux-system, repositories)
│   ├── components/            # Cilium, Prometheus, Loki, Tempo, OTel, Beyla, etc.
│   └── manifests/k3d/         # Rendered manifests (per-component subdirectories)
├── github/repository/         # Terraform for GitHub repo settings
├── docs/
└── workflow-config.yaml       # Environments and deployment targets
```

## 🚢 Deployment

### Trigger

- `.github/workflows/auto-label--deploy-trigger.yaml` runs on PR labels or push to `main`.
- `panicboat/deploy-actions/label-resolver` reads `workflow-config.yaml` to resolve deployment targets (`aws/{service}/envs/{environment}`).

### Stacks

| Stack | Path Convention | Tooling |
|-------|-----------------|---------|
| AWS Infrastructure | `aws/{service}/envs/{environment}` | Terragrunt 0.83.2 + OpenTofu 1.6.0 (`gruntwork-io/terragrunt-action@v3.2.0`) |
| Kubernetes Platform | `kubernetes/components/{service}/{environment}` | Helmfile + Kustomize hydration (`reusable--kubernetes-builder.yaml`) / Flux CD |
| GitHub Repo Settings | `github/repository` | Terraform |

### Environments

Defined in `workflow-config.yaml`. Currently `develop` and `production` are active; `staging` is reserved (commented out).

| Environment | AWS Region | AWS Account | Status |
|-------------|------------|-------------|--------|
| develop | us-east-1 | 559744160976 | Active |
| staging | - | - | Reserved |
| production | ap-northeast-1 | 559744160976 | Active |

Terragrunt remote state is consolidated in S3 bucket `terragrunt-state-559744160976` with DynamoDB lock table `terragrunt-state-locks`.

### Pipeline Flow

```mermaid
flowchart LR
  subgraph Triggers
    PRevent[PR open/sync]
    Mainpush[push main]
  end

  subgraph Labeling
    Dispatcher[auto-label--label-dispatcher<br/>panicboat/deploy-actions/label-dispatcher]
    Trigger[auto-label--deploy-trigger<br/>on: pull_request labeled]
    Resolver[label-resolver]
  end

  subgraph Terragrunt
    TG[reusable--terragrunt-executor]
    Plan[terragrunt plan]
    Apply[terragrunt apply]
    OIDC[github-oidc-auth<br/>IAM roles]
    PRComment[(PR comment)]
  end

  subgraph KubernetesCI [Kubernetes CI]
    Group[kubernetes-targets-group<br/>group by env]
    Hydrator[reusable--kubernetes-hydrator<br/>matrix: env<br/>concurrency: hydrate-PR-env]
    Commit[auto-commit<br/>kubernetes/manifests/]
    Builder[reusable--kubernetes-builder<br/>matrix: service x env<br/>diff only]
    IndexComment[(PR comment<br/>kubernetes-index-env)]
    CompComment[(PR comment<br/>kubernetes-service-env)]
  end

  subgraph Runtime
    AWS[(AWS)]
    FluxCD[Flux CD<br/>polls main branch<br/>kubernetes/manifests/k3d]
    Cluster[(k3d cluster)]
  end

  PRevent --> Dispatcher
  Dispatcher -->|adds missing labels<br/>per workflow-config.yaml<br/>directory_conventions| Trigger
  Mainpush --> Trigger
  Trigger --> Resolver
  Resolver -->|stack: terragrunt| TG
  TG -->|on pull_request| Plan
  TG -->|on push main| Apply
  Plan --> PRComment
  Apply --> AWS
  Apply --> OIDC
  OIDC -.->|AssumeRole| TG
  Resolver -->|stack: kubernetes| Group
  Group --> Hydrator
  Hydrator -->|make hydrate-component<br/>+ hydrate-index| Commit
  Hydrator -->|index diff| IndexComment
  Commit --> Builder
  Builder --> CompComment
  Mainpush -.->|polls every 1min| FluxCD
  FluxCD --> Cluster
  Commit -.->|App token push<br/>fires synchronize<br/>loop terminates: manifests/<br/>not in directory_conventions| Dispatcher
```

AWS authentication uses GitHub OIDC. `aws/github-oidc-auth/envs/{environment}` issues per-environment IAM roles (plan / apply), which other stacks assume to deploy.

### GitOps Sync (Flux CD)

- `kubernetes/clusters/k3d/flux-system/gotk-sync.yaml` defines the Flux bootstrap.
- Two `GitRepository` sources (poll interval: 1 minute):
  - **platform repo**: syncs `./kubernetes/clusters/k3d` — deploys shared platform components (Cilium, CoreDNS, Prometheus-Operator, Grafana, Loki, Tempo, OpenTelemetry, Beyla, etc.).
  - **monorepo**: syncs `./clusters/develop` — deploys application workloads (reconciled every 10 minutes).
- Platform and Monorepo are loosely coupled via Flux.
- When `kubernetes/components/` changes in a PR, the CI pipeline automatically runs `make hydrate` and commits the rendered manifests. The diff against `main` is posted as a PR comment for review.

### Claude Code Integration

- `.github/workflows/claude-code-action.yaml` is triggered by `@claude` comments and invokes AWS Bedrock Claude via the `claude-code-action` IAM role.
- `aws/claude-code-action/` and `aws/claude-code/` define the IAM roles for Bedrock invocation and execution respectively.

## 🔗 Related Repositories

- [panicboat/monorepo](https://github.com/panicboat/monorepo) — application source and `clusters/{env}` manifests (Flux sync target).
- [panicboat/deploy-actions](https://github.com/panicboat/deploy-actions) — reusable GitHub Actions (`label-resolver`, `terragrunt`, `container-builder`, `auto-approve`, etc.).
- [panicboat/ansible](https://github.com/panicboat/ansible) — developer local environment provisioning (independent from the deploy pipeline).
