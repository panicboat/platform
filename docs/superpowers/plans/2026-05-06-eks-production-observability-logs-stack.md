# EKS Production: Observability Logs Stack (Phase 3 Sub-project 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** panicboat EKS production cluster に logs collection + long-term S3 storage + Grafana 連携の logs stack を deploy。`grafana-community/loki` v13.6.0 (SingleBinary mode、Loki 3.7.1) + `fluent/fluent-bit` v0.57.3 を `monitoring` namespace に deploy、Sub-project 1 で provision 済の AWS infra (`loki-559744160976` bucket + `eks-production-loki` IAM role + `loki` Pod Identity SA) を活用、Sub-project 2 で確立した ServiceMonitor pattern + Grafana datasource 統合 path に従う。

**Architecture:** Fluent Bit DaemonSet が container logs を tail → Loki Gateway 経由で SingleBinary に直接 push (= 中間状態、Sub-project 4 で OTel Collector 経由に switching)、Pod Identity 経由で S3 long-term storage。Mimir Microservices との非対称性は意図的選択 (両 chart の official position に従った結果)。

**Tech Stack:** Helm + helmfile / `grafana-community/loki` v13.6.0 (Loki 3.7.1) / `fluent/fluent-bit` v0.57.3 (Fluent Bit 5.0.3) / EBS gp3 PVC / EKS Pod Identity / S3 backend (Sub-project 1 outputs)

**Spec:** `docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (loki/production):**
```
kubernetes/components/loki/production/
├── helmfile.yaml                      # grafana-community/loki chart v13.6.0
└── values.yaml.gotmpl                 # SingleBinary mode + S3 backend + Pod Identity
```

**Kubernetes 新規 (fluent-bit/production):**
```
kubernetes/components/fluent-bit/production/
├── helmfile.yaml                      # fluent/fluent-bit chart v0.57.3
└── values.yaml.gotmpl                 # tail input + Kubernetes filter + Loki HTTP output
```

**Kubernetes 変更 (production):**
```
kubernetes/helmfile.yaml.gotmpl                                 # production env values block に loki cross-stack values 追加
kubernetes/components/prometheus-operator/production/values.yaml.gotmpl   # Grafana datasources に Loki entry 追加
kubernetes/manifests/production/kustomization.yaml              # ./loki + ./fluent-bit を resources に追加
```

**Kubernetes 自動生成 (production hydrate output):**
```
kubernetes/manifests/production/loki/{kustomization.yaml, manifest.yaml}
kubernetes/manifests/production/fluent-bit/{kustomization.yaml, manifest.yaml}
kubernetes/manifests/production/prometheus-operator/manifest.yaml         # 再 hydrate
```

**Kubernetes 変更 (local migration、Decision 6):**
```
kubernetes/components/loki/local/helmfile.yaml      # chart: grafana/loki → grafana-community/loki, version: 7.0.0 → 13.6.0
kubernetes/components/loki/local/values.yaml        # chart schema 変更分の修正
kubernetes/manifests/local/loki/manifest.yaml       # 再 hydrate
```

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-logs-stack
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead (= `4653af7 docs(eks): Phase 3 Sub-project 3 ...`)

- [ ] **Step 2: aws/eks-logs/ resource 存在確認**

```bash
cd aws/eks-logs/envs/production
TG_TF_PATH=tofu terragrunt init -upgrade
terragrunt state list 2>&1 | tee /tmp/eks-logs-state.txt
```

Expected: 8 resources
```
aws_eks_pod_identity_association.this
aws_iam_role.s3_access
aws_iam_role_policy.s3_access
module.s3.aws_s3_bucket.this[0]
module.s3.aws_s3_bucket_lifecycle_configuration.this[0]
module.s3.aws_s3_bucket_public_access_block.this[0]
module.s3.aws_s3_bucket_server_side_encryption_configuration.this[0]
module.s3.aws_s3_bucket_versioning.this[0]
```

- [ ] **Step 3: S3 bucket actual existence (base role)**

```bash
zsh -ic 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws s3api head-bucket --bucket loki-559744160976
aws s3api get-bucket-location --bucket loki-559744160976'
```

Expected: 200 OK + `LocationConstraint: ap-northeast-1`

- [ ] **Step 4: Pod Identity Association 確認 (base role)**

```bash
zsh -ic 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 \
  --query "associations[?serviceAccount==\`loki\`]"'
```

Expected:
```json
[
    {
        "namespace": "monitoring",
        "serviceAccount": "loki",
        "associationArn": "arn:aws:eks:ap-northeast-1:559744160976:podidentityassociation/eks-production/a-...",
        "associationId": "a-..."
    }
]
```

- [ ] **Step 5: Cluster state 確認 (kubectl context)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl get storageclass gp3
kubectl get pods -n monitoring | grep -E "prometheus|alertmanager|grafana|mimir"'
```

Expected:
- `gp3` StorageClass exists (provisioner: `ebs.csi.aws.com`)
- monitoring ns に Prometheus / Alertmanager / Grafana / Mimir 全 component が `Running` (Sub-project 2 stack 稼働中)

- [ ] **Step 6: 既存 local component の現状確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-logs-stack
grep -A 3 "chart: grafana/loki" kubernetes/components/loki/local/helmfile.yaml
grep -A 3 "chart: fluent/fluent-bit" kubernetes/components/fluent-bit/local/helmfile.yaml
```

Expected:
- loki/local: `chart: grafana/loki` + `version: "7.0.0"` (= GEL only chart、Decision 5/6 で migration 対象)
- fluent-bit/local: `chart: fluent/fluent-bit` + `version: "0.57.3"` (= touched しない)

---

## Task 1: local Loki chart migration (`grafana/loki` v7.0.0 → `grafana-community/loki` v13.6.0)

**Files:**
- Modify: `kubernetes/components/loki/local/helmfile.yaml`
- Modify: `kubernetes/components/loki/local/values.yaml`
- Modify (auto-generated): `kubernetes/manifests/local/loki/manifest.yaml`

**Context:** Sub-project 2 brainstorming で発見、Decision 5/6 で確定。grafana/loki chart は 2026/3/16 に GEL only に分離、OSS continuation は grafana-community/loki。local cluster (k3d) で chart 切替を verify した上で production 新規 deploy に進む (= Decision 6 で local migration を本 sub-project の scope に含めた)。

- [ ] **Step 1: helm repo add (grafana-community)**

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm search repo grafana-community/loki --version 13.6.0
```

Expected: `grafana-community/loki  13.6.0  3.7.1  Helm chart for Grafana Loki ...` 出力

- [ ] **Step 2: helmfile.yaml の chart + version を update**

`kubernetes/components/loki/local/helmfile.yaml`:

```yaml
# =============================================================================
# Loki Helmfile for local
# =============================================================================
# Loki is a log aggregation system designed for efficiency and ease of
# operation. It receives logs from the OTel Collector and provides querying
# capabilities in Grafana.
#
# NOTE: 2026/3/16 に grafana/loki chart が GEL only に分離、OSS continuation は
# grafana-community/loki に移行。本 sub-project (Phase 3 Sub-project 3) で
# chart を切替する (Decision 5/6)。
# =============================================================================
environments:
  local:
---
repositories:
  - name: grafana-community
    url: https://grafana-community.github.io/helm-charts

releases:
  - name: loki
    namespace: monitoring
    chart: grafana-community/loki
    version: "13.6.0"
    values:
      - values.yaml
```

- [ ] **Step 3: local values.yaml の chart schema 互換性確認 + 修正**

現状の `kubernetes/components/loki/local/values.yaml` を read して、新 chart (grafana-community/loki v13.6.0) の schema との互換性を確認する。

```bash
# 現状の values.yaml を確認
cat kubernetes/components/loki/local/values.yaml
# 新 chart の default values で対応する key を確認
helm show values grafana-community/loki --version 13.6.0 2>/dev/null | grep -B 1 -A 3 -E "^(deploymentMode|loki:|singleBinary|gateway|test):" | head -40
```

main check points:
- `deploymentMode: SingleBinary` → 維持 (chart で valid な値)
- `loki.auth_enabled: false` → 維持
- `loki.commonConfig.replication_factor: 1` → 維持
- `loki.storage.type: 'filesystem'` → 維持 (local は filesystem、production は s3)
- `loki.schemaConfig` → 必要なら追加 (= chart default は空、local では `useTestSchema: true` で省略可)

