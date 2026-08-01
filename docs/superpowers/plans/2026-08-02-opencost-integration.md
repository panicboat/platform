# OpenCost Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy OpenCost to the `eks-production` cluster so AWS cost (especially spot instance cost) is visible in Grafana, without opening AWS Cost Explorer.

**Architecture:** OpenCost runs as a new `monitoring` namespace component. On-demand pricing comes from a public, unauthenticated AWS endpoint (no IAM needed). Spot pricing comes from an AWS Spot Instance Data Feed (a new S3 bucket + subscription in the existing `aws/cost-management` stack), read via a new Pod Identity IAM role (`aws/eks-cost` stack). OpenCost reads existing cluster resource-usage metrics from the existing `kube-prometheus-stack` Prometheus, and exposes its own cost metrics back to that same Prometheus via a `ServiceMonitor`, which already remote-writes to Mimir. Three community-maintained OpenCost Grafana dashboards are added to the existing dashboard sidecar auto-discovery mechanism.

**Tech Stack:** Terragrunt/OpenTofu (AWS resources), Helmfile (`opencost` chart v2.5.28 from `https://opencost.github.io/opencost-helm-chart`), Kustomize (Grafana dashboard ConfigMaps), FluxCD (deployment).

## Global Constraints

- OpenTofu `required_version = "1.12.5"`, AWS provider `version = "6.56.0"` (all new/modified `.tf` files must match the versions already pinned across every other `aws/*/modules/terraform.tf` in this repo)
- `terraform-aws-modules/s3-bucket/aws` module version `"5.15.3"` (current pin used by `aws/eks-metrics`, `aws/eks-logs`, `aws/eks-traces`)
- AWS account ID: `559744160976` (already hardcoded elsewhere in this repo, e.g. `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`)
- Cluster region: `ap-northeast-1`. `aws/cost-management`'s default provider is pinned to `us-east-1` (Cost Optimization Hub / Compute Optimizer are us-east-1-only); new resources in that stack must override with a per-resource `region = "ap-northeast-1"` argument rather than adding a provider alias (both `terraform-aws-modules/s3-bucket/aws` v5.15.3 and `aws_spot_datafeed_subscription` support this natively)
- Auth pattern: EKS Pod Identity, not IRSA (no `eks.amazonaws.com/role-arn` annotation; `serviceAccount.name` must exactly match the Pod Identity Association's `service_account`)
- OpenCost namespace: `monitoring` (shared with mimir/loki/tempo/prometheus-operator)
- OpenCost chart: repo `https://opencost.github.io/opencost-helm-chart`, chart `opencost`, version `"2.5.28"`
- Commit convention: `git commit -s` (signoff), no `Co-Authored-By` trailer
- All Terraform tasks in this plan stop at `terragrunt plan`. Do NOT run `terragrunt apply` or any other live-infrastructure-mutating command without a separate, explicit confirmation from the user at execution time — this is a hard-to-reverse, shared-system action per the operator's standing policy.

---

## Task 1: `aws/cost-management` — Spot Instance Data Feed S3 bucket + subscription

**Files:**
- Create: `aws/cost-management/modules/spot_datafeed.tf`
- Modify: `aws/cost-management/modules/outputs.tf`

**Interfaces:**
- Produces (Terraform outputs, consumed by Task 2 and Task 3 as hardcoded values — see Task 1 Step 4 rationale): `spot_datafeed_bucket_name = "opencost-spot-datafeed-559744160976"`, `spot_datafeed_region = "ap-northeast-1"`

- [ ] **Step 1: Write `spot_datafeed.tf`**

```hcl
# spot_datafeed.tf - AWS Spot Instance Data Feed (S3 bucket + subscription)
#
# OpenCost (aws/eks-cost stack 側の Pod Identity role 経由) が Spot instance
# の実勢価格を取得するための data feed。 `aws_spot_datafeed_subscription` は
# 1 AWS account に1つしか作成できない singleton resource
# (AWSServiceRoleForEC2Spot と同種の制約) のため、 cluster destroy/recreate
# cycle の対象外である本 stack に配置する。
#
# bucket は EKS cluster と同じ ap-northeast-1 に置く (OpenCost pod からの S3
# 読み取りで cross-region data transfer を避けるため)。 本 stack のデフォルト
# provider は Cost Optimization Hub / Compute Optimizer 向けに us-east-1
# 固定のため、 `region` 引数で resource 単位に上書きする。

data "aws_caller_identity" "current" {}

locals {
  spot_datafeed_bucket_name = "opencost-spot-datafeed-${data.aws_caller_identity.current.account_id}"
  spot_datafeed_region      = "ap-northeast-1"
}

module "spot_datafeed_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  region = local.spot_datafeed_region
  bucket = local.spot_datafeed_bucket_name

  force_destroy = true

  # Spot Data Feed は AWS が bucket ACL に write 権限を legacy 方式で付与する
  # ため、 Object Ownership を S3 デフォルトの "Bucket owner enforced"
  # (ACL 無効) から変更し ACL を有効化する必要がある。 明示的な grant は行わず
  # (= acl 変数は未設定)、 AWS 側が subscribe 時に自動でつける ACL に任せる。
  control_object_ownership = true
  object_ownership          = "BucketOwnerPreferred"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning = {
    status = "Disabled"
  }

  # 30日: raw data feed file を長期保持する理由がないため最小化
  lifecycle_rule = [
    {
      id     = "expire-old-datafeed-files"
      status = "Enabled"
      expiration = {
        days = 30
      }
    }
  ]

  tags = var.common_tags
}

resource "aws_spot_datafeed_subscription" "this" {
  region = local.spot_datafeed_region
  bucket = module.spot_datafeed_bucket.s3_bucket_id
}
```

- [ ] **Step 2: Append outputs to `outputs.tf`**

Current file is a single comment line (`# outputs.tf - No outputs; this service does not expose values to other stacks`). Replace its entire content with:

```hcl
# outputs.tf - Outputs for the cost-management module.

output "spot_datafeed_bucket_name" {
  description = "S3 bucket name for the AWS Spot Instance Data Feed. Referenced (as a hardcoded value, see aws/eks-cost and kubernetes/components/opencost/ for why) by aws/eks-cost's IAM policy Resource ARN and kubernetes/components/opencost/ helmfile values (opencost.customPricing.costModel.awsSpotDataBucket)."
  value       = module.spot_datafeed_bucket.s3_bucket_id
}

output "spot_datafeed_region" {
  description = "AWS region of the Spot Instance Data Feed bucket. Used as opencost.customPricing.costModel.awsSpotDataRegion."
  value       = local.spot_datafeed_region
}
```

- [ ] **Step 3: Validate and format**

Run:
```bash
cd aws/cost-management/envs/develop && TG_TF_PATH=tofu terragrunt validate
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-opencost-integration/aws/cost-management && TG_TF_PATH=tofu terragrunt hclfmt 2>/dev/null; tofu fmt -recursive modules/
```
Expected: `terragrunt validate` reports `Success! The configuration is valid.`; `tofu fmt` makes no further changes (or auto-fixes indentation — re-run `validate` after if it does).

- [ ] **Step 4: Plan (do not apply)**

Run:
```bash
cd aws/cost-management/envs/develop && TG_TF_PATH=tofu terragrunt plan
```
Expected: plan shows `2 to add` (`module.spot_datafeed_bucket...` resources — actually the module itself creates multiple resources, so the exact count will be higher than 2; confirm no `to change` or `to destroy` against the two existing `cost_optimization_hub`/`compute_optimizer` resources) and `aws_spot_datafeed_subscription.this` to add. No errors.

Note the exact `spot_datafeed_bucket_name` output value shown in the plan (should be `opencost-spot-datafeed-559744160976`) — Task 2 and Task 3 hardcode this string rather than using a live `dependency` block, following the same convention `kubernetes/components/mimir/production/helmfile.yaml` uses for its `aws/eks-metrics` bucket name (deterministic name, no need for a live cross-stack Terragrunt dependency).

- [ ] **Step 5: Commit**

```bash
git add aws/cost-management/modules/spot_datafeed.tf aws/cost-management/modules/outputs.tf
git commit -s -m "feat(aws/cost-management): add Spot Instance Data Feed S3 bucket and subscription"
```

---

## Task 2: `aws/eks-cost` — new stack: Pod Identity IAM role for OpenCost

**Files:**
- Create: `aws/eks-cost/root.hcl`
- Create: `aws/eks-cost/envs/production/env.hcl`
- Create: `aws/eks-cost/envs/production/terragrunt.hcl`
- Create: `aws/eks-cost/modules/main.tf`
- Create: `aws/eks-cost/modules/variables.tf`
- Create: `aws/eks-cost/modules/outputs.tf`
- Create: `aws/eks-cost/modules/lookups.tf`
- Create: `aws/eks-cost/modules/terraform.tf`
- Create: `aws/eks-cost/Makefile`

**Interfaces:**
- Consumes: `aws/cost-management`'s deterministic bucket name `opencost-spot-datafeed-559744160976` (hardcoded, see Task 1 Step 4)
- Produces: IAM role `eks-production-opencost`, Pod Identity Association binding K8s SA `monitoring:opencost` to that role (consumed implicitly by Task 3's Deployment at runtime — no Terraform output needs to be threaded into Helm values, since Pod Identity binds by SA name alone)

This task mirrors `aws/eks-metrics` file-for-file, swapping the S3-storage-for-Mimir policy for a read-only policy scoped to the Spot Data Feed bucket, and dropping the `bucket_name`/`bucket_path_prefix` outputs since OpenCost needs no bucket of its own.

- [ ] **Step 1: Write `root.hcl`**

```hcl
# root.hcl - Root Terragrunt configuration for EKS Cost
# This file contains common settings shared across all environments

locals {
  project_name = "eks-cost"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks-cost"
    Team        = "panicboat"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "platform/eks-cost/${local.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

inputs = {
  environment = local.environment
  common_tags = local.common_tags
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 2: Write `envs/production/env.hcl`**

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Component   = "eks-cost"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 3: Write `envs/production/terragrunt.hcl`**

```hcl
# terragrunt.hcl - Terragrunt configuration for production environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//eks-cost/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-cost"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 4: Write `modules/terraform.tf`**

```hcl
# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = "1.12.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}
```

- [ ] **Step 5: Write `modules/variables.tf`**

```hcl
# variables.tf - Inputs for the eks-cost module

variable "environment" {
  description = "Environment name (e.g., production)."
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 6: Write `modules/lookups.tf`**

```hcl
# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

- [ ] **Step 7: Write `modules/main.tf`**

```hcl
# main.tf - OpenCost AWS-side infrastructure (Pod Identity for Spot Data Feed read access).
#
# Provides:
# 1. IAM role bound by Pod Identity Association to K8s SA `monitoring:opencost`
#    - S3 read-only access scoped to the Spot Instance Data Feed bucket
#      created by aws/cost-management (spot_datafeed.tf). That bucket's name
#      is deterministic (`opencost-spot-datafeed-<account_id>`, same
#      convention as `mimir-<account_id>` referenced from
#      kubernetes/components/mimir/), so it is hardcoded here rather than
#      pulled via a live cross-stack Terragrunt `dependency` block.
#    - AWS on-demand pricing comes from a public, unauthenticated HTTPS
#      endpoint (verified against opencost.io/docs/configuration/aws), so no
#      IAM permission is needed or granted for it.
# 2. Pod Identity Association binding `monitoring:opencost` SA → IAM role

data "aws_caller_identity" "current" {}

locals {
  service_name             = "opencost" # K8s ServiceAccount name
  spot_datafeed_bucket_arn = "arn:aws:s3:::opencost-spot-datafeed-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-${local.service_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# Least-privilege read access to the Spot Data Feed bucket only. Split into
# bucket-level vs object-level statements (same 2-statement shape as
# aws/eks-metrics' s3_access policy) rather than the flat single-Resource
# example in OpenCost's own docs, which incorrectly lists object-level
# actions (s3:GetObject, s3:HeadObject) against a bucket-level ARN.
resource "aws_iam_role_policy" "spot_datafeed_read" {
  name = "spot-datafeed-read"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:HeadBucket", "s3:GetBucketLocation"]
        Resource = local.spot_datafeed_bucket_arn
      },
      {
        Sid      = "ObjectLevelRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${local.spot_datafeed_bucket_arn}/*"
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = "monitoring"
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
```

- [ ] **Step 8: Write `modules/outputs.tf`**

```hcl
# outputs.tf - Outputs for the eks-cost module.

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:opencost SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:opencost SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
```

- [ ] **Step 9: Write `Makefile`**

Copy `aws/eks-metrics/Makefile` verbatim, changing only the header comment and `help` banner text from "EKS Metrics (Mimir S3 + Pod Identity)" / "EKS Metrics" to "EKS Cost (OpenCost Pod Identity)" / "EKS Cost".

- [ ] **Step 10: Validate and plan (do not apply)**

Run:
```bash
cd aws/eks-cost/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade
cd aws/eks-cost/envs/production && TG_TF_PATH=tofu terragrunt validate
cd aws/eks-cost/envs/production && TG_TF_PATH=tofu terragrunt plan
```
Expected: `validate` succeeds; `plan` shows 3 resources to add (`aws_iam_role.pod_identity`, `aws_iam_role_policy.spot_datafeed_read`, `aws_eks_pod_identity_association.this`), 0 to change, 0 to destroy. No errors (the `module "eks"` lookup must successfully find the live `eks-production` cluster).

- [ ] **Step 11: Commit**

```bash
git add aws/eks-cost/
git commit -s -m "feat(aws/eks-cost): add Pod Identity IAM role for OpenCost"
```

---

## Task 3: `kubernetes/components/opencost/production/` — new component

**Files:**
- Create: `kubernetes/components/opencost/production/helmfile.yaml`
- Create: `kubernetes/components/opencost/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: `aws/cost-management` outputs `spot_datafeed_bucket_name` / `spot_datafeed_region` (Task 1, hardcoded per that task's Step 4 rationale); `aws/eks-cost`'s Pod Identity Association for `monitoring:opencost` (Task 2, binds automatically by SA name — no value wiring needed)
- Produces: `Deployment/opencost` + `Service/opencost` in namespace `monitoring`, `ServiceMonitor/opencost` labeled `release: kube-prometheus-stack`

- [ ] **Step 1: Write `helmfile.yaml`**

```yaml
# =============================================================================
# OpenCost Helmfile for production
# =============================================================================
# Kubernetes cost allocation. On-demand pricing comes from a public,
# unauthenticated AWS endpoint (no credentials involved). Spot pricing comes
# from the AWS Spot Instance Data Feed (aws/cost-management) read via Pod
# Identity (aws/eks-cost).
# =============================================================================
environments:
  production:
    values:
      - opencost:
          # Source: aws/cost-management/envs/develop terragrunt output spot_datafeed_bucket_name
          spotDataBucket: opencost-spot-datafeed-559744160976
          # Source: aws/cost-management/envs/develop terragrunt output spot_datafeed_region
          spotDataRegion: ap-northeast-1
          # STABLE: AWS account ID
          awsAccountId: "559744160976"
---
repositories:
  - name: opencost
    url: https://opencost.github.io/opencost-helm-chart

releases:
  - name: opencost
    namespace: monitoring
    chart: opencost/opencost
    version: "2.5.28"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 2: Write `values.yaml.gotmpl`**

```yaml
# OpenCost values for production

serviceAccount:
  create: true
  name: opencost

opencost:
  metrics:
    serviceMonitor:
      enabled: true
      # kube-prometheus-stack の serviceMonitorSelector match (cilium の
      # ServiceMonitor と同じ pattern)
      additionalLabels:
        release: kube-prometheus-stack

  prometheus:
    internal:
      enabled: true
      serviceName: kube-prometheus-stack-prometheus
      namespaceName: monitoring
      port: 9090

  # awsSpotDataBucket/awsSpotDataRegion/projectID の3つを渡すためだけに
  # customPricing を有効化する。 CPU/RAM/GPU 等の costModel フィールドは未指定
  # のまま chart デフォルトにフォールバックさせる (= 動的取得 (Pricing API)
  # が失敗した場合のみ使われる fallback 値であり、 常用の静的価格ではない。
  # opencost.io/docs/configuration/aws のソース調査で確認済)。
  customPricing:
    enabled: true
    provider: aws
    costModel:
      description: "AWS Spot Instance Data Feed location for spot price accuracy"
      awsSpotDataBucket: {{ .Values.opencost.spotDataBucket }}
      awsSpotDataRegion: {{ .Values.opencost.spotDataRegion }}
      projectID: {{ .Values.opencost.awsAccountId }}

  exporter:
    resources:
      requests:
        cpu: 25m
        memory: 55Mi
      limits:
        memory: 256Mi

  ui:
    resources:
      requests:
        cpu: 10m
        memory: 55Mi
      limits:
        memory: 256Mi
```

- [ ] **Step 3: Hydrate and inspect the rendered manifest**

Run:
```bash
scripts/kubernetes-hydrate/hydrate-component.sh opencost production
```
Expected: exits 0, writes `kubernetes/manifests/production/opencost/manifest.yaml` and `kustomization.yaml`.

Then verify the key pieces rendered correctly:
```bash
grep -n "^kind: ServiceAccount" -A3 kubernetes/manifests/production/opencost/manifest.yaml
grep -n "^kind: ServiceMonitor" -A20 kubernetes/manifests/production/opencost/manifest.yaml | grep -E "release:|name:|namespace:"
grep -n "awsSpotDataBucket\|awsSpotDataRegion\|projectID" kubernetes/manifests/production/opencost/manifest.yaml
```
Expected:
- `ServiceAccount` named `opencost` in namespace `monitoring`, no `eks.amazonaws.com/role-arn` annotation
- `ServiceMonitor` carries label `release: kube-prometheus-stack`
- the custom-pricing ConfigMap (or Secret, whichever the chart renders) contains `"awsSpotDataBucket": "opencost-spot-datafeed-559744160976"`, `"awsSpotDataRegion": "ap-northeast-1"`, `"projectID": "559744160976"`

- [ ] **Step 4: Regenerate the manifests index**

Run:
```bash
scripts/kubernetes-hydrate/hydrate-index.sh production
```
Expected: `kubernetes/manifests/production/kustomization.yaml` now lists `./opencost` alphabetically between `./oauth2-proxy` and `./opentelemetry-collector`; `kubernetes/manifests/production/00-namespaces/namespaces.yaml` is unchanged (opencost has no `namespace.yaml` of its own — it reuses the `monitoring` namespace already created by `prometheus-operator`).

- [ ] **Step 5: Dry-run validate against the live cluster**

Run:
```bash
kubectl apply -k kubernetes/manifests/production/opencost/ --dry-run=server
```
Expected: no errors (server-side dry-run confirms the rendered manifest is structurally valid against the live API server's CRDs, including `ServiceMonitor`).

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/opencost/ kubernetes/manifests/production/opencost/ kubernetes/manifests/production/kustomization.yaml
git commit -s -m "feat(kubernetes/opencost): add OpenCost component for production"
```

---

## Task 4: Grafana dashboards

**Files:**
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/opencost-overview.json`
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/opencost-namespace.json`
- Create: `kubernetes/components/dashboard/production/kustomization/grafana/opencost-workload.json`
- Modify: `kubernetes/components/dashboard/production/kustomization/kustomization.yaml`

**Interfaces:**
- Consumes: `ServiceMonitor/opencost` metrics flowing into Mimir (Task 3); each dashboard's `$datasource` template variable (type `prometheus`, default `"default"`) auto-resolves to whichever datasource Grafana has marked default (Mimir, per existing `prometheus-operator` component config) — no per-dashboard datasource UID edit needed

These three dashboards are community-maintained (`adinhodovic/opencost-mixin`), not published by the `opencost` GitHub org itself — the org's own `opencost/opencost-grafana-dashboard` repo is empty. This mixin's output is what backs the "OpenCost / Overview", "OpenCost / Namespace", and "OpenCost / Workload" listings on grafana.com, and is the closest thing to a de facto standard dashboard set. Pinned to commit `b63c14d687fd2463469c0afa36b06ab5f6bc7d70` (2026-07-17) for reproducibility.

- [ ] **Step 1: Download the three dashboard JSON files**

Run:
```bash
SHA=b63c14d687fd2463469c0afa36b06ab5f6bc7d70
DEST=kubernetes/components/dashboard/production/kustomization/grafana
for name in overview namespace workload; do
  curl -fsSL "https://raw.githubusercontent.com/adinhodovic/opencost-mixin/${SHA}/dashboards_out/opencost-${name}.json" \
    -o "${DEST}/opencost-${name}.json"
done
```
Expected: three files created, sizes roughly 49KB (overview), 57KB (namespace), 41KB (workload).

- [ ] **Step 2: Verify each file is valid JSON and uses the templated datasource**

Run:
```bash
for f in overview namespace workload; do
  python3 -c "import json; json.load(open('kubernetes/components/dashboard/production/kustomization/grafana/opencost-${f}.json'))" && echo "opencost-${f}.json: valid JSON"
done
grep -c '"uid": "\${datasource}"\|"uid": "\$datasource"' kubernetes/components/dashboard/production/kustomization/grafana/opencost-*.json
```
Expected: all three print "valid JSON"; each file has multiple matches for the templated datasource UID (confirms no hardcoded datasource UID was baked in).

- [ ] **Step 3: Register the three dashboards in `kustomization.yaml`**

Modify `kubernetes/components/dashboard/production/kustomization/kustomization.yaml`. Current content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

configMapGenerator:
  - name: grafana-dashboard-app-monitoring
    files:
      - grafana/app-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-infra-monitoring
    files:
      - grafana/infra-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-unified-monitoring
    files:
      - grafana/unified-monitoring.json
    options:
      labels:
        grafana_dashboard: "1"

generatorOptions:
  disableNameSuffixHash: true
```

Add three more `configMapGenerator` entries (after `grafana-dashboard-unified-monitoring`, before `generatorOptions`):

```yaml
  - name: grafana-dashboard-opencost-overview
    files:
      - grafana/opencost-overview.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-opencost-namespace
    files:
      - grafana/opencost-namespace.json
    options:
      labels:
        grafana_dashboard: "1"
  - name: grafana-dashboard-opencost-workload
    files:
      - grafana/opencost-workload.json
    options:
      labels:
        grafana_dashboard: "1"
```

- [ ] **Step 4: Build and verify**

Run:
```bash
kustomize build kubernetes/components/dashboard/production/kustomization/ | grep -A4 "^kind: ConfigMap" | grep "name: grafana-dashboard-opencost"
```
Expected: three `ConfigMap` names printed (`grafana-dashboard-opencost-overview`, `grafana-dashboard-opencost-namespace`, `grafana-dashboard-opencost-workload`).

- [ ] **Step 5: Hydrate the dashboard component**

Run:
```bash
scripts/kubernetes-hydrate/hydrate-component.sh dashboard production
```
Expected: exits 0; `git diff --stat kubernetes/manifests/production/dashboard/manifest.yaml` shows only additions (the three new ConfigMaps), no unrelated changes.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/components/dashboard/production/kustomization/grafana/opencost-*.json \
        kubernetes/components/dashboard/production/kustomization/kustomization.yaml \
        kubernetes/manifests/production/dashboard/manifest.yaml
git commit -s -m "feat(kubernetes/dashboard): add OpenCost Grafana dashboards"
```

---

## Task 5: EKS lifecycle integration

**Files:**
- Modify: `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`
- Modify: `docs/runbooks/eks-production-recreate.md`

**Interfaces:**
- Consumes: stack name `eks-cost` (Task 2)

- [ ] **Step 1: Add `eks-cost` to the destroy order**

In `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`, the `STACKS` array currently is:

```bash
STACKS=(
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks"
  "alb"
  "vpc"
)
```

Add `"eks-cost"` alongside the other three EKS-addon stacks (order among these four doesn't matter — none depend on each other):

```bash
STACKS=(
  "karpenter"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks-cost"
  "eks"
  "alb"
  "vpc"
)
```

Also update the header comment listing the destroy order (`# Order:\n#   karpenter -> eks-secrets -> ... -> vpc`) to include `eks-cost`, and the `# Destroy 8 stacks` comment to `# Destroy 9 stacks`.

- [ ] **Step 2: Add `eks-cost` to the runbook's apply order**

In `docs/runbooks/eks-production-recreate.md`, Phase 7 currently reads:

```bash
for stack in eks-secrets eks-logs eks-metrics eks-traces; do
  echo "=== apply: $stack ==="
  ( cd aws/$stack/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
done
```

Change to:

```bash
for stack in eks-secrets eks-logs eks-metrics eks-traces eks-cost; do
  echo "=== apply: $stack ==="
  ( cd aws/$stack/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve )
done
```

- [ ] **Step 3: Verify**

Run:
```bash
bash -n scripts/eks-lifecycle/lib/30-destroy-stacks.sh
grep -n "eks-cost" scripts/eks-lifecycle/lib/30-destroy-stacks.sh docs/runbooks/eks-production-recreate.md
```
Expected: `bash -n` prints nothing (syntax OK); both files show `eks-cost` in the expected lines.

- [ ] **Step 4: Commit**

```bash
git add scripts/eks-lifecycle/lib/30-destroy-stacks.sh docs/runbooks/eks-production-recreate.md
git commit -s -m "docs(runbook): register aws/eks-cost in the destroy/recreate cycle"
```

---

## Task 6: End-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Full hydrate pass**

Run:
```bash
for comp in opencost dashboard; do
  scripts/kubernetes-hydrate/hydrate-component.sh "$comp" production
done
scripts/kubernetes-hydrate/hydrate-index.sh production
git status --short kubernetes/manifests/
```
Expected: only `kubernetes/manifests/production/opencost/*` (new) and `kubernetes/manifests/production/dashboard/manifest.yaml` (modified) show up — everything from Tasks 3–4 should already be committed, so this should report a clean tree (confirms the hydrated output is reproducible and nothing was hand-edited out of sync with its source).

- [ ] **Step 2: Full-cluster server-side dry-run**

Run:
```bash
kubectl apply -k kubernetes/manifests/production/ --dry-run=server 2>&1 | grep -i "opencost\|error" 
```
Expected: only `configured`/`created` (dry-run) lines mentioning `opencost` resources, no `error` lines.

- [ ] **Step 3: Confirm both Terraform stacks still plan cleanly together**

Run:
```bash
( cd aws/cost-management/envs/develop && TG_TF_PATH=tofu terragrunt plan )
( cd aws/eks-cost/envs/production && TG_TF_PATH=tofu terragrunt plan )
```
Expected: both show the same additive-only diff as Task 1 Step 4 / Task 2 Step 10 (no drift introduced by later tasks).

- [ ] **Step 4: Push branch and open PR**

Per this repo's established pattern, and only after the above all pass:
```bash
git push -u origin HEAD   # if not already tracking
gh pr ready               # flip the existing draft PR to ready, or:
gh pr create --draft ...  # if no PR exists yet for this branch
```

- [ ] **Step 5: Live apply and cluster verification — requires explicit user confirmation, do not run unattended**

Once the user confirms:
```bash
( cd aws/cost-management/envs/develop && TG_TF_PATH=tofu terragrunt apply -auto-approve )
( cd aws/eks-cost/envs/production && TG_TF_PATH=tofu terragrunt apply -auto-approve )
git push
flux reconcile source git flux-system
flux reconcile kustomization flux-system
kubectl -n monitoring get pods -l app.kubernetes.io/name=opencost
kubectl -n monitoring logs deploy/opencost -c opencost --tail=50
```
Expected: `aws_spot_datafeed_subscription.this` and the `aws/eks-cost` IAM role/Pod Identity Association apply cleanly; the `opencost` pod reaches `Running`/`Ready`; its logs show successful AWS auth (no `AccessDenied` on S3) and no repeated `DownloadPricingData` errors. Note: the Spot Data Feed will have "no data" for up to an hour after first subscribing (AWS delivers feed files hourly) — this is expected per the spec's "Known Constraints", not a bug.

- [ ] **Step 6: Confirm non-zero cost metrics reach Mimir (wait at least 30s after Step 5 for the first ServiceMonitor scrape)**

Run:
```bash
kubectl -n monitoring exec deploy/kube-prometheus-stack-prometheus -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=node_total_hourly_cost' | python3 -m json.tool
```
Expected: `status: "success"` with at least one non-zero `value` per node — confirms OpenCost's own `/metrics` are being scraped and forwarded through the existing remote-write pipeline, not just that the pod is up.

- [ ] **Step 7: Sanity-check spot pricing against AWS ground truth (once the data feed has delivered its first hourly file — see Step 5 note)**

Run:
```bash
NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}')
INSTANCE_TYPE=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
AZ=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
aws ec2 describe-spot-price-history --region ap-northeast-1 \
  --instance-types "$INSTANCE_TYPE" --availability-zone "$AZ" \
  --product-descriptions "Linux/UNIX" --max-results 1 --query 'SpotPriceHistory[0].SpotPrice' --output text
kubectl -n monitoring exec deploy/kube-prometheus-stack-prometheus -c prometheus -- \
  wget -qO- "http://localhost:9090/api/v1/query?query=node_total_hourly_cost%7Bnode%3D%22${NODE}%22%7D" | python3 -m json.tool
```
Expected: the two hourly-price figures are within a small margin of each other (not off by orders of magnitude — the spec's Out-of-Scope explicitly accepts some drift from on-demand/spot rounding, but a >2x gap would indicate the data feed isn't being read and OpenCost fell back to its formula-based spot estimate).

- [ ] **Step 8: Confirm the Grafana dashboards render without "no data"**

Open Grafana (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`) and load each of the three dashboards added in Task 4 ("OpenCost / Overview", "OpenCost / Namespace", "OpenCost / Workload"). Expected: every panel shows data (not "No data"); if the `$datasource` variable dropdown doesn't default to Mimir, select it manually and confirm panels populate — this determines whether Task 4's assumption (Mimir already configured as Grafana's default datasource) held in practice.
