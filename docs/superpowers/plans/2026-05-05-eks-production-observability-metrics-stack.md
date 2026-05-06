# EKS Production: Observability Metrics Stack (Phase 3 Sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 3 観測スタックの metrics 機能を完成させる。Sub-project 1 の AWS resource を Mimir 用に rename し、kube-prometheus-stack chart (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator) と grafana/mimir-distributed chart v6.0.6 (Microservices mode) を production env で deploy。Prometheus が Mimir に remote write して S3 long-term storage を実現、Grafana から Mimir 経由で長期 metrics query 可能に。

**Architecture:** AWS-side rename (aws/eks-metrics/ stack の bucket/IAM/Pod Identity SA を `prometheus`/`thanos-` から `mimir`/`mimir-` に追従) + K8s 側 2 chart 導入。Mimir Microservices mode (chart default) で 8 component を有効化、5 component (alertmanager / ruler / query-scheduler / overrides-exporter / smoke-test) を disable。Grafana data source は Mimir primary。

**Tech Stack:** terragrunt + OpenTofu / terraform-aws-modules/s3-bucket / aws_eks_pod_identity_association / Helm + helmfile / prometheus-community/kube-prometheus-stack v84.5.0 / grafana/mimir-distributed v6.0.6 (Mimir 3.0.4)

**Spec:** `docs/superpowers/specs/2026-05-05-eks-production-observability-metrics-stack-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**AWS-side (rename):**
```
aws/eks-metrics/modules/main.tf       # locals.bucket_name / service_name / comments を Mimir 用に rename
aws/eks-metrics/modules/outputs.tf    # description を Mimir 用に追従
```

**Kubernetes 新規 (prometheus-operator/production):**
```
kubernetes/components/prometheus-operator/production/
├── helmfile.yaml                     # kube-prometheus-stack chart v84.5.0
├── values.yaml.gotmpl                # production override (retention / resources / PVC / remote_write / data sources)
├── namespace.yaml                    # monitoring namespace 作成
└── kustomization/                    # (オプション) 追加リソース、本 sub-project では空 or 不要
```

**Kubernetes 新規 (mimir/production):**
```
kubernetes/components/mimir/production/
├── helmfile.yaml                     # grafana/mimir-distributed chart v6.0.6
├── values.yaml.gotmpl                # Microservices mode + S3 backend + Pod Identity + resources / PVC
└── (namespace.yaml は不要、prometheus-operator/production/namespace.yaml と共有)
```

**Kubernetes 既存変更:**
```
kubernetes/helmfile.yaml.gotmpl       # production env に mimir cross-stack values 追加
kubernetes/manifests/production/{prometheus-operator,mimir}/  # hydrate 結果 (auto-generated)
kubernetes/README.md                  # 新 component を Phase 3 セクションに追加
```

**Files の責務分離:**

| File | 責務 |
|---|---|
| `aws/eks-metrics/modules/main.tf` | S3 bucket + IAM + Pod Identity Association を Mimir 用に rename |
| `aws/eks-metrics/modules/outputs.tf` | terragrunt output description を Mimir 用に追従 (key 名は維持) |
| `kubernetes/components/prometheus-operator/production/helmfile.yaml` | kube-prometheus-stack chart の release 定義 |
| `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` | chart の production override values (retention / remote_write / data sources / PVC) |
| `kubernetes/components/prometheus-operator/production/namespace.yaml` | monitoring namespace (= Mimir / Loki / Tempo 等で共有) |
| `kubernetes/components/mimir/production/helmfile.yaml` | mimir-distributed chart の release 定義 |
| `kubernetes/components/mimir/production/values.yaml.gotmpl` | Microservices mode + S3 backend + Pod Identity + sizing |
| `kubernetes/helmfile.yaml.gotmpl` | production env の cross-stack values (mimir.bucketName etc.) |
| `kubernetes/README.md` | Phase 3 進捗 + 新 component 説明 |

---

## Task 0: 前提条件の確認 + branch sync

**Files:** (read-only confirmation)

- [ ] **Step 1: branch / worktree 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git fetch origin main
git status
git log --oneline origin/main..HEAD
```

Expected:
- `On branch feat/eks-production-observability-metrics-stack`
- spec の 2 commits (`a5798c1` + `9eb1ccf`) が ahead of origin/main
- working tree clean

- [ ] **Step 2: AWS account-id + cluster info 確認**

```bash
aws sts get-caller-identity --query 'Account' --output text
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl cluster-info | head -2
```

Expected:
- account-id: `559744160976`
- cluster: `eks-production` API server endpoint 表示

- [ ] **Step 3: Sub-project 1 で provision された resource baseline 確認**

```bash
aws s3 ls --region ap-northeast-1 | grep -E "mimir-|thanos-|loki-|tempo-"
aws iam list-roles --query 'Roles[?starts_with(RoleName, `eks-production-prometheus`) || starts_with(RoleName, `eks-production-mimir`)].RoleName' --output text
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 --query 'associations[?namespace==`monitoring`].{ns:namespace,sa:serviceAccount}' --output table
```

Expected:
- `thanos-559744160976` bucket 表示 (= Sub-project 1 で provision 済、本 sub-project で `mimir-559744160976` に rename される)
- `loki-559744160976`, `tempo-559744160976` bucket も表示 (= Sub-project 1 で provision 済、本 sub-project では touch しない)
- `eks-production-prometheus` IAM role 表示 (= 本 sub-project で `eks-production-mimir` に rename)
- Pod Identity Association: `monitoring:prometheus` 表示 (= 本 sub-project で `monitoring:mimir` に rename)

- [ ] **Step 4: monitoring namespace の現状確認**

```bash
kubectl get namespace monitoring 2>&1 || echo "expected: NotFound"
```

Expected: `Error from server (NotFound): namespaces "monitoring" not found` (本 sub-project の Task 2 / 3 で初めて作成)。

- [ ] **Step 5: helm repos の確認**

```bash
helm repo list | grep -E "prometheus-community|grafana"
```

Expected: 両 repo が registered 状態。もし無い場合は:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

- [ ] **Step 6: Mimir chart v6.0.6 の availability 確認**

```bash
helm search repo grafana/mimir-distributed --versions | head -5
```

Expected: `6.0.6` (App version `3.0.4`) が表示される。version が不可なら最新 stable に変更可。

---

## Task 1: aws/eks-metrics/ stack の rename (prometheus → mimir)

**Files:**
- Modify: `aws/eks-metrics/modules/main.tf`
- Modify: `aws/eks-metrics/modules/outputs.tf`

Sub-project 1 で provision した resource を Mimir 用に rename。`local.bucket_name` / `local.service_name` を Mimir 系に変更し、関連 comment を追従。

terragrunt apply で旧 resource (`thanos-559744160976` bucket / `eks-production-prometheus` IAM role / `monitoring:prometheus` Pod Identity Association) は **destroy + create** される (data 0 byte で安全)。

- [ ] **Step 1: aws/eks-metrics/modules/main.tf を以下で書き換え**