values.yaml schema mismatch があれば修正。chart v6.x → v13.x の version 番号 jump があるが、values 構造は continuous evolution と推察。実装段階で `helmfile template` を実行して error なければ schema 互換と判断 (Step 4 で確認)。

- [ ] **Step 4: helmfile template で local manifest を render**

```bash
cd kubernetes
make hydrate-component COMPONENT=loki ENV=local
```

Expected:
- error なく完了
- `kubernetes/manifests/local/loki/manifest.yaml` が再生成される
- 中身に `helm.sh/chart: loki-13.6.0` が含まれる

```bash
grep "helm.sh/chart" kubernetes/manifests/local/loki/manifest.yaml | head -3
```

Expected: `helm.sh/chart: loki-13.6.0`

- [ ] **Step 5: k3d local cluster で deploy verify**

(任意の k3d cluster が起動している前提、もしくは `make phase1 phase2 phase3` で新規 setup)

```bash
# k3d cluster で kubectl apply
kubectl apply -k kubernetes/manifests/local/loki/

# 30 秒待機後に Pod 状態確認
sleep 30
kubectl get pods -n monitoring -l app.kubernetes.io/instance=loki
```

Expected: Loki SingleBinary Pod が `1/1 Running` (or `2/2 Running`、chart 内蔵 sidecar による)、Loki Gateway Deployment が `1/1 Running`

- [ ] **Step 6: local Fluent Bit との接続確認 (= 既存設計、touched なし)**

local の Fluent Bit は OTel Collector 経由で Loki に push する設計 (= README.md の最終形)。新 Loki chart のサービス名 `loki` (or `loki-gateway`) が変わっていないことを確認:

```bash
kubectl get svc -n monitoring -l app.kubernetes.io/instance=loki
```

Expected: `loki` / `loki-gateway` / `loki-headless` / `loki-memberlist` services が存在

(local の OTel Collector → Loki 接続は Sub-project 4 でアクセス確認、本 sub-project では production の中間状態 = Fluent Bit → Loki 直接 のみ scope)

- [ ] **Step 7: Commit**

```bash
git add kubernetes/components/loki/local/helmfile.yaml \
        kubernetes/components/loki/local/values.yaml \
        kubernetes/manifests/local/loki/manifest.yaml
git commit -s -m "feat(kubernetes/components/loki/local): migrate to grafana-community/loki v13.6.0

2026/3/16 に grafana/loki chart は GEL only に分離 (= OSS panicboat には不適切)。
OSS continuation は grafana-community/loki で active maintenance、最新 v13.6.0
(Loki 3.7.1) に切替する。

chart schema は continuous evolution で local values.yaml は概ね互換、必要箇所のみ
修正。production 新規 deploy (Phase 3 Sub-project 3 Task 2-) に向けた前提整備。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md
      Decision 5: chart = grafana-community/loki v13.6.0 (organizational migration)
      Decision 6: local migration = Sub-project 3 のスコープに含める"
```

---

## Task 2: production Loki component (`kubernetes/components/loki/production/`)

**Files:**
- Create: `kubernetes/components/loki/production/helmfile.yaml`
- Create: `kubernetes/components/loki/production/values.yaml.gotmpl`

**Context:** Sub-project 2 (mimir/production) と同形 pattern を踏襲。SingleBinary mode + S3 backend + Pod Identity + ServiceMonitor enable + 30d retention + 1-2 min flush 間隔 (Decision 11 軽減策)。

- [ ] **Step 1: helmfile.yaml を作成**

`kubernetes/components/loki/production/helmfile.yaml`:

```yaml
# =============================================================================
# Loki Helmfile for production
# =============================================================================
# Phase 3 Sub-project 3 で deploy する Logs stack の Loki 本体。
# SingleBinary mode (= chart 内蔵の Monolithic deploy、9 Pod Microservices ではなく
# 1-2 Pod 構成、small production OK の Loki 公式 position に準拠)。
# S3 backend は Sub-project 1 で provision 済の loki-559744160976 を Pod Identity
# 経由でアクセス。
#
# Decision references:
# - D2: SingleBinary mode (HA upgrade path 保持)
# - D3: tenancy=anonymous + retention=30d + auth_enabled=false (Mimir 対称)
# - D5: chart = grafana-community/loki v13.6.0 (Loki 3.7.1)
# - D11: HA upgrade path 明示、WAL flush 1-2 min + retry buffer filesystem-backed
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と
    # 同期すること (loki.bucketName / loki.bucketPathPrefix)。
    values:
      - loki:
          bucketName: loki-559744160976
          bucketPathPrefix: production
---
repositories:
  - name: grafana-community
    url: https://grafana-community.github.io/helm-charts

releases:
  - name: loki
    namespace: monitoring
    chart: grafana-community/loki
    version: "13.6.0"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 2: values.yaml.gotmpl を作成**

`kubernetes/components/loki/production/values.yaml.gotmpl`:

```yaml
# Loki Configuration for production
# SingleBinary mode + S3 backend (Sub-project 1 outputs) + Pod Identity (loki SA)

# =============================================================================
# Deployment Mode (Decision 2)
# =============================================================================
# SingleBinary = chart 内蔵の monolithic deploy。1 StatefulSet (replicas=1) で
# distributor / ingester / querier / query-frontend / store-gateway / compactor
# を全部 in-process。small production 向け、HA は将来 SimpleScalable に upgrade。
deploymentMode: SingleBinary

# =============================================================================
# Loki Core Configuration
# =============================================================================
loki:
  # 1 tenant 運用 (panicboat) のため auth 不要 (Decision 3)
  auth_enabled: false

  # -------------------------------------------------------------------------
  # Common Config
  # -------------------------------------------------------------------------
  commonConfig:
    path_prefix: /var/loki
    # SingleBinary 1 replica なので replication_factor=1 (Decision 2)
    # HA upgrade 時は SimpleScalable 3 replicas + replication_factor=3 に変更
    replication_factor: 1

  # -------------------------------------------------------------------------
  # Storage Config (S3 backend, Sub-project 1 outputs)
  # -------------------------------------------------------------------------
  storage:
    type: s3
    bucketNames:
      chunks: {{ .Values.loki.bucketName }}
      ruler: {{ .Values.loki.bucketName }}
    s3:
      region: ap-northeast-1
      # AWS S3 native = path style 不要 (= virtual-hosted style)
      s3ForcePathStyle: false
      # AWS_ENDPOINT_URL 不要 (= default endpoint)
      endpoint: null
      # Pod Identity 経由のため access key 不要
      accessKeyId: null
      secretAccessKey: null

  # -------------------------------------------------------------------------
  # Schema Config (TSDB schema = Loki 3.x recommended)
  # -------------------------------------------------------------------------
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          # env prefix で IAM policy s3:prefix=production と整合 (Sub-project 1 D11 IAM 3-statement)
          prefix: production_index_
          period: 24h

  # -------------------------------------------------------------------------
  # Storage Config (env prefix for IAM policy compat)
  # -------------------------------------------------------------------------
  storage_config:
    aws:
      # bucket 内 path prefix (= IAM policy s3:prefix=production と整合)
      bucketnames: {{ .Values.loki.bucketName }}
      region: ap-northeast-1
      s3forcepathstyle: false
    tsdb_shipper:
      # local cache (= Loki Pod の PVC 内に index cache を保持、S3 query 高速化)
      active_index_directory: /var/loki/tsdb-index
      cache_location: /var/loki/tsdb-cache
      shared_store: s3

  # -------------------------------------------------------------------------
  # Limits Config (retention 30d、Decision 3)
  # -------------------------------------------------------------------------
  limits_config:
    # logs entry の最大保持期間 = aws/eks-logs/ S3 lifecycle 30d と整合
    retention_period: 720h
    # 1 stream あたりのログ entry rate 制限 (= burst protection)
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 6

  # -------------------------------------------------------------------------
  # Compactor (retention enforcement)
  # -------------------------------------------------------------------------
  compactor:
    # S3 上の chunks を retention に基づき削除する (= aws/eks-logs/ S3 lifecycle と
    # 同 30d、Loki 側でも明示的に enforce)
    retention_enabled: true
    retention_delete_delay: 2h

  # -------------------------------------------------------------------------
  # Ingester (= flush 間隔短縮、Decision 11 軽減策)
  # -------------------------------------------------------------------------
  ingester:
    # WAL chunk を S3 に flush する間隔 (default は 5 min、AZ 障害時のロスト window
    # を縮小するため 2 min に短縮)
    chunk_idle_period: 2m
    # max chunk age = 古い chunk を強制 flush
    max_chunk_age: 5m

