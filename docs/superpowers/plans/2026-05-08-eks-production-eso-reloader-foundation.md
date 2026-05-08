# EKS Production: External Secrets Operator + Reloader Foundation (Phase 4-2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) に **External Secrets Operator (= jetstack: external-secrets/external-secrets v0.x latest stable) + Reloader (= stakater/reloader v1.x latest stable)** を deploy し、AWS Secrets Manager → K8s Secret sync 基盤 + Secret / ConfigMap 変更時の Deployment auto-rollout 基盤を確立する。新規 terragrunt stack `aws/eks-secrets/` で Pod Identity Association + IAM role (= secretsmanager:GetSecretValue/DescribeSecret + kms:Decrypt 権限) を provision、4-1 で deploy 済の cert-manager + `selfsigned-cluster-issuer` で ESO admission webhook cert を発行、`ClusterSecretStore aws-secrets-manager` で AWS Secrets Manager backend (= ap-northeast-1) を設定。本 sub-project 完了時に panicboat cluster は ESO + Reloader infrastructure を持ち、Phase 5 nginx で AWS Secrets Manager 由来の K8s Secret + Reloader による rollout 動作を検証可能になる。

**Architecture:** ESO の controller / cert-controller / webhook を `external-secrets` namespace、Reloader を `reloader` namespace に deploy。webhook は 3 replicas + `system-cluster-critical` priority class で HA 構成。ClusterSecretStore は cluster-scoped で 1 つ (= name `aws-secrets-manager`)、cluster 全 namespace で共有。Reloader は全 namespace を watch、`reloader.stakater.com/auto: "true"` annotation を持つ Deployment / StatefulSet が rollout 対象。terragrunt-side で IAM role + Pod Identity Association を provision、ESO ServiceAccount から AWS Secrets Manager API call を auth。

**Tech Stack:** Helm + helmfile / `external-secrets/external-secrets` v0.x (= 実装時に latest stable 確認) / `stakater/reloader` v1.x (= 実装時に latest stable 確認) / OpenTofu 1.11.6 + terragrunt / AWS provider v6.43.0 / cert-manager v1.20.x + selfsigned-cluster-issuer (= 4-1 で deploy 済) / kube-prometheus-stack ServiceMonitor

**Spec:** `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**AWS 新規 (aws/eks-secrets/):**
```
aws/eks-secrets/
├── Makefile                                   # convenience targets (= 既 stack 踏襲、optional)
├── envs/
│   └── production/
│       ├── env.hcl                            # production environment locals
│       └── terragrunt.hcl                     # production terragrunt config
├── modules/
│   ├── main.tf                                # IAM role + Pod Identity Association + IAM policy
│   ├── variables.tf                           # environment / aws_region / common_tags
│   ├── outputs.tf                             # iam_role_arn / iam_role_name / association_id
│   ├── lookups.tf                             # eks/lookup module 経由で cluster_name 取得
│   └── terraform.tf                           # OpenTofu + AWS provider 6.43.0
└── root.hcl                                   # root terragrunt config (= 既 stack 踏襲、optional)
```

**Kubernetes 新規 (cert-manager / external-secrets / reloader):**
```
kubernetes/components/external-secrets/
├── namespace.yaml                              # external-secrets namespace 定義
└── production/
    ├── helmfile.yaml                           # external-secrets/external-secrets chart deploy
    ├── values.yaml.gotmpl                      # HA + cert-manager integration + ServiceMonitor
    └── kustomization/
        ├── kustomization.yaml                  # ClusterSecretStore を別途 deploy
        └── cluster-secret-store.yaml           # aws-secrets-manager ClusterSecretStore

kubernetes/components/reloader/
├── namespace.yaml                              # reloader namespace 定義
└── production/
    ├── helmfile.yaml                           # stakater/reloader chart deploy
    └── values.yaml.gotmpl                      # priority class + ServiceMonitor + watchGlobally
```

**Kubernetes 自動生成 (production hydrate output):**
```
kubernetes/manifests/production/external-secrets/{kustomization.yaml, manifest.yaml}    # 新規
kubernetes/manifests/production/reloader/{kustomization.yaml, manifest.yaml}             # 新規
kubernetes/manifests/production/00-namespaces/namespaces.yaml                            # 修正 (= external-secrets / reloader namespace blocks 追加)
kubernetes/manifests/production/kustomization.yaml                                        # 修正 (= ./external-secrets + ./reloader auto-insert)
```

**変更しないファイル**: aws/eks-{metrics,logs,traces}/* / aws/eks/* / aws/karpenter/* / kubernetes/components/cert-manager/* (= 4-1 で deploy 済) / 他 K8s components / kubernetes/components/{external-secrets,reloader}/local/* (= 本 sub-project では作成しない、production 専用)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** 4-2 開始前に cluster 状態 + branch 状態を確認。Phase 4-1 完了状態 (= cert-manager + selfsigned-cluster-issuer deploy 済) を baseline、4-2 で ESO admission webhook cert 用に利用する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-eso-reloader-foundation
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead
```
f24ec70 docs(eks): Phase 4-2 (ESO + Reloader foundation) design
```

- [ ] **Step 2: cert-manager + selfsigned-cluster-issuer 動作確認 (= 4-1 で deploy 済の前提を verify)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- cert-manager pods ---"
kubectl get pods -n cert-manager
echo ""
echo "--- selfsigned-cluster-issuer Ready ---"
kubectl get clusterissuer selfsigned-cluster-issuer -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo ""
echo "--- 既存 Certificate (= 4-1 deploy 済の Hubble TLS、4-2 では touched なし) ---"
kubectl get certificate -A | head -5'
```

Expected:
- cert-manager pods 全 Running (= controller × 1 + cainjector × 1 + webhook × 3)
- ClusterIssuer Ready=`True`
- Hubble TLS certificates (= `hubble-server-certs` / `hubble-relay-client-certs`) Ready=True