```hcl
# main.tf - EKS Metrics AWS-side infrastructure (S3 backend for Mimir).
#
# Provides:
# 1. S3 bucket `mimir-<account-id>` for long-term metrics storage
#    (Mimir ingester が write、Mimir compactor が S3 内で compaction、
#    Mimir store-gateway が read)。
#    - Lifecycle: 90 日 expiration on `${var.environment}/` prefix only
#    - Encryption: SSE-S3 (AES256)
#    - Public access block: 4 settings all true
#    - Versioning: Disabled (immutable write pattern, cost minimization)
# 2. IAM role bound by Pod Identity Association to K8s SA `monitoring:mimir`
#    - S3 access scoped to `${var.environment}/*` path only (minimum permission)
#    - DeleteObject 含む (Mimir compaction で必要)
# 3. Pod Identity Association binding `monitoring:mimir` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# env 分離は bucket 内 prefix `${var.environment}/` で行う。
# Sub-project 2 (kube-prometheus-stack + grafana/mimir-distributed chart 導入) は
# 本 stack の outputs を terragrunt output 経由で取得し、helmfile values に渡す。

data "aws_caller_identity" "current" {}

locals {
  bucket_name    = "mimir-${data.aws_caller_identity.current.account_id}"
  service_name   = "mimir" # K8s ServiceAccount name
  retention_days = 90      # Mimir long-term metrics retention
}

# S3 bucket for Mimir long-term metrics storage
module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.6.0"

  bucket = local.bucket_name

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

  lifecycle_rule = [
    {
      id     = "${var.environment}-retention"
      status = "Enabled"
      filter = {
        prefix = "${var.environment}/"
      }
      expiration = {
        days = local.retention_days
      }
    }
  ]

  tags = var.common_tags
}

# IAM role for Pod Identity Association
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

# IAM policy for S3 access (production env path scoped)
# 3 statement: BucketLevelListing (s3:prefix condition) / BucketLocation (no condition) / ObjectLevelOperations (env-scoped Resource)
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevelListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = "${var.environment}/*"
          }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        Sid    = "ObjectLevelOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
        ]
        Resource = "arn:aws:s3:::${local.bucket_name}/${var.environment}/*"
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

- [ ] **Step 2: aws/eks-metrics/modules/outputs.tf を以下で書き換え**

description のみ Mimir 用に追従 (output key 名は維持、Sub-project 2-4 で consume する interface 不変):

```hcl
# outputs.tf - Outputs for the eks-metrics module.

output "bucket_name" {
  description = "S3 bucket name for Mimir long-term metrics storage. Referenced by Sub-project 2 helmfile values (mimir chart common.storage.s3.bucket)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Mimir object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:mimir SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:mimir SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
```

- [ ] **Step 3: terragrunt validate で type/syntax check**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/aws/eks-metrics/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
TG_TF_PATH=tofu terragrunt validate
```

Expected:
- `init`: provider download + module fetch (terraform-aws-modules/s3-bucket v5.6.0 + aws/eks/lookup) で `success`
- `validate`: `Success! The configuration is valid.`

- [ ] **Step 4: terragrunt plan で diff 確認 (rename 動作)**

```bash
TG_TF_PATH=tofu terragrunt plan
```

Expected diff:
- `module.s3.aws_s3_bucket.this[0]` will be **destroyed** (旧 `thanos-559744160976`) + **created** (新 `mimir-559744160976`)
- `module.s3.aws_s3_bucket_lifecycle_configuration.this[0]` destroy + create (rule id が `${var.environment}-retention` で同じ、bucket 名 change により再 create)
- `module.s3.aws_s3_bucket_public_access_block.this[0]` destroy + create
- `module.s3.aws_s3_bucket_server_side_encryption_configuration.this[0]` destroy + create
- `module.s3.aws_s3_bucket_versioning.this[0]` destroy + create
- `aws_iam_role.pod_identity` will be **destroyed** (旧 `eks-production-prometheus`) + **created** (新 `eks-production-mimir`)
- `aws_iam_role_policy.s3_access` destroy + create
- `aws_eks_pod_identity_association.this` will be **destroyed** (旧 SA `prometheus`) + **created** (新 SA `mimir`)

Plan summary: `Plan: 8 to add, 0 to change, 8 to destroy.` (Sub-project 1 と同じ count、ただし全 resource が rename で destroy + create)。

⚠️ 旧 bucket `thanos-559744160976` の destroy は data 0 byte の前提。もし object が残っている場合は (= Sub-project 1 後に何か write されていた)、`aws s3 rm s3://thanos-559744160976/ --recursive` で空にしてから再 plan。

- [ ] **Step 5: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add aws/eks-metrics/
git commit -s -m "feat(aws/eks-metrics): rename to Mimir (prometheus → mimir, thanos- → mimir-)

Sub-project 2 brainstorming で Mimir 採用 design pivot に伴い、Sub-project 1 で provision した historical artifact を clean rename:

- bucket: thanos-559744160976 → mimir-559744160976
- IAM role: eks-production-prometheus → eks-production-mimir
- Pod Identity Association SA: monitoring:prometheus → monitoring:mimir
- main.tf header / inline comment を Mimir 用に追従
- outputs.tf description を Mimir 用に追従 (output key 名は維持)

terragrunt apply で旧 resource destroy + 新 resource create (data 0 byte で migration cost なし)。"
```

---

## Task 2: kubernetes/components/prometheus-operator/production/ 新規作成

**Files (all NEW):**
- Create: `kubernetes/components/prometheus-operator/production/helmfile.yaml`
- Create: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`
- Create: `kubernetes/components/prometheus-operator/production/namespace.yaml`

local の `kubernetes/components/prometheus-operator/local/` をベースに production env 派生で kube-prometheus-stack chart を deploy。Prometheus が cluster の metrics を scrape し、Mimir に remote write する形。

- [ ] **Step 1: ディレクトリ作成**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
mkdir -p kubernetes/components/prometheus-operator/production
```

- [ ] **Step 2: kubernetes/components/prometheus-operator/production/helmfile.yaml 作成**

```yaml
# =============================================================================
# Kube-Prometheus-Stack Helmfile for production
# =============================================================================
# This chart installs:
#   - Prometheus (scrape agent + remote write to Mimir)
#   - Alertmanager (alerting hub、receiver は Phase 4 で追加)
#   - Grafana (visualization、Mimir data source primary)
#   - node-exporter (host metrics)
#   - kube-state-metrics (K8s API metrics)
#   - prometheus-operator (CRD 管理)
# =============================================================================
environments:
  production:
---
repositories:
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts

releases:
  - name: kube-prometheus-stack
    namespace: monitoring
    chart: prometheus-community/kube-prometheus-stack
    version: "84.5.0"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 3: kubernetes/components/prometheus-operator/production/namespace.yaml 作成**

```yaml
# namespace.yaml - monitoring namespace for Phase 3 observability stack
# Used by:
# - kube-prometheus-stack (Sub-project 2)
# - grafana/mimir-distributed (Sub-project 2)
# - loki (Sub-project 3)
# - tempo / opentelemetry / beyla (Sub-project 4)
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
```

- [ ] **Step 4: kubernetes/components/prometheus-operator/production/values.yaml.gotmpl 作成**

```yaml
# Kube-Prometheus-Stack Configuration for production
# Production-grade configuration with Mimir remote write, env-scoped resources.

# =============================================================================
# Grafana Configuration
# =============================================================================
grafana:
  enabled: true
  testFramework:
    enabled: false

  # TODO: (Phase 4) External Secrets Operator + AWS Secrets Manager 経由で secret 化
  adminPassword: "panicboat-2026"

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

  persistence:
    enabled: true
    size: 5Gi
    storageClassName: gp3

  # -------------------------------------------------------------------------
  # Sidecar for Dashboard Discovery
  # -------------------------------------------------------------------------
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL

  # -------------------------------------------------------------------------
  # Data Sources (Mimir primary、Prometheus local secondary)
  # -------------------------------------------------------------------------
  # NOTE: Loki / Tempo data sources は Sub-project 3 / 4 で additionalDataSources に追加
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Mimir
          uid: mimir
          type: prometheus
          url: http://mimir-distributed-nginx.monitoring.svc.cluster.local/prometheus
          access: proxy
          isDefault: true
          jsonData:
            httpMethod: POST
            timeInterval: 30s
        - name: Prometheus (local)
          uid: prometheus-local
          type: prometheus
          url: http://prometheus-operated.monitoring.svc.cluster.local:9090
          access: proxy
          isDefault: false
          jsonData:
            httpMethod: POST
            timeInterval: 30s

# =============================================================================
# Prometheus Configuration
# =============================================================================
prometheus:
  prometheusSpec:
    # -------------------------------------------------------------------------
    # ServiceMonitor / PodMonitor Discovery
    # -------------------------------------------------------------------------
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorSelector: {}
    podMonitorNamespaceSelector: {}

    # -------------------------------------------------------------------------
    # Retention (短期、long-term は Mimir に remote write)
    # -------------------------------------------------------------------------
    retention: 24h

    # -------------------------------------------------------------------------
    # Remote Write to Mimir
    # -------------------------------------------------------------------------
    remoteWrite:
      - url: http://mimir-distributed-nginx.monitoring.svc.cluster.local/api/v1/push
        # Mimir の tenant header (= 本 sub-project は 1 tenant、`anonymous` で OK)
        headers:
          X-Scope-OrgID: anonymous
        writeRelabelConfigs:
          # NOTE: cardinality を抑える relabel は cluster scale up 時に追加
          - sourceLabels: [__name__]
            regex: ".*"
            action: keep

    # -------------------------------------------------------------------------
    # Resource Limits
    # -------------------------------------------------------------------------
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1
        memory: 2Gi

    # -------------------------------------------------------------------------
    # Storage
    # -------------------------------------------------------------------------
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources:
            requests:
              storage: 20Gi

# =============================================================================
# Alertmanager Configuration
# =============================================================================
# NOTE: receiver 設定 (Slack / SNS / PagerDuty) は Phase 4 で追加
alertmanager:
  enabled: true
  alertmanagerSpec:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources:
            requests:
              storage: 2Gi

# =============================================================================
# Prometheus Node Exporter
# =============================================================================
prometheus-node-exporter:
  hostRootFsMount:
    enabled: true
    mountPropagation: HostToContainer
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# =============================================================================
# Kube-State-Metrics
# =============================================================================
kube-state-metrics:
  metricLabelsAllowlist:
    - pods=[*]
    - deployments=[*]
    - statefulsets=[*]
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

# =============================================================================
# Prometheus Operator
# =============================================================================
# NOTE: production では admissionWebhooks を再有効化 (= local で disable していた
# のは chart v82.x の RBAC bug 回避のため、v84.x で fix されているため OK)
prometheusOperator:
  admissionWebhooks:
    enabled: true
    patch:
      enabled: true
  tls:
    enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

- [ ] **Step 5: helmfile -e production template で render 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/kubernetes/components/prometheus-operator/production
helmfile -e production template > /tmp/prometheus-operator-rendered.yaml 2>&1
echo "--- summary ---"
grep -E "^kind:" /tmp/prometheus-operator-rendered.yaml | sort | uniq -c
```

Expected: kube-prometheus-stack の主要 Kind が出力 (`Deployment`, `StatefulSet`, `DaemonSet`, `Service`, `ServiceAccount`, `ServiceMonitor`, `PrometheusRule`, `ConfigMap`, `Secret`, `ClusterRole`, `ClusterRoleBinding`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`, `Prometheus`, `Alertmanager`, `Grafana` (helm-managed))。

⚠️ もし render error の場合 (= helmfile / chart values syntax error)、`helmfile -e production lint` で詳細 error を見る。

- [ ] **Step 6: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add kubernetes/components/prometheus-operator/production/
git commit -s -m "feat(kubernetes/components/prometheus-operator): add production env

Sub-project 2 で kube-prometheus-stack chart v84.5.0 を production env で deploy。Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator を含み、Prometheus が Mimir に remote write して S3 long-term storage 経由 で Grafana から長期 metrics query 可能に。

production override の主要設定:
- prometheus retention: 24h (short-term、long-term は Mimir)
- prometheus remoteWrite: mimir-distributed-nginx.monitoring.svc.cluster.local/api/v1/push (X-Scope-OrgID=anonymous)
- prometheus resources: 200m/512Mi req, 1/2Gi lim、storage 20Gi gp3
- alertmanager: storage 2Gi gp3 (receiver は Phase 4)
- grafana adminPassword: hardcode (TODO: Phase 4 ESO)
- grafana data source: Mimir primary + Prometheus local secondary
- prometheusOperator admissionWebhooks: 再有効化 (= local で disable だった bug は v84.x で fix)"
```

---

## Task 3: kubernetes/components/mimir/production/ 新規作成 (Microservices mode)

**Files (all NEW):**
- Create: `kubernetes/components/mimir/production/helmfile.yaml`
- Create: `kubernetes/components/mimir/production/values.yaml.gotmpl`

`grafana/mimir-distributed` chart v6.0.6 を Microservices mode (chart default) で deploy。本 sub-project では 8 component を有効化、5 component を disable。Pod Identity Association `monitoring:mimir` で S3 access。

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p kubernetes/components/mimir/production
```

- [ ] **Step 2: chart の values 構造を helm show values で確認**

```bash
helm show values grafana/mimir-distributed --version 6.0.6 > /tmp/mimir-default-values.yaml 2>&1
wc -l /tmp/mimir-default-values.yaml
grep -nE "^(alertmanager|ruler|query_scheduler|overrides_exporter|smoke_test|continuous_test|nginx|distributor|ingester|querier|query_frontend|store_gateway|compactor|memcached|chunks_cache|results_cache|metadata_cache):" /tmp/mimir-default-values.yaml | head -30
```

Expected: 各 component の top-level key (alertmanager / ruler / etc.) が表示される。values.yaml の line 数は 1500-2000 程度。

⚠️ chart v6.0.6 の正確な values key 名 (= snake_case vs camelCase の混在) を確認、Step 3 の chart values 構築時に正しい key 名を使用。

- [ ] **Step 3: kubernetes/components/mimir/production/helmfile.yaml 作成**

```yaml
# =============================================================================
# Grafana Mimir Distributed Helmfile for production
# =============================================================================
# This chart installs Mimir in Microservices mode (chart default):
#   - nginx (gateway): Mimir API HTTP entry point
#   - distributor: receive remote write from Prometheus, distribute to ingester
#   - ingester: WAL + recent metrics + S3 batch flush
#   - querier: unified query (ingester + store-gateway)
#   - query-frontend: query optimization + cache
#   - store-gateway: S3 metrics provider
#   - compactor: S3 metric compaction
#   - memcached (chunks-cache): query cache
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の values を child に
    # auto-inherit しないため、ここで再定義 (cilium / karpenter 同パターン)。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と同期。
    values:
      - mimir:
          # Source: aws/eks-metrics/envs/production terragrunt output bucket_name
          bucketName: mimir-559744160976
          # Source: aws/eks-metrics/envs/production terragrunt output bucket_path_prefix
          bucketPathPrefix: production
---
repositories:
  - name: grafana
    url: https://grafana.github.io/helm-charts

releases:
  - name: mimir-distributed
    namespace: monitoring
    chart: grafana/mimir-distributed
    version: "6.0.6"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 4: kubernetes/components/mimir/production/values.yaml.gotmpl 作成**

```yaml
# Grafana Mimir Distributed Configuration for production
# Microservices mode (chart default) with Pod Identity for S3 access.

# =============================================================================
# ServiceAccount (Pod Identity, no IRSA annotation needed)
# =============================================================================
# Pod Identity Association (aws/eks-metrics/ stack で provision 済) が
# monitoring:mimir SA を IAM role に紐付けるため、Helm chart 側で
# eks.amazonaws.com/role-arn annotation を入れる必要なし。
serviceAccount:
  create: true
  name: mimir

# =============================================================================
# Mimir 構成 (mimir.config を chart で生成、S3 backend を override)
# =============================================================================
mimir:
  structuredConfig:
    common:
      storage:
        backend: s3
        s3:
          bucket_name: {{ .Values.mimir.bucketName }}
          endpoint: s3.ap-northeast-1.amazonaws.com
          region: ap-northeast-1
          # SSE-S3 (AES256) は bucket-level の default encryption で適用済 (Sub-project 1)
    blocks_storage:
      storage_prefix: "{{ .Values.mimir.bucketPathPrefix }}/"
      backend: s3
      s3:
        bucket_name: {{ .Values.mimir.bucketName }}
        endpoint: s3.ap-northeast-1.amazonaws.com
        region: ap-northeast-1
    # multi-tenant 不要 (panicboat 1 tenant)
    multitenancy_enabled: false

# =============================================================================
# Disable unused components (本 sub-project で不要な 5 component)
# =============================================================================
# kube-prometheus-stack 内蔵 Alertmanager を使うため、Mimir 内蔵を disable
alertmanager:
  enabled: false
# kube-prometheus-stack 内蔵 Prometheus rule で評価するため、Mimir 内蔵 ruler を disable
ruler:
  enabled: false
# small cluster で query-frontend 直接で十分、query-scheduler 不要
query_scheduler:
  enabled: false
# multi-tenant 不要 (1 tenant)
overrides_exporter:
  enabled: false
# production で動作確認 Job 不要
smoke_test:
  enabled: false

# =============================================================================
# Enabled components (本 sub-project で必要な 8 component) のリソース設定
# =============================================================================

nginx:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

distributor:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

ingester:
  replicas: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 2Gi
  persistentVolume:
    enabled: true
    storageClass: gp3
    size: 10Gi

querier:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

query_frontend:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

store_gateway:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 2Gi
  persistentVolume:
    enabled: true
    storageClass: gp3
    size: 20Gi

compactor:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 2Gi
  persistentVolume:
    enabled: true
    storageClass: gp3
    size: 10Gi

# memcached (chunks-cache) — querier の S3 query 高速化
chunks-cache:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 200m
      memory: 1Gi
```

⚠️ Mimir chart v6.0.6 の values key 名は **snake_case** (例: `query_scheduler`, `query_frontend`, `store_gateway`, `chunks-cache`) で、kebab-case との混在に注意。Step 2 の helm show values で正確な key 名を確認すること。もし不一致なら subagent が自動的に修正する。

- [ ] **Step 5: helmfile -e production template で render 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/kubernetes/components/mimir/production
helmfile -e production template > /tmp/mimir-rendered.yaml 2>&1
echo "--- summary ---"
grep -E "^kind:" /tmp/mimir-rendered.yaml | sort | uniq -c
echo "--- ServiceAccount name ---"
grep -A 2 "kind: ServiceAccount" /tmp/mimir-rendered.yaml | head -10
echo "--- 8 components の Deployment / StatefulSet ---"
grep -E "^  name: mimir-distributed" /tmp/mimir-rendered.yaml | head -20
```

Expected:
- 主要 Kind: `Deployment` / `StatefulSet` / `Service` / `ServiceAccount` / `ConfigMap` / `Secret`
- `ServiceAccount name: mimir`
- 8 component の Deployment / StatefulSet (nginx / distributor / ingester / querier / query-frontend / store-gateway / compactor / memcached) が表示される
- 5 component (alertmanager / ruler / query-scheduler / overrides-exporter / smoke-test) の Deployment / StatefulSet は **表示されない** (disable 済)

⚠️ render error 時は `helmfile -e production lint` で詳細確認。Mimir chart v6.0.6 の正確な values key 名を helm show values で再確認 + Step 4 の values.yaml.gotmpl を修正。

- [ ] **Step 6: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add kubernetes/components/mimir/production/
git commit -s -m "feat(kubernetes/components/mimir): add production env (Microservices mode)

Sub-project 2 で grafana/mimir-distributed chart v6.0.6 を production env で deploy。Microservices mode (chart default) で 8 component (nginx / distributor / ingester / querier / query-frontend / store-gateway / compactor / chunks-cache) を有効化、5 component (alertmanager / ruler / query-scheduler / overrides-exporter / smoke-test) を disable。

設定の主要点:
- ServiceAccount name: mimir (Sub-project 1 の Pod Identity Association で bind 済)
- S3 backend: bucket={{ .Values.mimir.bucketName }} (Sub-project 1 outputs)、prefix=production/
- multitenancy_enabled: false (panicboat 1 tenant)
- 各 component 1 replica で start (small-medium cluster 規模)
- PVC: ingester 10G / store-gateway 20G / compactor 10G (gp3)"
```

---

## Task 4: kubernetes/helmfile.yaml.gotmpl の production env values 更新

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl` (production env values)

cross-stack values (Sub-project 1 の terragrunt outputs から取得した値) を production env block に追加。

- [ ] **Step 1: kubernetes/helmfile.yaml.gotmpl の production env block を更新**

既存 production env block (karpenter, cluster.name 等) に **追加** する形で `mimir` key を以下のように追記:

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
          eksApiEndpoint: BD10E7689A05E46191305DDC7BE6CA67.gr7.ap-northeast-1.eks.amazonaws.com
          vpcId: vpc-02ea5d0ed3b7a3266
          albControllerRoleArn: arn:aws:iam::559744160976:role/eks-production-alb-controller-20260503163503969700000004
          externalDnsRoleArn: arn:aws:iam::559744160976:role/eks-production-external-dns-20260503163503968100000002
        karpenter:
          nodeRoleName: Karpenter-eks-production-20260504154319852600000007
          interruptionQueueName: Karpenter-eks-production
        # ★ NEW: Mimir cross-stack values (Source: aws/eks-metrics/envs/production terragrunt output)
        mimir:
          # bucket_name 出力を使用 (= mimir-559744160976 を rename 後)
          bucketName: mimir-559744160976
          # bucket_path_prefix 出力を使用 (= "production")
          bucketPathPrefix: production
          # pod_identity_role_name 出力を使用 (verification 用、helmfile 値としては unused、参考メモ)
          podIdentityRoleName: eks-production-mimir
```

- [ ] **Step 2: 値の妥当性確認 (terragrunt output と一致するか)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/aws/eks-metrics/envs/production
TG_TF_PATH=tofu terragrunt output -json 2>&1 | jq '.bucket_name.value, .bucket_path_prefix.value, .pod_identity_role_name.value'
```

Expected: `"mimir-559744160976"`, `"production"`, `"eks-production-mimir"`。これらが Step 1 の helmfile.yaml.gotmpl 内 `mimir.*` 値と一致すること。

⚠️ Sub-project 1 の rename がまだ apply されていない (= terragrunt output が旧名 `thanos-` / `eks-production-prometheus`) 場合は、本 Step は skip 可。Task 1 commit で rename を予定通りに実装している場合、PR merge 後の terragrunt apply で新名に変わる。

- [ ] **Step 3: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add kubernetes/helmfile.yaml.gotmpl
git commit -s -m "feat(kubernetes): add Mimir cross-stack values to production env

Sub-project 2 で導入する mimir-distributed chart が consume する cross-stack values (= aws/eks-metrics/ stack の terragrunt outputs から取得した値) を production env block に追加。

- mimir.bucketName: mimir-559744160976 (S3 backend、Sub-project 1 rename 後)
- mimir.bucketPathPrefix: production (env path)
- mimir.podIdentityRoleName: eks-production-mimir (verification 用、helmfile 値としては unused)

helmfile v1.4 は親→子 の auto-inherit しないため、kubernetes/components/mimir/production/helmfile.yaml の environments.production.values にも同値を再定義済 (cilium / karpenter 同パターン、Plan 1c-β L4 反映)。"
```

---

## Task 5: make hydrate ENV=production

**Files:**
- Create / Modify: `kubernetes/manifests/production/{prometheus-operator,mimir}/manifest.yaml` (auto-generated)

Flux 用 rendered manifest を生成 + commit。

- [ ] **Step 1: make hydrate ENV=production**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/kubernetes
make hydrate ENV=production 2>&1 | tail -20
```

Expected: hydrate target が `kubernetes/manifests/production/{prometheus-operator,mimir}/` 配下に rendered manifest を生成。

- [ ] **Step 2: hydrate 結果の確認**

```bash
ls kubernetes/manifests/production/prometheus-operator/ 2>&1
ls kubernetes/manifests/production/mimir/ 2>&1
echo "--- prometheus-operator manifest summary ---"
grep -E "^kind:" kubernetes/manifests/production/prometheus-operator/manifest.yaml 2>/dev/null | sort | uniq -c
echo "--- mimir manifest summary ---"
grep -E "^kind:" kubernetes/manifests/production/mimir/manifest.yaml 2>/dev/null | sort | uniq -c
```

Expected:
- prometheus-operator/manifest.yaml に kube-prometheus-stack 主要 Kind (Deployment / StatefulSet / DaemonSet / Service / ServiceAccount / ServiceMonitor / PrometheusRule / Prometheus / Alertmanager / ConfigMap / Secret / ClusterRole / ClusterRoleBinding / MutatingWebhookConfiguration / ValidatingWebhookConfiguration 等) が表示
- mimir/manifest.yaml に Mimir 8 component の Kind (Deployment / StatefulSet / Service / ServiceAccount / ConfigMap / Secret) が表示、disabled 5 component の Deployment / StatefulSet は表示されない

- [ ] **Step 3: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add kubernetes/manifests/production/prometheus-operator/ kubernetes/manifests/production/mimir/
git commit -s -m "chore(kubernetes/manifests): hydrate prometheus-operator + mimir for production

make hydrate ENV=production で kube-prometheus-stack + grafana/mimir-distributed chart の rendered manifest を生成。Flux が apply する manifest 形式。

- kubernetes/manifests/production/prometheus-operator/manifest.yaml: kube-prometheus-stack v84.5.0 の rendered (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator)
- kubernetes/manifests/production/mimir/manifest.yaml: grafana/mimir-distributed v6.0.6 (Microservices mode) の rendered (8 component 有効化、5 component disable)"
```

---

## Task 6: kubernetes/README.md 更新

**Files:**
- Modify: `kubernetes/README.md`

新 component (prometheus-operator/production / mimir/production) を Phase 3 セクションに追加し、進捗を反映。

- [ ] **Step 1: README の Phase 3 関連セクションを read で確認**

```bash
grep -n "Phase 3\|Observability\|monitoring" /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack/kubernetes/README.md | head -20
```

(README の構造 + 既存 Phase 3 言及箇所を確認、subagent が context 把握する)

- [ ] **Step 2: README の "Cluster Components" or "Observability" セクションに追記**

`kubernetes/README.md` の Phase 3 / Observability section に以下を追加 (= 既存 component table 等の下に新 row として、または Phase 3 progress section の `- [x]` 形式で):

```markdown
### Phase 3 Sub-project 2: Metrics stack (kube-prometheus-stack + Mimir)

- `kubernetes/components/prometheus-operator/production/` (chart: prometheus-community/kube-prometheus-stack v84.5.0)
  - Prometheus が cluster の metrics を scrape し、Mimir に remote write
  - Alertmanager (receiver は Phase 4 で追加)
  - Grafana (data source は Mimir primary、Loki / Tempo は Sub-project 3 / 4 で追加)
  - node-exporter / kube-state-metrics / prometheus-operator
- `kubernetes/components/mimir/production/` (chart: grafana/mimir-distributed v6.0.6、Microservices mode)
  - Mimir 8 component (nginx / distributor / ingester / querier / query-frontend / store-gateway / compactor / chunks-cache) を有効化
  - S3 backend: `mimir-559744160976/production/` (Sub-project 1 で provision、本 sub-project で rename)
  - Pod Identity: `monitoring:mimir` SA → `eks-production-mimir` IAM role
  - long-term metrics retention 90 日 (S3 lifecycle policy)
- Sub-project 3 (Loki + Fluent Bit) / Sub-project 4 (Tempo + OpenTelemetry + Beyla + Hubble OTLP) は別 spec で扱う
```

⚠️ README の既存構造に応じて、上記 section を適切な位置に挿入する (例: 既存の "Phase 1 Foundation" / "Phase 2 Karpenter" 等の下に追加)。subagent は README 全体構造を read で確認した上で、適切な insertion point を判断。

- [ ] **Step 3: Commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git add kubernetes/README.md
git commit -s -m "docs(kubernetes): add Phase 3 Sub-project 2 (Metrics stack) to README

Sub-project 2 で導入した kube-prometheus-stack + grafana/mimir-distributed chart の operational documentation を README に追加。

- prometheus-operator/production: kube-prometheus-stack v84.5.0 (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics)
- mimir/production: grafana/mimir-distributed v6.0.6 (Microservices mode、8 component)
- S3 backend / Pod Identity / retention 90 日 等の運用情報

Sub-project 3 / 4 は別 spec で扱う旨を明示。"
```

---

## Task 7: PR push + Draft PR 作成

**Files:** (no file changes、git remote operation)

- [ ] **Step 1: branch 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-metrics-stack
git status
git log --oneline origin/main..HEAD
```

Expected:
- working tree clean
- 8 commits ahead of origin/main:
  - `9eb1ccf` spec (Sub-project 2)
  - `a5798c1` spec update (Microservices mode)
  - Task 1 commit (aws/eks-metrics/ rename)
  - Task 2 commit (prometheus-operator/production)
  - Task 3 commit (mimir/production)
  - Task 4 commit (helmfile.yaml.gotmpl)
  - Task 5 commit (hydrate)
  - Task 6 commit (README)

(Task 1-6 で 6 commits 追加 + spec 2 commits = 計 8 commits)

- [ ] **Step 2: branch を push**

```bash
git push -u origin HEAD
```

Expected: `feat/eks-production-observability-metrics-stack` branch が origin に作成される。

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --title "feat(eks): Phase 3 Sub-project 2 — Observability Metrics stack (kube-prometheus-stack + Mimir Microservices)" --body "$(cat <<'EOF'
## Summary

Roadmap Phase 3 (Observability) を 4 sub-projects に分解した 2 番目の sub-project。観測スタックの metrics 機能を完成させる。

### Stack 構成

| Component | Chart | Version | 役割 |
|---|---|---|---|
| **kube-prometheus-stack** | prometheus-community/kube-prometheus-stack | 84.5.0 | Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator |
| **grafana/mimir-distributed** | grafana/mimir-distributed | 6.0.6 (Mimir 3.0.4) | Microservices mode で 8 component (nginx + distributor + ingester + querier + query-frontend + store-gateway + compactor + chunks-cache)、5 component (alertmanager / ruler / query-scheduler / overrides-exporter / smoke-test) を disable |

### Design pivot (brainstorming で確定)

- 当初 Roadmap spec の "Thanos sidecar + S3" を **Grafana Mimir** に切り替え (= Bitnami の有償化方針懸念、Mimir は Thanos の概念的後継、future-proof)
- Sub-project 1 で provision した resource (`thanos-` bucket / `eks-production-prometheus` IAM role / `monitoring:prometheus` SA) を Mimir 用に **rename** (data 0 byte で migration cost なし)
- Mimir deployment mode を chart default の Microservices mode に (= chart v6.0.6 で Read-Write mode は native support なし)

### 設計のキーポイント

- **AWS-side rename**: aws/eks-metrics/ stack で bucket / IAM role / Pod Identity Association SA を Mimir 用に rename
- **Mimir Microservices mode**: chart default、必要 8 component 有効化、不要 5 component disable
- **multitenancy_enabled: false**: panicboat 1 tenant のみ
- **Pod Identity Association**: `monitoring:mimir` SA → `eks-production-mimir` IAM role で S3 access
- **Prometheus → Mimir flow**: Prometheus retention 24h (short-term)、Mimir に remote write で long-term storage (S3 90 日 retention)
- **Grafana data source**: Mimir primary (default) + Prometheus local secondary (KEDA / latency-sensitive query 用)

## Code 変更 (本 PR)

- `aws/eks-metrics/modules/{main.tf,outputs.tf}`: rename (Mimir 用)
- `kubernetes/components/prometheus-operator/production/`: 新規 (helmfile.yaml + values.yaml.gotmpl + namespace.yaml)
- `kubernetes/components/mimir/production/`: 新規 (helmfile.yaml + values.yaml.gotmpl)
- `kubernetes/helmfile.yaml.gotmpl`: production env に mimir cross-stack values 追加
- `kubernetes/manifests/production/{prometheus-operator,mimir}/`: hydrate 結果
- `kubernetes/README.md`: Sub-project 2 セクション追加
- `docs/superpowers/specs/2026-05-05-eks-production-observability-metrics-stack-design.md`: 新規 (394 lines + Microservices update)
- `docs/superpowers/plans/2026-05-05-eks-production-observability-metrics-stack.md`: 新規

## Documents

- Spec: `docs/superpowers/specs/2026-05-05-eks-production-observability-metrics-stack-design.md`
- Plan: `docs/superpowers/plans/2026-05-05-eks-production-observability-metrics-stack.md`
- Roadmap reference: `docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md` Phase 3
- Sub-project 1 dependency: `docs/superpowers/specs/2026-05-05-eks-production-observability-aws-infra-design.md`

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] aws/eks-metrics: `terragrunt validate` 成功 / `terragrunt plan` で `8 to add, 0 to change, 8 to destroy` (= rename)
- [x] prometheus-operator/production: `helmfile -e production template` でエラーなし、kube-prometheus-stack 主要 Kind が render
- [x] mimir/production: `helmfile -e production template` でエラーなし、Mimir 8 component が render、disabled 5 component が render されない
- [x] make hydrate ENV=production で manifest 生成 (prometheus-operator + mimir)

### Cluster-level (CI / operator 実行、merge 後)

- [ ] terragrunt apply で aws/eks-metrics/ rename 完了 (`mimir-559744160976` bucket / `eks-production-mimir` IAM role / `monitoring:mimir` Pod Identity Association)
- [ ] Flux reconcile で `monitoring` namespace + kube-prometheus-stack chart + mimir-distributed chart が apply
- [ ] `kubectl get pods -n monitoring` で全 Pod (15+ component) が `Running 1/1`
- [ ] `kubectl get pvc -n monitoring` で 7 PVC (Prometheus 20G / Alertmanager 2G / Grafana 5G / Mimir ingester 10G / store-gateway 20G / compactor 10G / chunks-cache 5G) が `Bound`
- [ ] Prometheus → Mimir remote write 動作: `kubectl logs -n monitoring prometheus-... -c prometheus | grep -i 'remote_write'` で送信 log
- [ ] Mimir → S3 flush 動作: `aws s3 ls s3://mimir-559744160976/production/ --recursive | head -20` で metrics block 表示 (~5-10 分後)
- [ ] Grafana 動作: `kubectl port-forward` で UI access、Mimir data source で `up` query が結果を返す
EOF
)"
```

Expected: PR が created、URL が表示される。

- [ ] **Step 4: CI ステータス確認**

```bash
gh run list --branch feat/eks-production-observability-metrics-stack --limit 5
```

Expected: `Lint GitHub Actions` workflow + `Auto Label - Label Resolver` workflow が success で完了。

---

## (USER) PR review + merge → Verification

**Files:** (cluster 状態変更 — AWS-side rename + K8s 側 chart install)

PR を merge して CI Deploy が実行 (terragrunt apply + Flux reconcile)。

- [ ] **Step 1: PR を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: `Hydrate Kubernetes (production)` workflow + `aws/eks-metrics` terragrunt apply workflow が success。AWS-side rename 完了 → Flux reconcile で chart install。

- [ ] **Step 2: AWS-side rename 完了確認**

```bash
aws s3 ls --region ap-northeast-1 | grep -E "mimir-|thanos-"
aws iam list-roles --query 'Roles[?starts_with(RoleName, `eks-production-mimir`) || starts_with(RoleName, `eks-production-prometheus`)].RoleName' --output text
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 --query 'associations[?serviceAccount==`mimir` || serviceAccount==`prometheus`]' --output table
```

Expected:
- `mimir-559744160976` 表示、`thanos-559744160976` **消滅**
- `eks-production-mimir` 表示、`eks-production-prometheus` **消滅**
- Pod Identity Association: `monitoring:mimir` 表示、`monitoring:prometheus` **消滅**

- [ ] **Step 3: monitoring namespace + Pod 起動確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
kubectl get namespace monitoring
kubectl get pods -n monitoring -o wide
```

Expected:
- `monitoring` namespace `Active`
- 15+ Pod が `Running 1/1`:
  - kube-prometheus-stack: `prometheus-...` (StatefulSet) / `alertmanager-...` (StatefulSet) / `kube-prometheus-stack-grafana-...` (Deployment) / `kube-prometheus-stack-kube-state-metrics-...` (Deployment) / `kube-prometheus-stack-operator-...` (Deployment) / `kube-prometheus-stack-prometheus-node-exporter-...` (DaemonSet × node 数)
  - mimir: `mimir-distributed-nginx-...` (Deployment) / `mimir-distributed-distributor-...` (Deployment) / `mimir-distributed-ingester-zone-a-...` (StatefulSet) / `mimir-distributed-querier-...` (Deployment) / `mimir-distributed-query-frontend-...` (Deployment) / `mimir-distributed-store-gateway-zone-a-...` (StatefulSet) / `mimir-distributed-compactor-...` (StatefulSet) / `mimir-distributed-chunks-cache-...` (StatefulSet)

- [ ] **Step 4: PVC bound 確認**

```bash
kubectl get pvc -n monitoring
```

Expected: 7 PVC (Prometheus 20Gi / Alertmanager 2Gi / Grafana 5Gi / Mimir ingester 10Gi / store-gateway 20Gi / compactor 10Gi / chunks-cache 5Gi) が `Bound`。

- [ ] **Step 5: Prometheus → Mimir remote write 動作確認**

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=50 -c prometheus | grep -iE "remote_write|remote-write" | head -10
```

Expected: remote write log で Mimir distributor URL (= `mimir-distributed-nginx.monitoring.svc.cluster.local`) への送信 log が表示。"successful" / "200" 等の success indicator。

- [ ] **Step 6: Mimir → S3 flush 動作確認 (5-10 分後)**

```bash
aws s3 ls s3://mimir-559744160976/production/ --recursive --region ap-northeast-1 | head -20
```

Expected: ingester から flush された metric block の S3 object (TSDB block files) が表示。**~5-10 分待つ必要あり** (= Mimir ingester の batch interval は default 2 時間だが、最初の flush は startup 後数分で発生する)。

- [ ] **Step 7: Grafana data source + query 動作確認**

```bash
# Grafana UI に port-forward でアクセス
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
sleep 2
# adminPassword で sign-in (= panicboat-2026、values.yaml.gotmpl の hardcode、Phase 4 で secret 化予定)
echo "Access: http://localhost:3000/login (admin / panicboat-2026)"
```

Expected (UI 操作):
1. Grafana UI に admin / panicboat-2026 で sign-in
2. Configuration → Data sources で `Mimir` (default) と `Prometheus (local)` の 2 source が `Working` 状態
3. Explore で `Mimir` data source を選び、query `up` を実行 → cluster 内全 target の up status が table 表示
4. Default dashboard "Kubernetes / Compute Resources / Cluster" 等で metrics 表示

⚠️ もし Mimir data source が "no data" / "connection failed" の場合:
- Mimir nginx Service が起動しているか: `kubectl get svc -n monitoring mimir-distributed-nginx`
- Mimir nginx Pod の log: `kubectl logs -n monitoring -l app.kubernetes.io/component=nginx --tail=20`
- Mimir distributor が remote write を受信しているか: `kubectl logs -n monitoring -l app.kubernetes.io/component=distributor --tail=20`

- [ ] **Step 8: cleanup**

```bash
kill %1 2>/dev/null
```

(Step 7 で起動した port-forward を停止)

---

## Self-review checklist

> Plan 完成後の self-review。Implementer が任意 task を実行する前に、Plan 自体の整合性を確認する。

### Spec coverage

- [x] **Goals G1 (kube-prometheus-stack production deploy)** → Task 2
- [x] **Goals G2 (Mimir Microservices mode deploy)** → Task 3
- [x] **Goals G3 (Grafana data source = Mimir primary)** → Task 2 Step 4 values.yaml.gotmpl の `grafana.datasources`
- [x] **Goals G4 (Sub-project 1 resource を Mimir 用に rename)** → Task 1
- [x] **Decision 1 (chart 構成 = kube-prometheus-stack + grafana/mimir-distributed)** → Tasks 2, 3 で 2 chart deploy
- [x] **Decision 2 (Mimir Microservices mode)** → Task 3 Step 4 で 8 component 有効 + 5 component disable
- [x] **Decision 3 (Mimir Pod Identity = chart-level 1 SA `mimir`)** → Task 3 Step 4 の `serviceAccount.name: mimir`
- [x] **Decision 4 (AWS-side rename)** → Task 1
- [x] **Decision 5 (Metrics flow = Prometheus scrape → remote write → Mimir → S3 → Grafana)** → Task 2 (remote write) + Task 3 (Mimir backend)
- [x] **Decision 6 (Alertmanager kube-prometheus-stack 内蔵)** → Task 2 Step 4 `alertmanager.enabled: true`
- [x] **Decision 7 (Grafana adminPassword 暫定 hardcode + TODO)** → Task 2 Step 4 `grafana.adminPassword: "panicboat-2026"` + TODO comment
- [x] **Decision 8 (Pod placement Karpenter system-components)** → 各 chart の nodeSelector / tolerations を **設定しない** (= Karpenter 自動 provision)
- [x] **Decision 9 (PVC sizing 各 component 個別)** → Task 2 + Task 3 の chart values で sizing 設定
- [x] **Decision 10 (Resource production-grade)** → Task 2 + Task 3 の chart values で resources 設定
- [x] **Decision 11 (Grafana data source Mimir primary + Prometheus local secondary)** → Task 2 Step 4 `grafana.datasources` の 2 entries
- [x] **Decision 12 (namespace = monitoring)** → Task 2 Step 3 namespace.yaml
- [x] **Components matrix の全 9 ファイル** → Tasks 1-6 で network
- [x] **Cross-stack value flow** → Task 4 で helmfile.yaml.gotmpl に mimir cross-stack values 追加
- [x] **Migration sequence (terragrunt apply rename → Flux reconcile chart install)** → (USER) Steps 2-7
- [x] **Verification checklist** → (USER) Steps 2-7
- [x] **Trade-offs (rename destroy+create / hardcode adminPassword / 単 AZ HA / PVC AZ pinning)** → Plan の前提として認識、PR description に明記

### Placeholder scan

- [x] `TBD` / `implement later` / `fill in details` 等の禁止文言なし
- [x] `# TODO: (Phase 4)` は valid な future-marker (= 禁止文言ではない、Phase 4 で扱う旨を明示)
- [x] `<account-id>` placeholder は `data.aws_caller_identity.current.account_id` で動的取得、PR description で実値 `559744160976`
- [x] `<n>` (PR number) は `gh pr create` の output で確定

### Type / signature consistency

- [x] **HCL local 名** (`local.bucket_name` / `local.service_name` / `local.retention_days`) は Sub-project 1 + 本 plan で同 key、値が `mimir` 系に rename
- [x] **HCL resource 名** (`module.s3` / `aws_iam_role.pod_identity` / `aws_iam_role_policy.s3_access` / `aws_eks_pod_identity_association.this`) は Sub-project 1 + 本 plan で一貫 (rename 対象は `local.*` 値のみ)
- [x] **terragrunt output 名** (`bucket_name` / `bucket_path_prefix` / `pod_identity_role_name` / `pod_identity_role_arn`) は Sub-project 1 + 本 plan で同 key (= description のみ Mimir 用に追従)
- [x] **K8s namespace** (`monitoring`) は Tasks 2 / 3 + (USER) Steps で一貫
- [x] **K8s ServiceAccount 名** (`mimir`) は Task 1 (Pod Identity Association SA) + Task 3 (chart values `serviceAccount.name`) で一致
- [x] **chart version** (kube-prometheus-stack `84.5.0` / mimir-distributed `6.0.6`) は Tasks 2 / 3 で pin
- [x] **bucket 名** (`mimir-559744160976`) は Task 1 (rename) + Task 4 (cross-stack values) + Task 3 (chart values via Values reference) で一致

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) — Tasks 1-7 の commit step で指定
- [x] `Co-Authored-By` 不付与 — 全 task の commit message に無し
- [x] PR は `--draft` — Task 7 Step 3 の `gh pr create --draft`
- [x] 新規ブランチ初回 push: `git push -u origin HEAD` — Task 7 Step 2
- [x] Conventional Commits — 全 commit が `feat(scope):` / `docs(scope):` / `chore(scope):` 形式

### Plan 1c-β / Plan 2 / Plan tuning / Sub-project 1 の知見反映

- [x] **Plan 1c-β L1 (IRSA random suffix)** → 本 plan は Pod Identity 採用で IRSA 不使用、IAM role は fixed name
- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT 不要)** → Task 4 で helmfile.yaml.gotmpl に直接実値 (`mimir-559744160976`) を書く、placeholder pattern 不採用
- [x] **Plan 1c-β L5 (squash merge 後 branch reset rollback)** → Task 0 Step 1 で `git fetch origin main && git log --oneline origin/main..HEAD` 確認
- [x] **Plan 2 L7 (spec/plan divergence)** → 本 plan の brainstorming 中に判明した chart v6.x の Microservices mode 実態に対し、spec を update する commit (`a5798c1`) で divergence 解消
- [x] **Plan tuning L1 (IAM name_prefix 38 chars limit)** → 本 plan は `aws_iam_role.name = "eks-${env}-mimir"` で fixed name、上限内
- [x] **Plan tuning L2 (line-based scope ではなく file-based scope)** → 各 task で「ファイル単位」で完結 (Step ごとに完全 file write)
- [x] **Sub-project 1 L1 (IAM policy 3 statement 構造)** → Task 1 Step 1 の main.tf で 3 statement 構造を踏襲
- [x] **Sub-project 1 L2 (Plan の sibling tasks 間 comment style 一致)** → 本 plan は sibling tasks 無し (= 各 task が unique)、L2 該当外
- [x] **Sub-project 1 L3 (resource count expected の精度)** → 本 plan の Task 1 Step 4 で expected を `8 to add, 0 to change, 8 to destroy` と書いた (Sub-project 1 と同 count、ただし全 resource が rename で destroy + create)
- [x] **Sub-project 1 L4 (two-stage review が plan-level oversight catch)** → 本 plan の implementation でも subagent-driven-development で 2-stage review を継続
- [x] **Sub-project 1 L5 (sibling stacks symmetric)** → 本 plan は sibling stack 無し、aws/eks-metrics/ stack 単独 + chart 2 つ独自構成

---

## Lessons Learned (post-execution)

PR #287 (本 sub-project の初回 merge) で deploy した直後に 5 件の runtime issue が判明し、PR #289 で fix を完了 + Flux 同期再開して production cluster で metrics stack が正常稼働するに至った。実 deploy で初めて表面化した issues は brainstorming / plan 草案では予防困難な性質 (chart 内部の auto-generated resource、upstream の breaking change、low-level validator 等) を持つため、次 sub-project (Phase 3 Sub-project 3 Logs / 4 Traces) 設計時の参考と、運用 pattern の標準化のために記録する。

### L1: Helm chart の major version upgrade で upstream の API/config schema breaking change を確認すべき

`grafana/mimir-distributed` chart v6.0.6 (= Mimir 3.0.4) を採用したが、Mimir 3.x で **`frontend_worker.frontend_address` field が `worker.Config` struct から削除されている** ことを spec 草案時に把握していなかった。本 plan の Task 3 で `query_scheduler` を disable して `frontend_worker.frontend_address` で query-frontend に直接接続する override を書いたが、Mimir 3.x が config schema reject (`field frontend_address not found in type worker.Config`) して distributor / querier / query-frontend が CrashLoopBackOff となった。

**影響:** Mimir Microservices mode の主要 component が起動不能 → metrics stack 全体が機能不全。chart README には触れられているが migration guide まで読まないと気づかない type の breaking change。

**対処:**

- Helm chart の major (e.g., v5 → v6) / minor (Mimir 2.x → 3.x のような upstream major) version 採用時は、**chart README の "Migration" / "Breaking changes" セクション + upstream upstream changelog の `BREAKING:` prefix entry** を必須確認とする
- 関連: 本件で `query_scheduler` を chart default の `enabled: true` に戻したことで自動的に正しい `scheduler_address` 経由の接続になり解消 (= 余計な override をしないことが best practice)
- spec 草案時の checklist に「chart values で override する各 field について、upstream の現行 schema で valid かを確認したか」を追加

### L2: kube-prometheus-stack chart の grafana sidecar が auto-generated ConfigMap を持ち values override と並列に inject される

`kube-prometheus-stack-grafana-datasource` ConfigMap (= chart が default で生成、`Prometheus` を `isDefault: true` で投入) と、本 plan で書いた `grafana.datasources.datasources.yaml` の `Mimir` (`isDefault: true`) が **同一 organization 内に default datasource 2 件** を作る形で衝突し、Grafana の datasource provisioning が `Datasource provisioning error: Only one datasource per organization can be marked as default` で失敗。

**影響:** Grafana Pod の sidecar (= `kube-api-access` / `sc-dashboard` / `sc-datasources` の 3 sidecar 構成のうち datasource sidecar) が CrashLoop し、Pod 全体が `2/3 CrashLoopBackOff` 状態に。

**対処:** PR #289 で `grafana.sidecar.datasources.defaultDatasourceEnabled: false` を追加して chart の自動 ConfigMap を抑止。

- chart が auto-generated resource (ConfigMap / Secret / Service / etc.) を持つ場合、values で同種 resource を override する **前に** chart の auto-generation を disable する必要がある
- spec 草案時の checklist に「chart の sidecar / hook / template が parent chart の override 対象 resource と並列に何かを生成しないか」を追加 (= chart `values.yaml` を `helm show values` で取得して `defaultXxxEnabled` / `enableYyy` 系 toggle を pre-survey する)

### L3: EBS ReadWriteOnce PVC + Deployment.RollingUpdate = Multi-Attach error で永遠に Init から進まない

Grafana Deployment の `strategy.type: RollingUpdate` (= chart default) で deploy したが、PVC が `ReadWriteOnce` (= EBS volume) のため、新 ReplicaSet の Pod が PVC を取れず `FailedAttachVolume: Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) <old pod>` で永遠に Init で stuck。古い Pod が ready のうちは RollingUpdate が古い Pod を terminate しないため、新 Pod が PVC を待ち続け、結果 Deployment update が完了しない loop に。

**影響:** Grafana の rollout (datasource ConfigMap fix の反映等) が deadlock。kubectl で古い Pod を手動 delete することで一時しのぎは可能だが、values 修正のたびに同じ問題が再発する。

**対処:** PR #289 で `grafana.deploymentStrategy.type: Recreate` を追加。

- **RWO PVC を持つ Deployment は `strategy.type: Recreate` を必須化** する (= ダウンタイム数十秒許容)。Grafana / Loki / Tempo / Prometheus 等の monitoring tools は単一 replica + RWO PVC が一般的なので、Sub-project 3 / 4 の Loki / Tempo / Beyla / OpenTelemetry Collector deploy 時にも最初から `Recreate` で書く
- spec 草案時の checklist に「Deployment + PVC の組み合わせの場合、access mode が RWO か RWX かを確認、RWO なら strategy = Recreate を明示」を追加
- 関連: StatefulSet は Pod-level の OrderedReady 制御で同様の問題が起きにくい (= PVC は Pod template で 1:1 binding) ため Mimir の ingester / compactor / store-gateway では発生しなかった

### L4: Spec verification step は pre-flight (merge 前) と post-flight (merge 後) に明確分割すべき、destructive ops は merge 前必須

本 sub-project の spec で書いた "8-step verification plan" のうち **Step 1 `terragrunt apply` (= aws/eks-metrics で `thanos-559744160976` → `mimir-559744160976` rename = 8 destroy + 8 create) が merge 後にスキップされた**。ユーザーは PR #287 を merge → Flux が反映 → Mimir Pod が S3 access error で起動失敗 → assistant に状況を報告、という順序になり、**bucket rename という destructive ops が GitOps loop の外で別管理されている前提が暗黙だった** ことが表面化。

**影響:** merge 後に Pod 群が起動しない状態が約 1 時間続いた (バケットが空だったためデータロスは無かったが、本番 cluster の運用劣化)。spec D4 (= rename) は brainstorming で議論された明示的決定だったにもかかわらず、verification step が「merge 後にユーザーが手動で実行する想定」だったため抜け落ちた。

**対処:**

- spec / plan の verification を **以下 2 種に明確分離**:
  - **Pre-flight (merge 前 = PR draft 中に完了すべき)**: terragrunt apply / DB migration / IAM changes / Secrets rotation 等の **destructive / irreversible ops**
  - **Post-flight (merge 後の GitOps 反映後 verify)**: Pod 起動確認 / API 疎通 / data flow 確認等の **read-only / observable verifications**
- spec template の Test Plan section に Pre-flight / Post-flight の sub-section を分ける convention を導入
- destructive ops が pre-flight に含まれる PR は、PR description に **「Pre-flight check 全件 ✅ を確認してから Ready for review」** を明記 (= reviewer が pre-flight 状態を確認可能に)
- 関連: writing-plans skill の Test Plan section template を update する learnings (skill 改善 PR にて別途反映)

### L5: production runtime fix の標準フロー: `flux suspend → 手 apply → 検証 → PR merge → flux resume`

PR #287 merge 後の runtime issue を解消するにあたり、`flux suspend kustomization X` で同期を停止 → cluster に手 `kubectl apply` で fix を当てて検証 → 検証 OK 確認後に PR #289 を作成・merge → `flux reconcile source git X` → `flux resume kustomization X` → `flux reconcile kustomization X --with-source` で安全に同期再開する pattern を採用し、production cluster で機能した。

**機能した仕組み:**

- `prune: true` の Kustomization でも、suspend 中は drift detection が止まるため手 apply で追加した resource (gp3 StorageClass / patched Mimir manifest 等) が削除されない
- merge 後の resume は **idempotent re-apply** であり、cluster state と repo の最新 commit が等価な場合は no-op (= 再度 Pod restart が起きない)
- helm chart 由来の rendered manifest が Flux により再 apply される際は、helm template の deterministic 性で同じ output が出る → server-side apply の field manager 衝突なく nochange

**対処:** 本 pattern を **production runtime fix の standard runbook** として記録。次 sub-project (Sub-project 3 / 4) で同種の post-merge issue が起きた場合に再利用する。

- step 順序の重要性: **PR merge を resume の前に完了** させること (= resume 時に Flux が古い commit を pull して prune する事故を防ぐ)
- `flux reconcile source git` を resume の前に実行することで、最新 commit を source-controller に取り込ませてから kustomize-controller に reconcile させる安全順序

### L6: `gp3` StorageClass は EKS default に含まれず、foundational resource として明示 provision が必要

EKS の default StorageClass は `gp2` (= in-tree provisioner `kubernetes.io/aws-ebs`) のみで、`gp3` を使うには **EBS CSI driver (= addon、本 cluster では稼働中) を活用する独自 StorageClass を別途 apply する必要がある**。本 sub-project の spec で Mimir / Prometheus / Grafana / Alertmanager の PVC を `storageClassName: gp3` で指定したが、StorageClass 自体の provision step が plan に無く、PVC 全 6 件が `Pending` (`storageclass.storage.k8s.io "gp3" not found`) となり、Prometheus / Alertmanager の StatefulSet 自体が prometheus-operator により作成されない (= operator が validation で reject) 状態に。

**影響:** Pending PVC が 6 件 + StatefulSet 自体の不在で metrics stack の半分が deploy 不能。

**対処:** PR #289 で `kubernetes/manifests/production/storage-class/{kustomization.yaml, storage-classes.yaml}` を新設し `00-namespaces` と同じ foundational pattern (= helm chart 不要の raw manifest を直置き) で provision。

- foundational k8s resource (StorageClass / IngressClass / PriorityClass / Namespace 等) は cluster bootstrap 時に provision する必要があるため、**spec 草案時の "Pre-requisites" section で前提資源を明示** する
- 特に `storageClassName: <name>` を values に書く場合、その `<name>` が cluster に存在することを確認する pre-flight check を verification plan に含める (`kubectl get storageclass <name>`)
- 将来的に Sub-project 3 (Loki) / Sub-project 4 (Tempo) でも `gp3` 前提だが、本 PR で provision 済のため両 sub-project では再 provision 不要 (= storage-class component が共有される)

### L7: K8s controller は unhealthy Pod を常に強制再生成しない (kubectl delete pod / Pod-level rollout が必要なシナリオがある)

本 sub-project の verification 中に 2 種類の "Pod state を強制更新する必要があるシナリオ" を観測:

- **StatefulSet の OrderedReady rollout**: `kubectl rollout restart statefulset` は新 Pod template (= ReplicaSet hash) を生成するが、既存 Pod-0 が unhealthy (CrashLoop) で stuck している場合、StatefulSet controller は **既存 Pod-0 が ready になる** を待って次の操作を行うため、新 Pod-0 への置き換えが起きない。本件では Mimir の compactor / store-gateway が約 1 時間古い Pod のまま CrashLoop し続けた。
- **EKS Pod Identity Webhook の injection タイミング**: Pod Identity Association を AWS-side で update (`prometheus` SA → `mimir` SA に rename) しても、既存 Pod の env (`AWS_CONTAINER_CREDENTIALS_FULL_URI` 等) は更新されない。webhook は **Pod 作成時 (Mutating admission)** に env を inject する仕様のため、既存 Pod は古い IAM context のまま EC2 instance role にフォールバックする。

両ケースとも `kubectl delete pod <name>` で強制 delete + 再生成すれば webhook injection が走り正常化する。

**対処:** spec / runbook の "Common pitfalls" section に以下を記録:

- StatefulSet で config / image 更新後に Pod が permanent CrashLoop している場合は `kubectl delete pod <statefulset-name>-0` で強制再生成
- Pod Identity Association を変更したら **対象 SA を使う Pod 全件を rollout restart** (もしくは delete pod)
- webhook injection 系 (= Pod Identity / Istio sidecar / Cilium identity 等) は新 Pod 作成時にしか発動しないことを前提にした runbook を整備

### L8: Brainstorming / plan で全 runtime issue を予防するのは困難、post-merge verification loop の確実性こそが quality gate

本 sub-project の 5 root causes (gp3 StorageClass 不在 / Mimir 3.x schema breaking / TSDB validator / Grafana datasource conflict / Multi-Attach + RollingUpdate) のうち、**brainstorming 段階で予防可能だったのは L1 (changelog 確認) と L4 (verification step 分割) の 2 件のみ**。残る L2 / L3 / L6 は実 deploy 後に表面化する性質 (chart 内部の auto-generation / k8s scheduler ↔ EBS interaction / EKS default 不在) のもので、人間の oversight bandwidth で全網羅は現実的でない。

**機能した quality gate:**

- subagent-driven-development の two-stage review (spec compliance + code quality) は **code-level oversight** (typo / 型不整合 / spec 逸脱) に有効に機能した — Final code reviewer が rebase 必要性 / Thanos TODO 残存 / PR title 長さ等を catch
- ただし **runtime issue は別 loop が必要**: PR merge → GitOps 反映 → cluster 状態 verify という post-merge cycle で発見される

**対処:**

- brainstorming / writing-plans 段階の self-review は continued (= L1 / L4 系の learnings は再発を減らす) しつつ、**post-merge verification loop の確実性を上げる** ことを次の優先課題とする:
  - production cluster の Pod state を CI/CD で gate にする automated smoke test の検討 (= 全 Pod が `Running` になるまで CI が pass しない仕組み)
  - Sub-project 3 / 4 の plan で Test Plan に "merge 後 N 分以内に target Pods 全件 Ready" という concrete success criteria を記述
  - 本 sub-project で確立した "Flux suspend → 手 apply → PR → resume" pattern を runtime fix の標準として再利用 (L5)
- meta lesson: spec / plan の **完璧** を目指すのではなく、**rapid iteration の loop を高速・安全に回せる infrastructure** に投資する方が ROI が高い (= "ship and learn" approach、ただし production-grade safety を伴う形で)