# =============================================================================
# ServiceAccount (Pod Identity for S3 access)
# =============================================================================
serviceAccount:
  create: true
  # aws/eks-logs/ で provision 済の Pod Identity Association が
  # monitoring/loki SA を IAM role eks-production-loki に紐付け済
  name: loki
  # Pod Identity は IRSA と異なり annotation 不要 (cluster-side で managed)
  annotations: {}

# =============================================================================
# SingleBinary StatefulSet (Decision 2)
# =============================================================================
singleBinary:
  enabled: true
  replicas: 1

  # PVC: WAL + boltdb-shipper local cache を gp3 10Gi
  persistence:
    enabled: true
    storageClass: gp3
    size: 10Gi

  # Resources (small production)
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1
      memory: 2Gi

  # PodDisruptionBudget は 1 replica なので minAvailable=0 (= 強制 evict 可能)
  # default の `enabled: true` のままだと replicas=1 で minAvailable=1 になる
  # 可能性があり、node drain 時に block する。明示的に disable。
  podDisruptionBudget:
    enabled: false

# =============================================================================
# Loki Gateway (chart 内蔵 nginx)
# =============================================================================
gateway:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
  # Gateway は stateless (PVC なし)、1 replica + RollingUpdate で OK
  # (= Sub-project 2 L3 の Multi-Attach 罠は PVC なしのため発生しない)

# =============================================================================
# Disable subcomponents (SingleBinary mode で不要)
# =============================================================================
# SimpleScalable / Distributed mode の component を全 disable
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

# Cache (memcached-based、small production では不要)
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Test (helm test 用、production では不要)
test:
  enabled: false

# Loki Canary (= synthetic canary、small production では不要)
lokiCanary:
  enabled: false

# Tabler-manager (= deprecated component、Loki 3.x では使わない)
tableManager:
  enabled: false

# Network policy (panicboat では Cilium で別途管理、chart 内蔵は使わない)
networkPolicy:
  enabled: false

# =============================================================================
# Monitoring (ServiceMonitor for Prometheus auto-scrape)
# =============================================================================
monitoring:
  # Self-monitoring metrics を Prometheus が scrape
  serviceMonitor:
    enabled: true
    # kube-prometheus-stack の ServiceMonitor selector に乗るための label
    labels:
      release: kube-prometheus-stack
    interval: 15s

  # Prometheus Rules (= alerting rules)、Phase 4 で alertmanager 設定時に有効化
  rules:
    enabled: false

  # Loki dashboards (chart 内蔵 ConfigMap)、Phase 4 で別途 Grafana に投入
  dashboards:
    enabled: false

  # Self monitoring (= Loki が自分自身の logs を query する仕組み)、不要
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
```

- [ ] **Step 3: helmfile template で render verify**

```bash
cd kubernetes
make hydrate-component COMPONENT=loki ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/loki/manifest.yaml` が新規生成される
- 中身に以下が含まれる:
  - `kind: StatefulSet` (loki SingleBinary)
  - `kind: Deployment` (loki-gateway)
  - `kind: ServiceMonitor` (Prometheus auto-scrape)
  - `kind: ServiceAccount` (name: loki)
  - `loki.storage.bucketnames: loki-559744160976`
  - `replication_factor: 1`

```bash
grep -E "kind:|name: loki$|replication_factor|bucketnames|storageClass" kubernetes/manifests/production/loki/manifest.yaml | head -20
```

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/loki/production/
git commit -s -m "feat(kubernetes/components/loki): add production env (SingleBinary mode + S3 backend)

Phase 3 Sub-project 3 で deploy する Logs stack の Loki 本体。
grafana-community/loki v13.6.0 (Loki 3.7.1) chart の SingleBinary mode で
1 StatefulSet + 1 Gateway Deployment 構成、Pod Identity (loki SA) 経由で
S3 (loki-559744160976) backend にアクセス。

主要設定:
- deploymentMode: SingleBinary (Decision 2)
- replication_factor: 1 (small production、HA upgrade path 保持)
- retention: 30d (= aws/eks-logs/ S3 lifecycle 30d と整合、Decision 3)
- auth_enabled: false (1 tenant anonymous、Decision 3)
- WAL flush 2 min (Decision 11 軽減策で AZ 障害時のロスト window 縮小)
- ServiceMonitor enabled (Sub-project 2 確立 pattern、Decision 9)
- gp3 PVC 10Gi (Sub-project 2 で provision 済 StorageClass 再利用)
- TSDB schema v13 + production_index_ prefix (IAM policy s3:prefix=production と整合)

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md
      Decision 2 / 3 / 5 / 9 / 11"
```

---

## Task 3: production Fluent Bit component (`kubernetes/components/fluent-bit/production/`)

**Files:**
- Create: `kubernetes/components/fluent-bit/production/helmfile.yaml`
- Create: `kubernetes/components/fluent-bit/production/values.yaml.gotmpl`

**Context:** DaemonSet (per node)、tail input + Kubernetes filter + **Loki HTTP output 直接 push** (= Decision 1 中間状態)。filesystem-backed retry buffer (Decision 11 軽減策)。

- [ ] **Step 1: helmfile.yaml を作成**

`kubernetes/components/fluent-bit/production/helmfile.yaml`:

```yaml
# =============================================================================
# Fluent Bit Helmfile for production
# =============================================================================
# Phase 3 Sub-project 3 で deploy する Logs stack の log collector。
# DaemonSet で各 node の container logs を tail、Loki Gateway に HTTP push。
# (= Decision 1 中間状態、Sub-project 4 で OTel Collector 経由に switching)
#
# Decision references:
# - D1: Logs flow path = Fluent Bit → Loki 直接 push (中間状態)
# - D7: chart = fluent/fluent-bit v0.57.3 (Fluent Bit 5.0.3)
# - D8: Pod Identity 不要 (Loki Gateway HTTP push のみ、AWS access なし)
# - D9: ServiceMonitor enabled (Sub-project 2 確立 pattern)
# - D11 軽減策: filesystem-backed retry buffer
# =============================================================================
environments:
  production:
---
repositories:
  - name: fluent
    url: https://fluent.github.io/helm-charts

releases:
  - name: fluent-bit
    namespace: monitoring
    chart: fluent/fluent-bit
    version: "0.57.3"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 2: values.yaml.gotmpl を作成**

`kubernetes/components/fluent-bit/production/values.yaml.gotmpl`:

```yaml
# Fluent Bit Configuration for production
# DaemonSet で container logs を tail、Loki Gateway に HTTP 直接 push (= Decision 1 中間状態)

# =============================================================================
# Deployment Kind
# =============================================================================
# 各 node の container logs を tail するため DaemonSet (= chart default)
kind: DaemonSet

# =============================================================================
# ServiceAccount (Decision 8: Pod Identity 不要)
# =============================================================================
# AWS access 不要 (Loki HTTP push のみ)、default SA で OK
serviceAccount:
  create: true
  annotations: {}

# =============================================================================
# Resources (lightweight per-node DaemonSet)
# =============================================================================
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

# =============================================================================
# Tolerations (= 全 node に乗るため、master/etcd 等の taint に対応)
# =============================================================================
tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