- [ ] **Step 3: external-secrets / reloader namespace 不在確認 (= 想定通り)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get namespace external-secrets reloader 2>&1 | head -5'
```

Expected: `Error from server (NotFound): namespaces "external-secrets" not found` + 同 reloader

- [ ] **Step 4: AWS Secrets Manager の test access (= 4-2 で provision する IAM role 不在のため、user の AWS credentials で確認)**

```bash
zsh -ic 'aws secretsmanager list-secrets --region ap-northeast-1 --max-results 5 2>&1 | head -15'
```

Expected: `SecretList: []` or 既存 secrets が表示される (= AWS account への access が機能、Secrets Manager service が available)

- [ ] **Step 5: 既存 terragrunt stacks 状態確認 (= aws/eks/ + aws/eks-{metrics,logs,traces}/ が動作中)**

```bash
ls aws/
echo "---"
# Karpenter / EKS / metrics / logs / traces stacks の terragrunt state list (= 状態確認)
zsh -ic 'cd aws/eks/envs/production && terragrunt state list 2>&1 | head -3'
```

Expected: aws/ 配下に `eks-{metrics,logs,traces}` stacks 存在、`aws/eks-secrets/` は **不在** (= 4-2 Task 1 で新規作成)

- [ ] **Step 6: Phase 3 monitoring stack の健康確認 (= regression baseline)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get pods -n monitoring | grep -v Completed | grep -v "1/1\|2/2\|3/3" | head -5 || echo "(全 monitoring pod Ready)"'
```

Expected: 結果なし (= 全 monitoring pod が Ready 状態)

- [ ] **Step 7: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1 | head -3'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:7bc7469` (= 直近 main = Phase 4-1 learnings PR #307 merge 済) もしくはそれ以降の commit

---

## Task 1: AWS infra (`aws/eks-secrets/` 新規 stack)

**Files:**
- Create: `aws/eks-secrets/envs/production/env.hcl`
- Create: `aws/eks-secrets/envs/production/terragrunt.hcl`
- Create: `aws/eks-secrets/modules/main.tf`
- Create: `aws/eks-secrets/modules/variables.tf`
- Create: `aws/eks-secrets/modules/outputs.tf`
- Create: `aws/eks-secrets/modules/lookups.tf`
- Create: `aws/eks-secrets/modules/terraform.tf`

**Context:** Sub-project 1 の `aws/eks-traces/` stack pattern を踏襲。IAM role + Pod Identity Association を provision、ESO ServiceAccount (= `external-secrets/external-secrets`) が AWS Secrets Manager API call を auth するための setup。

### Step 1: ディレクトリ構造を作成

```bash
mkdir -p aws/eks-secrets/envs/production
mkdir -p aws/eks-secrets/modules
```

### Step 2: `aws/eks-secrets/modules/terraform.tf` 作成

```hcl
# terraform.tf - OpenTofu and provider configuration

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.43.0"
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

### Step 3: `aws/eks-secrets/modules/variables.tf` 作成

```hcl
# variables.tf - Inputs for the eks-secrets module