# =============================================================================
# Fluent Bit Config (production override)
# =============================================================================
config:
  # -------------------------------------------------------------------------
  # SERVICE Block
  # -------------------------------------------------------------------------
  service: |
    [SERVICE]
        Daemon Off
        Flush 1
        Log_Level info
        Parsers_File /fluent-bit/etc/parsers.conf
        Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
        HTTP_Server On
        HTTP_Listen 0.0.0.0
        HTTP_Port 2020
        Health_Check On
        # filesystem-backed buffer = node disk 利用、長時間 outage 耐性 (Decision 11 軽減策)
        storage.path              /var/log/flb_storage/
        storage.sync              normal
        storage.checksum          off
        storage.backlog.mem_limit 5M

  # -------------------------------------------------------------------------
  # INPUTS (= container logs tail)
  # -------------------------------------------------------------------------
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
        Refresh_Interval  10
        # storage.type filesystem = retry buffer を node disk に保存 (Decision 11)
        storage.type      filesystem
        # DB ファイルで読み取り position を記録、再起動時に resume
        DB                /var/log/flb_storage/tail.db

  # -------------------------------------------------------------------------
  # FILTERS (= Kubernetes metadata 付与 + cardinality 制御 = Decision 4)
  # -------------------------------------------------------------------------
  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
        Annotations         Off
        Labels              On

    # Decision 4 = 最小 labels (namespace / pod / container) + structured metadata で他保持
    # nest filter で kubernetes_* 系 metadata を整形
    [FILTER]
        Name        nest
        Match       kube.*
        Operation   lift
        Nested_under kubernetes
        Add_prefix  k8s_

  # -------------------------------------------------------------------------
  # OUTPUTS (= Loki HTTP push、Decision 1 中間状態)
  # -------------------------------------------------------------------------
  outputs: |
    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki-gateway.monitoring.svc.cluster.local
        Port              80
        # Loki API path (X-Scope-OrgID header は tenant_id で実装)
        Uri               /loki/api/v1/push
        # 1 tenant 運用 (= Decision 3)
        tenant_id         anonymous
        # Decision 4 labels = 最小 (namespace / pod / container)
        labels            job=fluentbit, namespace=$kubernetes['namespace_name'], pod=$kubernetes['pod_name'], container=$kubernetes['container_name']
        # 残りの k8s metadata は structured metadata で保持 (= cardinality cost なし)
        structured_metadata node=$kubernetes['host'], stream=$stream
        # remove kube_ prefix from log fields
        remove_keys       kubernetes
        # gzip 圧縮で帯域削減
        compress          gzip
        # retry settings
        net.connect_timeout 10
        Retry_Limit       no_limits
        # storage = filesystem buffer (= retry の永続化)
        storage.total_limit_size  5G

# =============================================================================
# Volumes & Volume Mounts (= filesystem buffer 用 hostPath)
# =============================================================================
# default の daemonSetVolumes / daemonSetVolumeMounts に追加
daemonSetVolumes:
  - name: varlog
    hostPath:
      path: /var/log
  - name: varlibdockercontainers
    hostPath:
      path: /var/lib/docker/containers
  - name: etcmachineid
    hostPath:
      path: /etc/machine-id
      type: File
  # Decision 11 軽減策 = filesystem buffer 永続化用の hostPath
  - name: flb-storage
    hostPath:
      path: /var/log/flb_storage
      type: DirectoryOrCreate

daemonSetVolumeMounts:
  - name: varlog
    mountPath: /var/log
  - name: varlibdockercontainers
    mountPath: /var/lib/docker/containers
    readOnly: true
  - name: etcmachineid
    mountPath: /etc/machine-id
    readOnly: true
  - name: flb-storage
    mountPath: /var/log/flb_storage

# =============================================================================
# ServiceMonitor (Prometheus auto-scrape, Decision 9)
# =============================================================================
serviceMonitor:
  enabled: true
  # kube-prometheus-stack の ServiceMonitor selector に乗るための label
  additionalLabels:
    release: kube-prometheus-stack
  interval: 15s

# =============================================================================
# Test (= helm test 用、production では不要)
# =============================================================================
testFramework:
  enabled: false
```

- [ ] **Step 3: helmfile template で render verify**

```bash
cd kubernetes
make hydrate-component COMPONENT=fluent-bit ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/fluent-bit/manifest.yaml` が新規生成される
- 中身に以下が含まれる:
  - `kind: DaemonSet` (fluent-bit)
  - `kind: ServiceMonitor` (Prometheus auto-scrape)
  - `kind: ServiceAccount` (default name)
  - `loki-gateway.monitoring.svc.cluster.local` 出力 OUTPUT block
  - `tenant_id anonymous` 出力

```bash
grep -E "kind:|loki-gateway|tenant_id|storage.type filesystem" kubernetes/manifests/production/fluent-bit/manifest.yaml | head -10
```

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/fluent-bit/production/
git commit -s -m "feat(kubernetes/components/fluent-bit): add production env (Loki direct push)

Phase 3 Sub-project 3 で deploy する Logs stack の log collector。
fluent/fluent-bit v0.57.3 (Fluent Bit 5.0.3) chart の DaemonSet で各 node の
container logs を tail、Loki Gateway に HTTP 直接 push。

Decision 1 中間状態 (= Fluent Bit → Loki 直接、Sub-project 4 で OTel
Collector 経由に switching)。Decision 4 = 最小 labels (namespace / pod /
container) + structured metadata で他 k8s metadata を保持、cardinality 制御。
Decision 8 = Pod Identity 不要 (AWS access なし)。Decision 9 = ServiceMonitor
enabled。Decision 11 軽減策 = filesystem-backed retry buffer (= node disk
/var/log/flb_storage/、長時間 outage 耐性)。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md
      Decision 1 / 4 / 7 / 8 / 9 / 11"
```

---

## Task 4: Cross-stack values + Grafana datasource update

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`

**Context:** Plan 1c-β L4 pattern (= placeholder 不採用、直接実値書き) を踏襲。Grafana datasource は Sub-project 2 で確立した pattern (= `datasources.yaml` に追加)、default は Mimir 維持 (Decision 10)。

- [ ] **Step 1: kubernetes/helmfile.yaml.gotmpl の production env values block に loki cross-stack values を追加**

現状の関連箇所:
```bash
grep -n -B 2 -A 20 "production:" kubernetes/helmfile.yaml.gotmpl | head -40
```

production env block の `mimir:` 直下に同形の `loki:` block を追加:

```yaml
# Before:
environments:
  production:
    values:
      - cluster:
          name: eks-production
        karpenter:
          interruptionQueueName: Karpenter-eks-production
        mimir:
          bucketName: mimir-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-mimir

# After:
environments:
  production:
    values:
      - cluster:
          name: eks-production
        karpenter:
          interruptionQueueName: Karpenter-eks-production
        mimir:
          bucketName: mimir-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-mimir
        loki:
          # Source: aws/eks-logs/envs/production terragrunt output
          bucketName: loki-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-loki
```

(具体的な diff 箇所は実装段階で確定、上記は概念例)

- [ ] **Step 2: kubernetes/components/prometheus-operator/production/values.yaml.gotmpl の Grafana datasource に Loki entry を追加**

現状の `datasources.yaml.datasources` block を確認:

```bash
grep -n -B 2 -A 30 "datasources:" kubernetes/components/prometheus-operator/production/values.yaml.gotmpl | head -50
```

Mimir entry の後に Loki entry を追加 (Mimir / Prometheus と並列、`isDefault: false`、Decision 10):

```yaml
grafana:
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Mimir
          uid: mimir
          type: prometheus
          url: http://mimir-distributed-gateway.monitoring.svc.cluster.local/prometheus
          access: proxy
          isDefault: true       # Mimir = default (Decision 10)
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
        # Phase 3 Sub-project 3 (Logs stack)
        - name: Loki
          uid: loki
          type: loki
          url: http://loki-gateway.monitoring.svc.cluster.local
          access: proxy
          isDefault: false      # Loki は default にしない (= Mimir 維持、Decision 10)
          jsonData:
            # 1 tenant 運用 (= Decision 3)
            httpHeaderName1: X-Scope-OrgID
          secureJsonData:
            httpHeaderValue1: anonymous
```

- [ ] **Step 3: helmfile template で prometheus-operator を再 hydrate**

```bash
cd kubernetes
make hydrate-component COMPONENT=prometheus-operator ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/prometheus-operator/manifest.yaml` で Loki datasource が新規追加された diff

```bash
git diff kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -30
```

Expected: `name: Loki` / `type: loki` / `url: http://loki-gateway.monitoring.svc.cluster.local` の追加 diff が含まれる

- [ ] **Step 4: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl \
        kubernetes/components/prometheus-operator/production/values.yaml.gotmpl \
        kubernetes/manifests/production/prometheus-operator/manifest.yaml
git commit -s -m "feat(kubernetes): add Loki cross-stack values + Grafana datasource

Phase 3 Sub-project 3 (Logs stack) のための cross-stack values を
production env に追加 (= Plan 1c-β L4 pattern、placeholder 不採用)。

1. kubernetes/helmfile.yaml.gotmpl
   production env values block に loki: bucketName / bucketPathPrefix /
   podIdentityRoleName を追加 (Sub-project 1 outputs と整合)。

2. kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
   grafana.datasources.datasources.yaml.datasources に Loki entry 追加
   (Mimir = default 維持、Loki = isDefault: false、Decision 10)。
   X-Scope-OrgID: anonymous header で tenant 指定 (Decision 3)。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md
      Decision 3 / 9 / 10"
```

---

## Task 5: Hydrate manifests + kustomization.yaml update

**Files:**
- Auto-generate: `kubernetes/manifests/production/loki/{kustomization.yaml, manifest.yaml}`
- Auto-generate: `kubernetes/manifests/production/fluent-bit/{kustomization.yaml, manifest.yaml}`
- Modify: `kubernetes/manifests/production/kustomization.yaml`

**Context:** Sub-project 2 と同形の hydrate output。kustomization.yaml に新 component 2 つを resources として追加。

- [ ] **Step 1: hydrate-index で manifests/production/ を再生成 + cleanup**

```bash
cd kubernetes
make hydrate-index ENV=production
```

Expected:
- `kubernetes/manifests/production/loki/kustomization.yaml` が新規作成される (`resources: [manifest.yaml]`)
- `kubernetes/manifests/production/fluent-bit/kustomization.yaml` が新規作成される
- 既存の loki / fluent-bit manifest.yaml も再生成

確認:
```bash
ls kubernetes/manifests/production/loki/
ls kubernetes/manifests/production/fluent-bit/
```

Expected: 各 dir に `kustomization.yaml` + `manifest.yaml` の 2 file

- [ ] **Step 2: kubernetes/manifests/production/kustomization.yaml に追加**

現状:
```bash
cat kubernetes/manifests/production/kustomization.yaml
```

Expected (Sub-project 2 完了時点):
```yaml
resources:
  - ./00-namespaces
  - ./aws-load-balancer-controller
  - ./cilium
  - ./external-dns
  - ./gateway-api
  - ./karpenter
  - ./keda
  - ./metrics-server
  - ./mimir
  - ./prometheus-operator
  - ./storage-class
```

`./fluent-bit` と `./loki` を **アルファベット順** で追加 (= `./external-dns` の前と `./keda` の後):

```yaml
resources:
  - ./00-namespaces
  - ./aws-load-balancer-controller
  - ./cilium
  - ./external-dns
  - ./fluent-bit
  - ./gateway-api
  - ./karpenter
  - ./keda
  - ./loki
  - ./metrics-server
  - ./mimir
  - ./prometheus-operator
  - ./storage-class
```

- [ ] **Step 3: kustomize build で全体 manifest を render verify**

```bash
kubectl kustomize kubernetes/manifests/production/ > /tmp/production-rendered.yaml
echo "Total resources: $(grep -c '^kind:' /tmp/production-rendered.yaml)"
echo ""
echo "=== loki resources ==="
grep -B 1 "name: loki" /tmp/production-rendered.yaml | grep "kind:" | sort | uniq -c
echo ""
echo "=== fluent-bit resources ==="
grep -B 1 "name: fluent-bit" /tmp/production-rendered.yaml | grep "kind:" | sort | uniq -c
echo ""
echo "=== Loki datasource entry in Grafana cm ==="
grep -A 3 "name: Loki" /tmp/production-rendered.yaml | head -10
```

Expected:
- error なく完了
- Loki resource: StatefulSet 1 + Deployment (gateway) 1 + Service 数件 + ServiceMonitor 1 + ConfigMap 1 + ServiceAccount 1
- Fluent Bit resource: DaemonSet 1 + Service 1 + ServiceMonitor 1 + ConfigMap 1 + ServiceAccount 1
- Grafana datasources cm に `name: Loki` entry が含まれる

- [ ] **Step 4: Commit**

```bash
git add kubernetes/manifests/production/loki/ \
        kubernetes/manifests/production/fluent-bit/ \
        kubernetes/manifests/production/kustomization.yaml
git commit -s -m "chore(kubernetes/manifests): hydrate loki + fluent-bit for production

Phase 3 Sub-project 3 (Logs stack) の helmfile template 結果を hydrate。
kustomization.yaml に ./fluent-bit + ./loki を追加 (alphabetical order)。

manifest.yaml の中身は components/loki/production/ + components/fluent-bit/production/
の helmfile.yaml + values.yaml.gotmpl から auto-generated (= make hydrate-index)。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md"
```

---

## Task 6: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Sub-project 2 L4 learnings 適用。Pre-flight check 全件 ✅ を PR description に記録してから Ready for review に切替。

- [ ] **Step 1: branch 状態を確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-logs-stack
git log --oneline origin/main..HEAD
```

Expected: 6 commits ahead (Task 1 から Task 5 まで + spec commit)
```
<sha> chore(kubernetes/manifests): hydrate loki + fluent-bit for production
<sha> feat(kubernetes): add Loki cross-stack values + Grafana datasource
<sha> feat(kubernetes/components/fluent-bit): add production env (Loki direct push)
<sha> feat(kubernetes/components/loki): add production env (SingleBinary mode + S3 backend)
<sha> feat(kubernetes/components/loki/local): migrate to grafana-community/loki v13.6.0
<sha> docs(eks): Phase 3 Sub-project 3 (Observability Logs stack) design spec
```

- [ ] **Step 2: branch を origin に push**

```bash
git push -u origin HEAD
```

Expected: `branch 'feat/eks-production-observability-logs-stack' set up to track 'origin/feat/eks-production-observability-logs-stack'`

- [ ] **Step 3: Draft PR を作成 (Pre-flight check 結果を含む)**

PR title: `feat(eks): Phase 3 Sub-project 3 — Logs stack (Loki SingleBinary + Fluent Bit)`

PR body は以下:

```markdown
## Summary

Phase 3 Sub-project 3 (Logs stack) の implementation。`grafana-community/loki` v13.6.0 (SingleBinary mode、Loki 3.7.1) + `fluent/fluent-bit` v0.57.3 を `monitoring` namespace に deploy。Sub-project 1 で provision 済の AWS infra (`loki-559744160976` bucket + `eks-production-loki` IAM role + `loki` Pod Identity SA) を活用、Sub-project 2 で確立した ServiceMonitor pattern + Grafana datasource 統合 path に従う。

**Architecture (中間状態):** Fluent Bit DaemonSet が container logs を tail → Loki Gateway 経由で SingleBinary に直接 push (= Decision 1)、Pod Identity 経由で S3 long-term storage。Sub-project 4 で OTel Collector deploy 後に Fluent Bit → OTel Collector → Loki に switching 予定。

## Spec

`docs/superpowers/specs/2026-05-06-eks-production-observability-logs-stack-design.md` (12 Decisions、Sub-project 2 learnings 全項目適用)

## Notable Decisions

- **D1**: Logs flow = Fluent Bit → Loki 直接 push (中間状態)
- **D2**: Loki SingleBinary (Mimir Microservices と非対称、両 chart の official position 準拠)
- **D5**: chart = `grafana-community/loki` v13.6.0 (`grafana/loki` が GEL only に分離した結果として OSS continuation chart に移行)
- **D6**: local migration を本 sub-project に含める
- **D11**: HA upgrade path 明示 (1 replica で start、必要なら SimpleScalable + multi-AZ)

## Pre-flight check

- [x] aws/eks-logs/ terragrunt state 8 resources confirmed (Task 0 Step 2)
- [x] S3 bucket loki-559744160976 head-bucket 200 OK (Task 0 Step 3)
- [x] Pod Identity Association monitoring/loki exists (Task 0 Step 4)
- [x] gp3 StorageClass exists (Task 0 Step 5)
- [x] Sub-project 2 stack all Running (Task 0 Step 5)
- [x] local migration verified on k3d (Task 1 Step 5)

## Test plan (post-flight, after merge)

### 10 分以内
- [ ] Loki SingleBinary `1/1 Running`
- [ ] Loki Gateway `1/1 Running`
- [ ] Fluent Bit DaemonSet が全 node で `1/1 Running`
- [ ] PVC `storage-loki-0` Bound (gp3 10Gi)
- [ ] Prometheus targets で `loki` / `fluent-bit` が `UP`

### 30 分以内
- [ ] S3 (`loki-559744160976/production/`) に chunks 出現
- [ ] Grafana Explore で `{namespace="monitoring"}` query が logs を返す
- [ ] Sub-project 2 stack regression なし (Mimir / Prometheus / Alertmanager / Grafana 全 Running、Mimir gateway `/ready` OK)

## Sub-project 2 learnings 適用

| Sub-project 2 learnings | 本 PR での適用 |
|---|---|
| L1 (chart upgrade での upstream changelog 確認) | D5: grafana/loki → grafana-community/loki organizational migration |
| L2 (chart auto-generated ConfigMap と values override の衝突) | Sub-project 2 の `defaultDatasourceEnabled: false` 設定継続、新たな衝突は発生しない |
| L3 (EBS RWO + RollingUpdate → Recreate) | Loki SingleBinary は StatefulSet (OrderedReady)、Loki Gateway は Deployment + PVC なし、新規 Recreate 設定不要 |
| L4 (Spec verification を pre-flight / post-flight 分割) | 本 PR description に Pre-flight check section 明示 |
| L5 (Flux suspend pattern) | 通常 deploy で進める、問題発見時のみ reactive 発動 |
| L6 (gp3 StorageClass) | Sub-project 2 で provision 済再利用 |
| L7 (Pod Identity webhook injection) | 新規 deploy のため初回起動時に正しく injection、force-delete シナリオなし |
| L8 (storage_prefix 英数字制約) | Loki でも `production` (slash なし) を採用 |

## Rollback 手順 (想定外障害時)

```bash
flux suspend kustomization flux-system
kubectl delete -k kubernetes/manifests/production/loki/
kubectl delete -k kubernetes/manifests/production/fluent-bit/
kubectl get pods -n monitoring | grep -v loki | grep -v fluent-bit  # Sub-project 2 影響なき確認
gh pr create --title "revert: Phase 3 Sub-project 3 (Logs stack)" ...
flux reconcile source git flux-system
flux resume kustomization flux-system
```

aws/eks-logs/ は Sub-project 1 で provision 済 = AWS-side rollback 不要。
```