variable "environment" {
  description = "Environment name (e.g., production). Used in IAM role name."
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

### Step 4: `aws/eks-secrets/modules/lookups.tf` 作成

```hcl
# lookups.tf - External stack lookups.

# EKS cluster info (for Pod Identity Association cluster_name)
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
```

### Step 5: `aws/eks-secrets/modules/main.tf` 作成

```hcl
# main.tf - EKS Secrets AWS-side infrastructure (IAM role + Pod Identity for ESO).
#
# Provides:
# 1. IAM role bound by Pod Identity Association to K8s SA
#    `external-secrets:external-secrets`
#    - AWS Secrets Manager read access (account 内全 secrets、minimum permissions)
#    - KMS Decrypt (= Secrets Manager 経由のみ、kms:ViaService condition で限定)
# 2. Pod Identity Association binding `external-secrets:external-secrets` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# Sub-project 4-2 (= ESO + Reloader) は本 stack の outputs を terragrunt output 経由で
# 取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  service_name = "external-secrets" # K8s ServiceAccount name
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-eso"

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

# IAM policy for AWS Secrets Manager read access (= minimum required)
# 2 statement: SecretsManagerRead / KmsDecryptForSecretsManager
# NOTE: Resource: "secret:*" で account 内全 secrets access、Phase 6+ で multi-team
# 化時に fine-grained scoping を再評価。
resource "aws_iam_role_policy" "secrets_access" {
  name = "secrets-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
      },
      {
        Sid    = "KmsDecryptForSecretsManager"
        Effect = "Allow"
        Action = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = local.service_name
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
```

### Step 6: `aws/eks-secrets/modules/outputs.tf` 作成

```hcl
# outputs.tf - Outputs for the eks-secrets module.

output "pod_identity_role_name" {
  description = "IAM role name bound to external-secrets:external-secrets SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for external-secrets:external-secrets SA Pod Identity binding. Referenced by Sub-project 4-2 helmfile values."
  value       = aws_iam_role.pod_identity.arn
}

output "pod_identity_association_id" {
  description = "Pod Identity Association ID. Used for verification (aws eks describe-pod-identity-association)."
  value       = aws_eks_pod_identity_association.this.association_id
}

output "pod_identity_association_arn" {
  description = "Pod Identity Association ARN."
  value       = aws_eks_pod_identity_association.this.association_arn
}
```

### Step 7: `aws/eks-secrets/envs/production/env.hcl` 作成

```hcl
# env.hcl - Environment-specific configuration for production

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks-secrets"
    Owner       = "panicboat"
  }
}
```

### Step 8: `aws/eks-secrets/envs/production/terragrunt.hcl` 作成

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
  source = "../../..//eks-secrets/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-secrets"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

### Step 9: terragrunt init + plan (= 動作確認、まだ apply はしない)

```bash
cd aws/eks-secrets/envs/production
terragrunt init
terragrunt plan 2>&1 | tail -30
cd -
```

Expected: 3 resources を create する plan 出力
```
Plan: 3 to add, 0 to change, 0 to destroy.
```
- `aws_iam_role.pod_identity`
- `aws_iam_role_policy.secrets_access`
- `aws_eks_pod_identity_association.this`

NOTE: 本 step は plan のみ、apply は **Task 5 (= manifests hydrate 完了後) で実施** (= AWS infra と K8s deploy の atomic commit + USER review 後の merge で同時 apply)。

### Step 10: Diff 確認 + Commit

```bash
git status
```

Expected: 7 files added (= main.tf + variables.tf + outputs.tf + lookups.tf + terraform.tf + env.hcl + terragrunt.hcl)

```bash
git add aws/eks-secrets/
git commit -s -m "feat(eks): aws/eks-secrets stack for ESO Pod Identity (Phase 4-2)"
```

Expected: 7 files changed、commit subject ≤ 72 chars (= 65 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 2: ESO + ClusterSecretStore deploy

**Files:**
- Create: `kubernetes/components/external-secrets/namespace.yaml`
- Create: `kubernetes/components/external-secrets/production/helmfile.yaml`
- Create: `kubernetes/components/external-secrets/production/values.yaml.gotmpl`
- Create: `kubernetes/components/external-secrets/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/external-secrets/production/kustomization/cluster-secret-store.yaml`

**Context:** Phase 4-2 で deploy する External Secrets Operator (= external-secrets/external-secrets) の component 全体を新規作成。Phase 4-1 (= cert-manager) と同 pattern で `production/helmfile.yaml` + `production/values.yaml.gotmpl` を作成、ClusterSecretStore (= chart 範囲外) を `production/kustomization/cluster-secret-store.yaml` で追加。

### Step 1: chart 最新 stable version + key path 確認 (= Sub-project 4-1 L1 systematic application)

```bash
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo update external-secrets
helm search repo external-secrets/external-secrets --versions | head -5
```

Expected: 上位に latest stable version (= `v0.10.x` or 最新) が表示。spec では `v0.10.x` を仮定したが、実際の最新 stable patch を採用。

### Step 2: chart values の key path を確認 (= 4b L1 + 4-1 L1 適用、特に注意 keys)

```bash
helm show values external-secrets/external-secrets --version <step1 で確認した version> | head -100
```

確認すべき keys:
- `installCRDs` vs `crds.enabled`
- `webhook.certManager.cert.issuerRef.{name, kind, group}` の正確な path
- `serviceMonitor.additionalLabels` vs `serviceMonitor.labels` vs `serviceMonitor.extraLabels`
- `priorityClassName` の配置 (= top-level vs 各 component 配下)

NOTE: chart 固有 key path に従って Step 5 values.yaml.gotmpl を調整。

### Step 3: namespace.yaml を作成

`kubernetes/components/external-secrets/namespace.yaml`:

```yaml
# =============================================================================
# external-secrets Namespace
# =============================================================================
# External Secrets Operator (controller / cert-controller / webhook) の専用 namespace。
# AWS Secrets Manager から K8s Secret への sync 基盤。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
  labels:
    app.kubernetes.io/name: external-secrets
```

### Step 4: production/helmfile.yaml を作成

`kubernetes/components/external-secrets/production/helmfile.yaml`:

```yaml
# =============================================================================
# external-secrets Helmfile for production
# =============================================================================
# External Secrets Operator (= external-secrets/external-secrets) の deploy。
# admission webhook cert は cert-manager + selfsigned-cluster-issuer で発行、
# ClusterSecretStore は kustomization で別途 deploy (= chart 範囲外)。
# =============================================================================
environments:
  production:
---
repositories:
  - name: external-secrets
    url: https://charts.external-secrets.io

releases:
  - name: external-secrets
    namespace: external-secrets
    chart: external-secrets/external-secrets
    version: "<step 1 で確認した latest stable、例 v0.10.x>"
    values:
      - values.yaml.gotmpl
```

### Step 5: production/values.yaml.gotmpl を作成

`kubernetes/components/external-secrets/production/values.yaml.gotmpl`:

```yaml
# external-secrets Configuration for production
# AWS Secrets Manager backend で K8s Secret を sync する基盤。

# =============================================================================
# CRDs (= chart 経由で install)
# =============================================================================
installCRDs: true

# =============================================================================
# Global config: Priority class
# =============================================================================
priorityClassName: system-cluster-critical

# =============================================================================
# Controller (= main reconciliation loop)
# =============================================================================
replicaCount: 1
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    memory: 128Mi

# =============================================================================
# Webhook (= 公式 production = 3 replicas で HA)
# =============================================================================
# NOTE: ESO admission webhook が不可になると ExternalSecret CR の create / update /
# delete が全部 fail、cert-manager と同 risk 構造のため同 mitigation (= 3 replicas)。
webhook:
  replicaCount: 3
  certManager:
    enabled: true
    cert:
      issuerRef:
        name: selfsigned-cluster-issuer
        kind: ClusterIssuer
        group: cert-manager.io
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 64Mi

# =============================================================================
# Cert Controller (= Certificate resource auto-creation)
# =============================================================================
certController:
  replicaCount: 1
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 64Mi

# =============================================================================
# ServiceMonitor (= kube-prometheus-stack の serviceMonitorSelector に乗る)
# =============================================================================
# NOTE: chart の ServiceMonitor key path は Step 2 で確認した値を使用。
# Mimir / Loki / Tempo / cert-manager の各 chart 固有 key とは異なる patterns。
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack
  interval: 30s
```

NOTE: Step 2 で確認した key path に従い、`installCRDs` / `webhook.certManager.cert.issuerRef.*` / `serviceMonitor.additionalLabels` 等を chart actual values に修正。

### Step 6: helmfile template で render verify

```bash
helmfile -f kubernetes/components/external-secrets/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -E "kind: ServiceMonitor|kind: Deployment|kind: CustomResourceDefinition" | head -20
```

Expected:
- 7+ CRDs (= `clusterexternalsecrets` / `clustersecretstores` / `externalsecrets` / `secretstores` / `clusterpushsecrets` / `pushsecrets` 等) が render される
- 3 Deployments (`external-secrets` / `external-secrets-cert-controller` / `external-secrets-webhook`) が render される
- ServiceMonitor 1+ 件 が render される

```bash
# Webhook 3 replicas 確認
helmfile -f kubernetes/components/external-secrets/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -B2 "replicas: 3" | head -5
```

Expected: `external-secrets-webhook` Deployment に `replicas: 3`

```bash
# system-cluster-critical priority 確認
helmfile -f kubernetes/components/external-secrets/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -E "priorityClassName" | head -5
```

Expected: 3 Deployment 全てに `priorityClassName: system-cluster-critical`

```bash
# cert-manager Certificate resource 生成確認 (= webhook.certManager.enabled: true で生成される)
helmfile -f kubernetes/components/external-secrets/production/helmfile.yaml -e production template --include-crds --skip-tests 2>&1 | \
  grep -B1 -A5 "kind: Certificate" | head -10
```

Expected: `external-secrets-webhook` Certificate が `issuerRef.name: selfsigned-cluster-issuer` で render される

### Step 7: ClusterSecretStore kustomization を作成

`kubernetes/components/external-secrets/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# external-secrets Kustomization for production
# =============================================================================
# ClusterSecretStore (= chart 範囲外) を kustomization で別途 deploy。
# external-secrets CRDs install 後に Flux が ClusterSecretStore を apply (= 失敗時 retry)。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - cluster-secret-store.yaml
```

`kubernetes/components/external-secrets/production/kustomization/cluster-secret-store.yaml`:

```yaml
# =============================================================================
# AWS Secrets Manager ClusterSecretStore
# =============================================================================
# cluster 全 namespace から参照可能な共有 SecretStore。
# Pod Identity Association 経由で AWS Secrets Manager (= ap-northeast-1) に access。
# =============================================================================
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

NOTE: ESO chart actual version の auth syntax を ESO 公式 docs ([external-secrets.io/main/provider/aws-secrets-manager/](https://external-secrets.io/main/provider/aws-secrets-manager/)) で確認。Pod Identity Association を使う場合の syntax は version で異なる:
- v0.9.x 以前: `auth.jwt.serviceAccountRef` で IRSA token 経由
- v0.10+: Pod Identity Association を auto detect、auth block 省略可能 or 別 syntax

### Step 8: Diff 確認

```bash
git status
```

Expected: 5 files added (= namespace.yaml + helmfile.yaml + values.yaml.gotmpl + kustomization.yaml + cluster-secret-store.yaml)

### Step 9: Commit

```bash
git add kubernetes/components/external-secrets/
git commit -s -m "feat(eks): External Secrets Operator + ClusterSecretStore (Phase 4-2)"
```

Expected: 5 files changed、commit subject ≤ 72 chars (= 67 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 3: Reloader deploy

**Files:**
- Create: `kubernetes/components/reloader/namespace.yaml`
- Create: `kubernetes/components/reloader/production/helmfile.yaml`
- Create: `kubernetes/components/reloader/production/values.yaml.gotmpl`

**Context:** Phase 4-2 で deploy する Stakater Reloader の component 全体を新規作成。passive watcher (= admission webhook 不在) のため 1 replica で十分。watch scope は全 namespace + opt-in annotation。

### Step 1: chart 最新 stable version + key path 確認 (= Sub-project 4-1 L1 systematic application)

```bash
helm repo add stakater https://stakater.github.io/stakater-charts --force-update
helm repo update stakater
helm search repo stakater/reloader --versions | head -5
```

Expected: 上位に latest stable version (= `v1.x` or 最新) が表示。

### Step 2: chart values の key path を確認

```bash
helm show values stakater/reloader --version <step1 で確認した version> | head -100
```

確認すべき keys:
- `reloader.deployment.replicas` の path (= top-level vs `reloader.deployment` 配下)
- `reloader.deployment.priorityClassName` の path
- `reloader.watchGlobally` の path
- `reloader.serviceMonitor.additionalLabels` vs `reloader.serviceMonitor.labels` vs 同 extraLabels
- `reloader.podMonitor.enabled` (= ServiceMonitor を使うため podMonitor 不要)

### Step 3: namespace.yaml を作成

`kubernetes/components/reloader/namespace.yaml`:

```yaml
# =============================================================================
# reloader Namespace
# =============================================================================
# Stakater Reloader (= reloader-controller) の専用 namespace。
# Secret / ConfigMap 変更時に annotation 付きの Deployment / StatefulSet を auto-rollout する。
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: reloader
  labels:
    app.kubernetes.io/name: reloader
```

### Step 4: production/helmfile.yaml を作成

`kubernetes/components/reloader/production/helmfile.yaml`:

```yaml
# =============================================================================
# reloader Helmfile for production
# =============================================================================
# Stakater Reloader の deploy。passive watcher、admission webhook 不在のため
# 1 replica で十分。
# =============================================================================
environments:
  production:
---
repositories:
  - name: stakater
    url: https://stakater.github.io/stakater-charts

releases:
  - name: reloader
    namespace: reloader
    chart: stakater/reloader
    version: "<step 1 で確認した latest stable、例 v1.x>"
    values:
      - values.yaml.gotmpl
```

### Step 5: production/values.yaml.gotmpl を作成

`kubernetes/components/reloader/production/values.yaml.gotmpl`:

```yaml
# reloader Configuration for production
# Secret / ConfigMap 変更時の Deployment / StatefulSet auto-rollout。
# watch scope は全 namespace、opt-in annotation で対象指定。

# =============================================================================
# Reloader controller
# =============================================================================
reloader:
  watchGlobally: true                  # 全 namespace を watch (= chart default)

  deployment:
    replicas: 1                        # passive watcher、SPOF 影響軽微

    priorityClassName: system-cluster-critical

    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        memory: 128Mi

  podMonitor:
    enabled: false                     # ServiceMonitor を使うため podMonitor 不要

  service:
    enabled: true                      # ServiceMonitor は Service が必要

  serviceMonitor:
    enabled: true
    additionalLabels:
      release: kube-prometheus-stack
```

NOTE: Step 2 で確認した key path に従い、`reloader.deployment.priorityClassName` / `reloader.serviceMonitor.additionalLabels` 等を chart actual values に修正。

### Step 6: helmfile template で render verify

```bash
helmfile -f kubernetes/components/reloader/production/helmfile.yaml -e production template --skip-tests 2>&1 | \
  grep -E "kind: ServiceMonitor|kind: Deployment|priorityClassName|watch-globally" | head -10
```

Expected:
- 1 Deployment (`reloader-reloader`) が render される
- ServiceMonitor が 1 件 render される
- `priorityClassName: system-cluster-critical` が render される
- args に `--watch-globally=true` 等の watch all namespaces 引数

### Step 7: Diff 確認

```bash
git status
```

Expected: 3 files added (= namespace.yaml + helmfile.yaml + values.yaml.gotmpl)

### Step 8: Commit

```bash
git add kubernetes/components/reloader/
git commit -s -m "feat(eks): Stakater Reloader for Secret/ConfigMap rollout (Phase 4-2)"
```

Expected: 3 files changed、commit subject ≤ 72 chars (= 70 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 4: Hydrate manifests + verify

**Files:**
- Modify (auto-generated): `kubernetes/manifests/production/external-secrets/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/reloader/{kustomization.yaml, manifest.yaml}` (= 新規)
- Modify (auto-generated): `kubernetes/manifests/production/00-namespaces/namespaces.yaml` (= 2 namespace blocks 追加)
- Modify (auto-generated): `kubernetes/manifests/production/kustomization.yaml` (= 2 resources auto-insert)

**Context:** Task 2 + 3 で K8s component values + namespace.yaml + kustomization 修正済。Task 4 で hydrated manifests を再生成し、Flux が apply する actual YAML を更新する。

### Step 1: external-secrets manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=external-secrets ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/external-secrets/manifest.yaml` 新規作成 (= chart render + ClusterSecretStore)
- `kubernetes/manifests/production/external-secrets/kustomization.yaml` 新規作成 (= `resources: [manifest.yaml]`)

### Step 2: reloader manifest を新規生成

```bash
cd kubernetes
make hydrate-component COMPONENT=reloader ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/reloader/manifest.yaml` 新規作成 (= chart render)
- `kubernetes/manifests/production/reloader/kustomization.yaml` 新規作成

### Step 3: production の 00-namespaces + kustomization を再生成

```bash
cd kubernetes
make hydrate-index ENV=production
cd ..
```

Expected:
- `kubernetes/manifests/production/00-namespaces/namespaces.yaml` 更新 (= `external-secrets` + `reloader` Namespace blocks 追加、alphabetical order 自動 insert)
- `kubernetes/manifests/production/kustomization.yaml` 更新 (= `./external-secrets` + `./reloader` resources line 自動 insert)

### Step 4: external-secrets manifest 内容確認

```bash
grep -E "kind: (Deployment|ClusterSecretStore|CustomResourceDefinition|ServiceMonitor|Certificate)" \
  kubernetes/manifests/production/external-secrets/manifest.yaml | sort | uniq -c
```

Expected:
- 7+ CRDs (external-secrets.io 系)
- 3 Deployments (`external-secrets` / `external-secrets-cert-controller` / `external-secrets-webhook`)
- 1 ClusterSecretStore (`aws-secrets-manager`)
- 1+ ServiceMonitor
- 1 Certificate (= `external-secrets-webhook` cert-manager-managed)

### Step 5: ClusterSecretStore の AWS provider 設定確認

```bash
grep -B1 -A10 "kind: ClusterSecretStore" kubernetes/manifests/production/external-secrets/manifest.yaml | head -20
```

Expected:
```yaml
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

### Step 6: reloader manifest 内容確認

```bash
grep -E "kind: (Deployment|ServiceMonitor|Service|ServiceAccount)" \
  kubernetes/manifests/production/reloader/manifest.yaml | head -10
echo ""
grep -B1 -A1 "priorityClassName" kubernetes/manifests/production/reloader/manifest.yaml | head -5
echo ""
grep "watch-globally" kubernetes/manifests/production/reloader/manifest.yaml | head -3
```

Expected:
- 1 Deployment (`reloader-reloader`)
- 1 ServiceMonitor
- 1 Service (= ServiceMonitor の前提)
- 1 ServiceAccount
- `priorityClassName: system-cluster-critical`
- args に `--watch-globally=true` 等

### Step 7: 00-namespaces.yaml に external-secrets + reloader namespace 追加確認

```bash
grep -B1 -A3 "name: external-secrets" kubernetes/manifests/production/00-namespaces/namespaces.yaml | head -10
echo ""
grep -B1 -A3 "name: reloader" kubernetes/manifests/production/00-namespaces/namespaces.yaml | head -10
```

Expected: 両 namespace block が表示される

### Step 8: production kustomization.yaml に ./external-secrets + ./reloader 追加確認

```bash
grep -E "external-secrets|reloader" kubernetes/manifests/production/kustomization.yaml
```

Expected:
- `  - ./external-secrets` が resources list に含まれる (= alphabetical order)
- `  - ./reloader` が resources list に含まれる

### Step 9: kustomize build で全体 manifest が valid render することを確認

```bash
kustomize build kubernetes/manifests/production 2>&1 | tail -10
```

Expected: error なし、最後に何らかの YAML resource が出力される (= kustomization build success)

### Step 10: Diff 確認

```bash
git status
git diff --stat
```

Expected:
- 新規: production/external-secrets/{kustomization.yaml, manifest.yaml}
- 新規: production/reloader/{kustomization.yaml, manifest.yaml}
- 修正: production/00-namespaces/namespaces.yaml (= external-secrets + reloader 追加)
- 修正: production/kustomization.yaml (= ./external-secrets + ./reloader 追加)

### Step 11: Commit

```bash
git add kubernetes/manifests/
git commit -s -m "feat(eks): hydrate external-secrets + reloader (Phase 4-2)"
```

Expected: 5-6 files changed、commit subject ≤ 72 chars (= 56 chars)、`-s` signoff、Co-Authored-By 不在

---

## Task 5: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR + terragrunt apply 操作のみ)

**Context:** Task 1-4 完了後の commit 累計 5 件 (= spec + 4 implementation)。AWS-side terragrunt apply は **PR merge 前に user が実行**、K8s-side は PR merge 後に Flux reconcile で auto apply。Sub-project 2 / 3 / 4a / 4b / 4-1 で確立した standard runbook + AWS-side step 追加。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/docs/eks-production-eso-reloader-foundation
git log --oneline origin/main..HEAD
```

Expected: 5 commits ahead (Task 1 から Task 4 まで + spec commit)
```
<sha> feat(eks): hydrate external-secrets + reloader (Phase 4-2)
<sha> feat(eks): Stakater Reloader for Secret/ConfigMap rollout (Phase 4-2)
<sha> feat(eks): External Secrets Operator + ClusterSecretStore (Phase 4-2)
<sha> feat(eks): aws/eks-secrets stack for ESO Pod Identity (Phase 4-2)
f24ec70 docs(eks): Phase 4-2 (ESO + Reloader foundation) design
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (= 既 spec push 時に `git push -u origin HEAD` 済)、push success message

### Step 3: PR title 文字数チェック (≤ 72 chars)

```bash
echo -n "feat(eks): Phase 4-2 — ESO + Reloader foundation" | wc -m
```

Expected: 49 chars (em dash 含む、Sub-project 4-1 の PR title 命名 pattern と整合)

### Step 4: Draft PR を作成 (Pre-flight check 結果を含む)

PR body は以下:

```markdown
## Summary

Phase 4-2 (External Secrets Operator + Reloader foundation) の implementation。`external-secrets/external-secrets` v0.x を `external-secrets` namespace、`stakater/reloader` v1.x を `reloader` namespace に deploy。AWS Secrets Manager backend の `ClusterSecretStore aws-secrets-manager` を 1 つ作成 (= 4-1 で deploy 済の `selfsigned-cluster-issuer` で ESO admission webhook cert 発行)。新規 terragrunt stack `aws/eks-secrets/` で IAM role + Pod Identity Association を provision。本 sub-project 完了時に panicboat cluster は ESO + Reloader infrastructure を持ち、Phase 5 nginx で AWS Secrets Manager 由来の K8s Secret + Reloader による rollout 動作を検証可能になる。

**Architecture (4-2 完了時):** ESO の controller / cert-controller / webhook (= 3 replicas + system-cluster-critical priority) が `external-secrets` namespace に deploy。Reloader が `reloader` namespace で 1 replica で稼働。ClusterSecretStore が AWS Secrets Manager backend (= ap-northeast-1) で Pod Identity 経由 auth で Ready=True。

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-08-eks-production-eso-reloader-foundation-design.md` (11 Decisions、Sub-project 1-4-1 learnings ~36 件のうち applicable 全項目適用)
- Plan: `docs/superpowers/plans/2026-05-08-eks-production-eso-reloader-foundation.md` (5 tasks)

## Notable Decisions

- **D1**: ESO chart = `external-secrets/external-secrets` v0.x latest stable (= 実装時に latest verify)
- **D2**: Reloader chart = `stakater/reloader` v1.x latest stable
- **D4**: ESO HA = webhook 3 replicas + `system-cluster-critical` priority (= 4-1 cert-manager と同 pattern、admission webhook SPOF 回避)
- **D5**: Reloader = 1 replica + `system-cluster-critical` priority (= passive watcher、HA は overkill)
- **D6**: ClusterSecretStore = `aws-secrets-manager` 1 つ (= cluster 全 namespace 共有、AWS Secrets Manager backend、Pod Identity 経由 auth)
- **D7**: AWS infra stack = `aws/eks-secrets/` (= 命名 clarity 重視、"ESO" より概念的に分かりやすい)
- **D8**: ESO IAM permissions = `secretsmanager:GetSecretValue/DescribeSecret` + `kms:Decrypt` (= minimum required、`Resource: "secret:*"` で account 内全 secrets access)
- **D9**: ESO admission webhook cert = cert-manager + `selfsigned-cluster-issuer` (= 4-1 で確立した pattern の systematic application)
- **D10**: Reloader watch scope = 全 namespace + opt-in annotation (`reloader.stakater.com/auto: "true"`、chart default)
- **D11**: 1 sub-project 構成 (= AWS infra + ESO + Reloader を atomic merge、Sub-project 4a と同 pattern)

## Implementation 補記

- **Chart version 確定**: 実装時に `helm search repo --versions` で actual latest stable を確認、採用 (= Sub-project 4b L1 「spec 段階 chart binary verify」 + 4-1 L1 「systematic application」 の継続)
- **Chart 固有 key path**: `installCRDs` / `webhook.certManager.cert.issuerRef.*` / `serviceMonitor.additionalLabels` / `reloader.deployment.priorityClassName` 等を実装段階で `helm show values` で事前確認
- **terragrunt apply 順序**: AWS 先 (= IAM role + Pod Identity Association) → K8s 後 (= Flux reconcile)、Pod Identity Association 反映 (= ~1 min) 後に ClusterSecretStore Ready=True

## Pre-flight check (executed pre-merge)

- [x] Branch state 1 commit (spec) ahead (Task 0 Step 1)
- [x] cert-manager + selfsigned-cluster-issuer 動作確認 (= 4-1 deploy 済) (Task 0 Step 2)
- [x] external-secrets / reloader namespace 不在確認 (Task 0 Step 3)
- [x] AWS Secrets Manager service available (Task 0 Step 4)
- [x] aws/eks-secrets/ stack 不在確認 (= 4-2 で新規) (Task 0 Step 5)
- [x] Phase 3 monitoring stack 全 pod Running (Task 0 Step 6)
- [x] Flux not suspended (Task 0 Step 7)

## Test plan (post-flight, after merge)

USER は以下を **PR merge 前に** 実行:
1. AWS-side: `cd aws/eks-secrets/envs/production && terragrunt apply`
2. K8s-side: PR merge → Flux reconcile

### 10 分以内
- [ ] AWS infra: `aws iam get-role --role-name eks-production-eso` で IAM role 確認
- [ ] AWS infra: Pod Identity Association 確認 (`aws eks list-pod-identity-associations`)
- [ ] external-secrets namespace + 全 5 pods Running (= controller × 1 + cert-controller × 1 + webhook × 3)、restartCount 0
- [ ] webhook 3 pods 全てに `priority=system-cluster-critical` 付与
- [ ] 7+ ESO CRDs install 確認
- [ ] ESO admission webhook Certificate (`external-secrets-webhook`) Ready=True (= cert-manager 由来)
- [ ] **ClusterSecretStore `aws-secrets-manager` Ready=True** (= 重要、Pod Identity 動作 verify)
- [ ] reloader namespace + pod Running 1/1、restartCount 0
- [ ] Reloader pod に `priority=system-cluster-critical`、args に `--watch-globally=true`

### 30 分以内
- [ ] ESO + Reloader ServiceMonitor + Prometheus targets で UP
- [ ] Mimir に `externalsecret_*` / `reloader_*` metrics が remote_write 保存済、Grafana で query 可能
- [ ] ESO Pod Identity 動作 direct verify (= ESO controller pod から aws cli で list-secrets) もしくは ClusterSecretStore Ready=True で代替
- [ ] 既存 4-1 path (= cert-manager + Cilium TLS) regression なし
- [ ] ESO + Reloader log で過去 10m persistent error なし (= 起動直後 ~60s 以内の transient は L3 checklist で除外)

### Sub-project 4a L3 + 4-1 L2 適用 (= persistent vs transient checklist)

各 verification step で error log を発見した場合:
1. 時刻情報を確認 (= 起動 ~60 秒以内の transient は retry で resolve)
2. `kubectl logs --since=10m` で最近の error/warn を確認
3. `restartCount > 0` なら persistent
4. `kubectl get -o jsonpath` で truncate 回避
5. cert-manager-style chicken-and-egg startup pattern を認識 (= ESO controller も webhook readiness gap で transient error 発生)
6. AWS Pod Identity propagation timing を認識 (= terragrunt apply 後 ~1 min 待機)

## Sub-project 1-4-1 learnings 適用

| Learning | 4-2 での適用 |
|---|---|
| **2-L1 (chart upgrade での upstream changelog 確認)** | ESO + Reloader chart の latest stable + release notes / breaking changes を Step 1 で確認 |
| **3-L1 (chart 内部固定 path 問題)** | ESO chart の `webhook.certManager.cert.issuerRef.*` / Reloader chart の `reloader.deployment.priorityClassName` の正確な path を `helm show values` で pre-validate |
| **3-L9 (公式 docs 引用)** | ESO 公式 docs ([external-secrets.io](https://external-secrets.io/main/provider/aws-secrets-manager/)) を ClusterSecretStore auth syntax で direct citation |
| **4a-L1 (累積効果で 0 issue)** | 4-2 でも 0 runtime issue 目標、Sub-project 1-4-1 learnings 全項目適用 |
| **4a-L2 (startup transient を persistent と決めつけない)** | post-flight verification で起動 ~60s 以内の transient error は L3 checklist で除外 |
| **4a-L3 (persistent vs transient 5-step checklist)** | post-flight check section の最後に明示組み込み、加えて AWS Pod Identity propagation timing も追加 |
| **4a-L7 (sub-project 分割 ROI)** | 4-2 は AWS infra + ESO + Reloader を 1 sub-project (= D11)、依存関係明確で atomic merge が natural |
| **4b-L1 (spec 段階 chart binary verify systematic application)** | **最重要適用 (= 4-1 で証明済)**: ESO + Reloader chart の latest stable version + 全 values key を Plan Step 1-2 で `helm show values` + `helm template` で systematic verify |
| **4-1 L1 (chart binary verify systematic application)** | **継続適用**: 4-2 でも Plan Step 1-2 で chart latest stable version 確認 + `helm show values` + `helm template` の systematic step を組み込み |
| **4-1 L2 (cert-manager startup transient pattern)** | **同 pattern 適用**: ESO controller も admission webhook readiness gap で同 transient error 発生 (= "no endpoints available")、~30-60s 以内なら normal、L3 checklist で除外 |
| **4-1 L4 (subagent-driven development cadence improvement)** | **継続適用**: Combined spec + code reviewer pattern を 4-2 でも採用 |
| **4-1 L5 (spec の chart version placeholder pattern)** | **継続適用**: spec で `v0.x` placeholder、Plan で "実装時に latest stable 確認" 指示、actual version は subagent が決定 |

## Rollback 手順 (想定外障害時)

```bash
# Pattern A: Standard rollback (= Flux suspend + revert + terragrunt destroy)
flux suspend kustomization flux-system -n flux-system
gh pr create --title "revert: Phase 4-2 — ESO + Reloader" --base main
gh pr merge <revert-pr-num> --squash
cd aws/eks-secrets/envs/production && terragrunt destroy
flux resume kustomization flux-system -n flux-system

# Pattern B: Partial rollback (= ESO のみ、Reloader 維持)
# Pattern C: Reloader のみ rollback
```

詳細は spec の Risks / Rollback section を参照。
```

```bash
gh pr create --draft \
  --title "feat(eks): Phase 4-2 — ESO + Reloader foundation" \
  --body "$(<上記 PR body>)"
```

Expected: PR URL 出力 (例: `https://github.com/panicboat/platform/pull/<N>`)

### Step 5: PR URL を確認

```bash
gh pr view --json title,url,isDraft --jq '.'
```

Expected:
```json
{
    "isDraft": true,
    "title": "feat(eks): Phase 4-2 — ESO + Reloader foundation",
    "url": "https://github.com/panicboat/platform/pull/<N>"
}
```

(ここで USER GATE: terragrunt apply → PR review + Ready for review + merge は user 操作)

---

## Self-review

### Spec coverage

| Spec section | 実装 task | カバレッジ |
|---|---|---|
| Architecture (mermaid 4-2 完了時) | Task 1 + 2 + 3 | ✅ AWS infra + ESO + Reloader components すべて |
| Scope (4 task) | Task 1 / 2 / 3 / 4 | ✅ AWS / ESO / Reloader / Hydrate すべて |
| Out of scope (Phase 4-3 / Phase 5 / Phase 6+) | (= deploy しないため task 不在) | ✅ |
| Decision 1 (chart `external-secrets/external-secrets` v0.x) | Task 2 Step 1 (= version 確認) + Step 4 (helmfile.yaml) | ✅ |
| Decision 2 (chart `stakater/reloader` v1.x) | Task 3 Step 1 + Step 4 | ✅ |
| Decision 3 (namespace dedicated 別々) | Task 2 Step 3 (external-secrets) + Task 3 Step 3 (reloader) | ✅ |
| Decision 4 (ESO HA: webhook 3 replicas + system-cluster-critical) | Task 2 Step 5 (`webhook.replicaCount: 3`、`priorityClassName: system-cluster-critical`) + Step 6 (= render verify) | ✅ |
| Decision 5 (Reloader 1 replica + system-cluster-critical) | Task 3 Step 5 (`reloader.deployment.replicas: 1`、`priorityClassName`) + Step 6 (= render verify) | ✅ |
| Decision 6 (ClusterSecretStore `aws-secrets-manager`) | Task 2 Step 7 (cluster-secret-store.yaml) | ✅ |
| Decision 7 (AWS infra stack `aws/eks-secrets/`) | Task 1 (= 全体構造) | ✅ |
| Decision 8 (ESO IAM permissions = minimum required) | Task 1 Step 5 (= main.tf の `aws_iam_role_policy.secrets_access`) | ✅ |
| Decision 9 (ESO admission webhook cert = cert-manager) | Task 2 Step 5 (`webhook.certManager.cert.issuerRef.*`) | ✅ |
| Decision 10 (Reloader watch scope = 全 namespace + opt-in) | Task 3 Step 5 (`reloader.watchGlobally: true`) | ✅ |
| Decision 11 (1 sub-project atomic merge) | Task 5 (= 5 commits 1 PR) | ✅ |
| Risks / Rollback (Pattern A/B/C + multi-layer) | Task 5 Step 4 (PR body の Rollback 手順) | ✅ |
| Post-flight check (15 items) | Task 5 Step 4 (PR body の Test plan) | ✅ |

### Placeholder scan

- [x] `TBD` / `TODO` / `FIXME` / `XXX` 等の placeholder なし
- [x] `<step1 で確認した version>` placeholder は chart latest stable 確認結果を埋める意図的記述 (= Task 2 Step 1 / Step 4 + Task 3 Step 1 / Step 4)
- [x] `<sha>` placeholder は git commit hash placeholder として意図的 (= Task 5 Step 1)
- [x] `<N>` placeholder は PR 番号として意図的 (= Task 5 Step 4 / Step 5)
- [x] `<上記 PR body>` は heredoc-style PR body insertion を意図 (= Task 5 Step 4)、code block 内に PR body 全文記述済

### Type / Property name consistency

- [x] `external-secrets` namespace (Task 2 namespace.yaml + production helmfile.yaml + values.yaml.gotmpl + cluster-secret-store.yaml の serviceAccountRef): 全て同一
- [x] `external-secrets` SA name (Task 1 main.tf `local.service_name` + Task 2 cluster-secret-store.yaml `serviceAccountRef.name`): 全て同一
- [x] `aws-secrets-manager` ClusterSecretStore name (Task 2 cluster-secret-store.yaml): 一意
- [x] `selfsigned-cluster-issuer` ClusterIssuer name (Task 2 values.yaml.gotmpl `webhook.certManager.cert.issuerRef.name`): 4-1 で deploy 済 ClusterIssuer と一致
- [x] `system-cluster-critical` priority class (Task 2 values.yaml.gotmpl `priorityClassName` + Task 3 values.yaml.gotmpl `reloader.deployment.priorityClassName`): 全 component に適用
- [x] `release: kube-prometheus-stack` ServiceMonitor label (Task 2 + Task 3 values.yaml.gotmpl): Sub-project 1-4-1 ServiceMonitor pattern と整合
- [x] `eks-production-eso` IAM role name (Task 1 main.tf `aws_iam_role.pod_identity.name = "eks-${var.environment}-eso"`): Pod Identity Association で参照される
- [x] `pods.eks.amazonaws.com` Service principal (Task 1 main.tf assume_role_policy): Pod Identity Association の正しい principal
- [x] commit subject prefix: `feat(eks):` (= 4 commits)、Sub-project 4a / 4b / 4-1 と整合