```bash
gh pr create --draft \
  --title "feat(eks): Phase 3 Sub-project 3 — Logs stack (Loki SingleBinary + Fluent Bit)" \
  --body "$(<above body>)"
```

Expected: PR URL 出力 (例: `https://github.com/panicboat/platform/pull/<N>`)

- [ ] **Step 4: PR URL を確認**

```bash
gh pr view --json title,url,isDraft --jq '.'
```

Expected:
```json
{
    "isDraft": true,
    "title": "feat(eks): Phase 3 Sub-project 3 — Logs stack (Loki SingleBinary + Fluent Bit)",
    "url": "https://github.com/panicboat/platform/pull/<N>"
}
```

PR title 文字数: ≤ 70 visible chars 確認 (= Sub-project 2 PR title 教訓、`wc -m` で 100 以下に収める)。

```bash
echo -n "feat(eks): Phase 3 Sub-project 3 — Logs stack (Loki SingleBinary + Fluent Bit)" | wc -m
```

Expected: ≤ 100 (em dash の 3 byte 含む)、visible chars ≤ 70

(ここで USER GATE: PR review + Ready for review + merge は user 操作)

---

## Self-review

### Spec coverage

| Spec section | 実装 task | カバレッジ |
|---|---|---|
| Architecture (mermaid) | Task 2 / 3 / 5 | ✅ Loki + Fluent Bit + ServiceMonitor + Grafana datasource すべて Task で網羅 |
| Components table | Task 2 / 3 | ✅ Fluent Bit DaemonSet / Loki Gateway / Loki SingleBinary / ServiceMonitor / Grafana datasource すべてカバー |
| Data flow (Step 1-6 + side flows) | Task 2 / 3 | ✅ container stdout → tail → kubernetes filter → Loki HTTP push → S3 を全 step 実装 |
| AWS infra (Sub-project 1 利用) | Task 0 (verify only) | ✅ pre-flight check で existence 確認、変更なし |
| Decision 1 (中間状態) | Task 3 (Fluent Bit Loki output 直接 push) | ✅ |
| Decision 2 (SingleBinary) | Task 2 (deploymentMode: SingleBinary) | ✅ |
| Decision 3 (anonymous + 30d + auth disabled) | Task 2 (auth_enabled: false / retention_period: 720h / tenant_id: anonymous) | ✅ |
| Decision 4 (最小 labels + structured metadata) | Task 3 (Loki output labels block + structured_metadata block) | ✅ |
| Decision 5 (grafana-community/loki v13.6.0) | Task 1 (local migration) + Task 2 (production new) | ✅ |
| Decision 6 (local migration) | Task 1 | ✅ |
| Decision 7 (fluent/fluent-bit v0.57.3) | Task 3 (helmfile.yaml chart version) | ✅ |
| Decision 8 (Pod Identity 不要) | Task 3 (serviceAccount.create: true、annotations なし) | ✅ |
| Decision 9 (ServiceMonitor + Grafana datasource) | Task 2 (Loki monitoring.serviceMonitor) + Task 3 (Fluent Bit serviceMonitor) + Task 4 (datasources.yaml に Loki 追加) | ✅ |
| Decision 10 (Mimir = default 維持) | Task 4 (Loki: isDefault: false) | ✅ |
| Decision 11 (HA upgrade path 明示) | Task 2 (replicas: 1 + WAL flush 2 min) + Task 3 (filesystem buffer) | ✅ |
| Decision 12 (Mimir 非対称) | (実装事項なし、spec note のみ) | ✅ |
| Test plan (pre-flight 6 + post-flight 13) | Task 0 (pre-flight) + Task 6 (PR description で post-flight 明示) | ✅ |

### Placeholder scan

- [x] "TBD" / "TODO" / "FIXME" 等の placeholder なし
- [x] 各 Step で actual code block (helmfile.yaml / values.yaml.gotmpl / commit message) を完全に書き出し済
- [x] "Similar to Task N" 形式の reference なし (= 各 task の code を完全 transcribe)

### Type / naming consistency

- [x] SA name `loki` は Task 2 + Task 0 (pre-flight check) + spec で一貫
- [x] Bucket name `loki-559744160976` は Task 2 / Task 4 / Task 0 で一貫
- [x] Service name `loki-gateway.monitoring.svc.cluster.local` は Task 3 (Fluent Bit OUTPUT Host) + Task 4 (Grafana datasource url) で一貫
- [x] Tenant ID `anonymous` は Task 3 / Task 4 で一貫
- [x] Storage class `gp3` は Task 2 で参照、Sub-project 2 の既存 component と一貫
- [x] kube-prometheus-stack ServiceMonitor selector label `release: kube-prometheus-stack` は Task 2 (Loki) + Task 3 (Fluent Bit) で一貫

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) 全 task の commit step で指定
- [x] `Co-Authored-By` 不付与 (全 commit message に無し)
- [x] PR は `--draft` (Task 6 Step 3)
- [x] 新規ブランチ初回 push: `git push -u origin HEAD` (Task 6 Step 2)
- [x] Conventional Commits 全 commit が `feat(scope):` / `chore(scope):` 形式

### Plan 1c-β / Plan 2 / Plan tuning / Sub-project 1 / 2 の知見反映

- [x] **Plan 1c-β L1 (IRSA random suffix)** → 本 plan は Pod Identity 採用で IRSA 不使用
- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT 不要)** → Task 4 で helmfile.yaml.gotmpl に直接実値 (`loki-559744160976`) を書く、placeholder pattern 不採用
- [x] **Plan 1c-β L5 (squash merge 後 branch reset rollback)** → Task 0 Step 1 で `git fetch origin main && git log --oneline origin/main..HEAD` 確認
- [x] **Plan 2 L7 (spec/plan divergence)** → 本 plan の brainstorming 中に判明した chart の organizational migration (= grafana/loki → grafana-community/loki) を spec で明示記録 (Decision 5)
- [x] **Sub-project 1 L1 (IAM policy 3 statement)** → 本 sub-project は IAM 触らないため non-applicable
- [x] **Sub-project 1 L2 (Plan の sibling tasks 間 comment style 一致)** → 本 plan は sibling tasks 無し (各 task が unique)
- [x] **Sub-project 1 L3 (resource count expected の精度)** → 本 plan の Task 5 Step 3 で expected resource count を range で書く (= Loki StatefulSet 1 + Deployment 1 + Service 数件)
- [x] **Sub-project 1 L4 (two-stage review が plan-level oversight catch)** → 本 plan の implementation でも subagent-driven-development で 2-stage review を継続
- [x] **Sub-project 1 L5 (sibling stacks symmetric)** → 本 plan は sibling stack 無し
- [x] **Sub-project 2 L1 (chart upgrade での upstream changelog 確認)** → Decision 5 で grafana/loki → grafana-community/loki organizational migration を発見、spec / plan に明示記録
- [x] **Sub-project 2 L2 (chart auto-generated ConfigMap 衝突)** → Sub-project 2 PR #289 の `defaultDatasourceEnabled: false` 設定が既存、新たな衝突なし
- [x] **Sub-project 2 L3 (EBS RWO + RollingUpdate → Recreate)** → Loki SingleBinary は StatefulSet、Gateway は PVC なし、新規 Recreate 不要
- [x] **Sub-project 2 L4 (Spec verification を pre-flight / post-flight 分割)** → Task 0 (pre-flight 6 件) + Task 6 PR description (post-flight 13 件) で明示分離
- [x] **Sub-project 2 L5 (Flux suspend pattern)** → Spec Test plan section に Rollback 手順として明示
- [x] **Sub-project 2 L6 (gp3 StorageClass)** → Sub-project 2 で provision 済再利用、本 sub-project では作らない
- [x] **Sub-project 2 L7 (Pod Identity webhook injection は Pod 作成時のみ)** → 新規 deploy のため初回起動時に正しく injection
- [x] **Sub-project 2 L8 (storage_prefix 英数字制約)** → Loki schema config の `prefix: production_index_` で英数字 + underscore のみ使用、slash 不要 = Mimir L8 適用済

---

## Lessons Learned (post-execution)

PR #291 (本 sub-project の初回 merge) で deploy した直後に 4 件の runtime issue が判明し、PR #292 で fix を完了 + Flux 同期再開して production cluster で logs stack が正常稼働するに至った。Sub-project 2 で確立した Flux suspend pattern (= L5) が再利用され、確立 pattern として validate された。今回の中で **公式 docs に基づく事実関係調査** + **Sub-project 1 で確立した IAM 設計の retrospective** が大きな知見となった。次 sub-project (Phase 3 Sub-project 4 Traces / Tempo) 設計時の参考と、運用 pattern の標準化のために記録する。

### L1: chart の application 内部実装 (= 固定 path / 強制動作) は IAM design では予防困難

Loki 3.x の compactor `delete_request_store` は **bucket root の固定 path `index/delete_requests/`** に DeleteObject 試行する。chart values で path 制御不可 ([Loki Issue #14657](https://github.com/grafana/loki/issues/14657) で `object_prefix` が全 component に一貫適用されない問題が報告)。Sub-project 1 で確立した env-scoped IAM (`${bucket}/${env}/*`) と整合しない。

これは **brainstorming / planning 段階で予防困難** な性質の issue:

- chart README / values に書かれていない application 内部実装
- runtime で初めて表面化 (= initial deploy 時に CrashLoopBackOff)
- post-merge cycle で発見されるべき (= Sub-project 2 L8 の "実 deploy 後に初めて見つかる errors" と同性質)

**対処:**

- **brainstorming 段階** で各 stack の **公式 IAM template** (= 公式 docs に明記された permission set) を必ず確認する慣習を導入。chart の application 内部実装に依存する path を IAM scope で control しない。
- **post-merge verification** (= Sub-project 2 L4 で確立した pre-flight / post-flight 分割) を確実に回す。runtime issue は post-flight で catch する。

### L2: Sub-project 1 IAM 設計の retrospective — env scope は IAM レベルではなく application-level prefix で

Sub-project 1 で **env-scoped IAM** (= `${bucket}/${env}/*` の Resource scope + `s3:prefix=${env}/*` condition) を 3 sibling stack で確立した。これは AWS IAM の least privilege 原則に沿う設計だが、本 sub-project で **Loki 3.x compactor の bucket root 固定 path** と整合しないことが判明。

公式 docs を再調査した結果:

- **Grafana Loki 公式** ([Storage configuration AWS](https://grafana.com/docs/loki/latest/configure/storage/#aws)): `Resource: [${bucket}, ${bucket}/*]` (= prefix なし) を IAM template として推奨
- **Grafana Tempo 公式** ([S3 configuration](https://grafana.com/docs/tempo/latest/configuration/s3/)): 同 Loki と同形式
- **Grafana Mimir** ([Discussion #2264](https://github.com/grafana/mimir/discussions/2264)): community で同 pattern が主流、`storage_prefix` で application-level env scope 実現

つまり **公式推奨は bucket-wide IAM + application-level prefix で env scope** であり、Sub-project 1 で確立した IAM レベルの env scope は **公式 pattern から逸脱した independent 設計** だった。

**対処:**

- 3 sibling stack の IAM policy を **`Resource: [${bucket}, ${bucket}/*]` に統一** (= Loki / Tempo 公式と整合)、env scope は各 stack の application-level prefix で担保:
  - Mimir: `blocks_storage.storage_prefix: production` (Sub-project 2 で実証済)
  - Tempo: `storage.trace.s3.prefix: production` (Sub-project 4 で予定)
  - Loki: TSDB schema `index.prefix: production_index_` (本 sub-project で実装)
- defense in depth は弱まるが (= bucket-wide write 権限)、各 application が prefix を強制するので env 越境 write は構造的に発生しない。
- AWS multi-tenant pattern としては **bucket-per-tenant** が long-term sustainable ([AWS Storage Blog](https://aws.amazon.com/blogs/storage/design-patterns-for-multi-tenant-access-control-on-amazon-s3/))、Phase 4 以降で再検討候補。

**Sub-project 1 spec / plan は本 sub-project では update しない**: 既に確立した historical record として保持、本 fix は Sub-project 3 の changeset で扱う。Sub-project 1 spec の D11 (= IAM 3-statement structure) は当時の判断として valid、ただし production 運用で Loki / Tempo を扱う場合は本 learnings を参照する。

### L3: Helm chart default readinessProbe は application policy と矛盾する場合あり、values で override

`fluent/fluent-bit` chart v0.57.3 の default readinessProbe は `/api/v2/health` (= comprehensive check、output retry limits + dropped chunks 累計を含む)。これは strict check で、production policy と矛盾する場合がある:

- panicboat は `Retry_Limit no_limits` (= retry 無制限、長時間 outage 耐性) + `storage.type filesystem` (= node disk buffer) の policy
- Loki ingester `max_chunk_age: 5m` 超過の古い entries は `entry too far behind` で reject される
- これらの reject errors が retry buffer で蓄積 → `/api/v2/health` が HTTP 500 を返し続ける → Pod 永遠に NotReady

**対処:**

- readinessProbe + livenessProbe を **`/api/v1/health` (= Fluent Bit プロセス up の simple check)** に変更
- output 健全性は ServiceMonitor 経由の Prometheus metrics で別途観測:
  - `fluentbit_output_retries_failed_total`
  - `fluentbit_output_dropped_records_total`
  - 等を Mimir に remote_write、必要なら alertmanager で alerting
- 一般化: **chart default の strict probe は確認すべき項目**。production policy (retry / buffer / output destination 等) と矛盾するケースを brainstorming 段階でチェックする。

### L4: Uniform retention の場合は S3 lifecycle で代替、application-level retention は per-tenant rules 等の advanced feature 用

Loki / Mimir の retention 機能 (`compactor.retention_enabled` 等) は **user-defined retention rules を強制するため** (= 「app=foo は 7d」「tenant=bar は 90d」等の差分 retention)。panicboat は uniform 30d retention で十分なため、application-level retention は redundant。

加えて Loki 3.x の retention 機能は **delete request store** という追加 component を必要とし、bucket root 固定 path (= L1 で flag した issue) を使う。これが IAM 設計を複雑化させる。

**対処:**

- panicboat は **S3 lifecycle (= aws/eks-{metrics,logs,traces}/ で provision 済)** で uniform retention を担保。application-level retention 機能は OFF。
  - Mimir: 90d (S3 lifecycle)
  - Loki: 30d (S3 lifecycle)
  - Tempo: TBD (Sub-project 4 で確定)
- compactor 自体は **chunks compaction (= S3 IO 効率化、cost 削減)** のため起動を維持、retention enforcement のみ off。
- 細かい per-tenant / per-stream retention rules が必要になったら **Phase 4 (advanced features)** で再検討 (= IAM 設計も含めた見直しが必要)。

### L5: Flux suspend pattern が再利用、Sub-project 2 で確立した standard runbook として validate

PR #291 merge 後の runtime issue 解消で **Sub-project 2 L5 (Flux suspend → 手 apply → 検証 → PR → resume)** pattern を再適用。production cluster で機能した。

具体手順 (Sub-project 2 と同一):

1. `flux suspend kustomization flux-system` で同期停止
2. 手 `kubectl apply` で fix を当てて検証
3. 検証 OK 確認後に PR 作成 + merge
4. `flux reconcile source git` → `flux resume` → `flux reconcile kustomization --with-source` で resume
5. cluster state と repo の最新 commit が等価 → idempotent re-apply で no-op

**重要な再認証ポイント:**

- `prune: true` の Kustomization でも、suspend 中は drift detection が止まるため手 apply で追加した resource (今回は IAM update + Loki/Fluent Bit values 更新) が削除されない
- merge 後の resume は idempotent re-apply、cluster state が最新 commit と一致していれば Pod restart も発生しない (今回 Sub-project 2 stack の component は AGE 6h+ を維持、影響なし)
- Loki SingleBinary も idempotent (= AGE 10m を維持、Flux re-apply で restart なし)

**運用 pattern として確立:** 本 pattern を **production runtime fix の standard runbook** として spec template に組み込む。Sub-project 4 / 5 / ... で同種の post-merge issue が起きた場合に再利用する。

### L6: Loki `auth_enabled: false` 時の internal default tenant ID = `fake`

`auth_enabled: false` を設定した Loki は、`X-Scope-OrgID` header を **無視**して internal default tenant ID `fake` で全 logs を保存する ([Loki 公式 Multi-tenancy docs](https://grafana.com/docs/loki/latest/operations/multi-tenancy/)):

> If multi-tenancy is disabled (auth_enabled: false), all data goes into the default tenant called `fake`.

panicboat の Fluent Bit OUTPUT で `tenant_id: anonymous` を設定したが、Loki は `auth_enabled: false` で受けるため実際の S3 path は `${bucket}/fake/<chunks>/...` になる。

**実害なし** (= 1 tenant 運用で全 logs が同 tenant に集約されるという挙動は同じ) が、以下の点で記録:

- Grafana datasource の `X-Scope-OrgID: anonymous` header も実は無視される (Loki が `fake` で受ける)、ただし送信側のロジックは正しい
- 将来 multi-tenant 化する場合 (= `auth_enabled: true` に切替) は、tenant ID の合意 (`anonymous` / `panicboat` / 等) を Fluent Bit OUTPUT + Grafana datasource + Mimir / Tempo (もし auth 有効化) で揃える必要

**対処:**

- 現状は `fake` のままで運用 (= 実害なし)
- `auth_enabled: true` に切替する場合 (Phase 4 等で multi-tenant 必要時)、tenant ID を spec の Decision として明示記録、3 stack で揃える

### L7: 3 sibling stack symmetric を維持しつつ runtime fix を行うコスト評価

Sub-project 1 L5 で確立した「3 sibling stack symmetric」原則は long-term maintenance に効くが、runtime fix で **3 stack 全てを同時に変更する必要がある** ケースが出る (= 本 sub-project の IAM align)。

評価:

- **メリット**: Sub-project 1 plan / spec が template として 3 stack に展開されている → 1 箇所修正の方法論で 3 stack 同時に対応可能、template として再利用可能
- **コスト**: 1 stack だけ修正 (= 例えば eks-logs だけ IAM align) で済む場合でも、symmetric 維持のため 3 stack apply が必要 → terragrunt apply のコストが 3 倍
- **判定**: 今回は 3 stack 全てに公式準拠の IAM が適用されたので long-term ROI が positive。ただし **「1 stack 固有の fix で symmetric を捨てるべきか?」 の判断点は brainstorming で議論すべき**

**対処:**

- brainstorming / planning 段階で「sibling stack symmetric を維持するコスト」と「1 stack 固有の fix で済む価値」を明示比較する慣習。
- 今回のケースは **公式 docs が 3 stack で同一の IAM template を推奨** していたため symmetric 維持が natural、長期 maintenance に有利と判断。

### L8: subagent-driven-development の two-stage review が runtime issue を catch しない場合がある (= meta lesson 再認証)

本 sub-project でも subagent-driven-development の two-stage review (spec compliance + code quality) を全 task で実施。Final code reviewer は subagent rate limit で controller 直接実施に切替。spec compliance / code quality レベルでは **Verdict: APPROVED** で完走したが、**post-merge で 4 件の runtime issue を発見**。

これは **subagent-driven-development の review は code-level oversight に有効、runtime issue は別 cycle (= post-flight check) で発見される** という Sub-project 2 L8 の再確認。

**対処:**

- subagent-driven-development の two-stage review は継続 (= code-level oversight 効果は明確)
- **post-flight check の確実性向上** が次の優先課題:
  - 本 sub-project では Sub-project 2 L4 (= pre-flight / post-flight 分割) で post-flight 13 項目を spec に明示したが、実際の deploy 時に 1 件ずつ手動で確認した。**自動化** が次のステップ
  - production cluster の Pod state を CI/CD で gate にする automated smoke test の検討 (= 全 Pod が `Running` になるまで CI が pass しない仕組み、Argo CD Health check 連携 等)
  - Sub-project 4 / 5 では post-flight check を **時系列 alert** として組み込む (= merge 後 N 分以内に target Pods 全件 Ready のチェックを Prometheus alert として実装)

### L9: 公式 docs の事実関係調査を brainstorming に組み込む

本 sub-project の brainstorming 段階で、Loki chart の `grafana/loki` v7.0.0 → `grafana-community/loki` への organizational migration を web 検索で発見した (= Decision 5、Sub-project 2 L1 適用)。これと同種の調査を **IAM template 設計時にも実施すべきだった**。

具体的には、Sub-project 1 brainstorming で IAM 3-statement structure を設計した時、**Loki / Tempo / Mimir の公式 IAM template を direct citation で確認しなかった**。私の判断で env-scoped IAM を採用、これが本 sub-project で表面化。

**対処:**

- spec brainstorming 時の checklist に **「主要 application / chart の公式 docs (= IAM template / config schema 等の reference) を web 検索で direct citation する」** を追加
- 公式 docs の引用は spec の Decisions section に URL 付きで記録
- 私の独自設計 (= 公式と乖離する判断) を spec に書く場合は、その理由を明示
- memory file `mimir-mode-knowledge.md` の作成と同様に、各 stack の公式 position memory を作る慣習 (= Loki / Tempo / Fluent Bit / OTel Collector 等)

### L10: Phase 3 全体の runtime fix 件数 = 9 件 (Sub-project 2 で 5 件 + Sub-project 3 で 4 件)、Phase 4 以降の改善材料

Phase 3 で発生した runtime issue:

| sub-project | runtime issue 数 | 主要 root causes |
|---|---|---|
| Sub-project 1 | 0 件 | (verification は code review のみ、AWS-side で deploy / cluster 影響なし) |
| Sub-project 2 (Mimir) | 5 件 | gp3 StorageClass / Mimir 3.x schema / TSDB validator / Grafana datasource / Multi-Attach |
| Sub-project 3 (Loki) | 4 件 | Loki 3.x config validator / Loki compactor 固定 path + IAM mismatch / Fluent Bit probe / (関連 IAM design retrospective) |
| **合計 9 件** | runtime issue が **post-merge cycle で発見された** | brainstorming / planning では予防困難な性質 |

→ **post-flight check の自動化** + **公式 docs 事実関係調査** + **Flux suspend pattern の確立** で次 sub-project (Sub-project 4) は runtime issue 数を減らす目標。

ただし **完璧な spec / plan を目指すのではなく**、 rapid iteration の loop を高速・安全に回せる infrastructure (= Flux suspend pattern + post-flight verification + learnings 共有) に投資する方が ROI が高い、という Sub-project 2 L8 の meta lesson は引き続き valid。
