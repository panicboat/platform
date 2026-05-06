# EKS Production: Observability Traces Stack Foundation (Phase 3 Sub-project 4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** panicboat EKS production cluster に traces collection 基盤を deploy。`grafana/tempo` v1.24.4 (Monolithic mode、Tempo 2.9.0) + `opentelemetry/opentelemetry-collector` v0.153.0 を `monitoring` namespace に deploy。Sub-project 1 で provision 済 + Sub-project 3 fix で bucket-wide IAM 適用済の AWS infra を活用、Sub-project 2 / 3 で確立した monitoring namespace + ServiceMonitor pattern + Grafana datasource 統合 path に従う。本 sub-project (4a) 完了時は traces pipeline 基盤が ready、Sub-project 4b で sources (Beyla / Hubble / Fluent Bit) を接続して data flow 成立。

**Architecture:** Tempo Monolithic StatefulSet で S3 backend (`tempo-559744160976`) に Pod Identity 経由でアクセス。OTel Collector Deployment で OTLP receivers + Tempo exporter のみの **traces pipeline** を 4a で完成、metrics / logs pipelines は 4b で追加。Mimir / Loki / Tempo 3 stack で application retention OFF + S3 lifecycle 担保 + bucket-wide IAM + application-level prefix env scope の panicboat pattern が完全に揃う。

**Tech Stack:** Helm + helmfile / `grafana/tempo` v1.24.4 (Tempo 2.9.0) / `opentelemetry/opentelemetry-collector` v0.153.0 (= contrib 0.151.0) / EBS gp3 PVC / EKS Pod Identity / S3 backend (Sub-project 1 outputs)

**Spec:** `docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md`

---

## File Structure

新規作成 / 変更ファイル:

**Kubernetes 新規 (tempo/production):**
```
kubernetes/components/tempo/production/
├── helmfile.yaml                      # grafana/tempo chart v1.24.4
└── values.yaml.gotmpl                 # Monolithic mode + S3 backend + Pod Identity
```

**Kubernetes 新規 (opentelemetry-collector/production):**
```
kubernetes/components/opentelemetry-collector/production/
├── helmfile.yaml                      # opentelemetry/opentelemetry-collector chart v0.153.0
└── values.yaml.gotmpl                 # Deployment mode + traces pipeline (= 4a 範囲)
```

**Kubernetes 変更 (production):**
```
kubernetes/helmfile.yaml.gotmpl                                        # production env values block に tempo cross-stack values 追加
kubernetes/components/prometheus-operator/production/values.yaml.gotmpl   # Grafana datasources に Tempo entry 追加
kubernetes/manifests/production/kustomization.yaml                     # ./tempo + ./opentelemetry-collector を resources に追加 (auto-insert)
kubernetes/manifests/production/prometheus-operator/manifest.yaml      # 再 hydrate (= datasources Secret 反映)
```

**Kubernetes 自動生成 (production hydrate output):**
```
kubernetes/manifests/production/tempo/{kustomization.yaml, manifest.yaml}
kubernetes/manifests/production/opentelemetry-collector/{kustomization.yaml, manifest.yaml}
```

**変更しないファイル**: aws/eks-traces/* / kubernetes/components/*/local/* / kubernetes/README.md / kubernetes/components/{beyla,opentelemetry,fluent-bit,cilium}/production/

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つのみ ahead (= `0f5ae57 docs(eks): Phase 3 Sub-project 4a (Traces foundation) design spec`)

- [ ] **Step 2: aws/eks-traces/ resource 存在確認 (terragrunt state)**

```bash
cd aws/eks-traces/envs/production
TG_TF_PATH=tofu terragrunt state list 2>&1 | tee /tmp/eks-traces-state.txt
```

Expected: 8 resources
```
aws_eks_pod_identity_association.this
aws_iam_role.pod_identity
aws_iam_role_policy.s3_access
module.s3.aws_s3_bucket.this[0]
module.s3.aws_s3_bucket_lifecycle_configuration.this[0]
module.s3.aws_s3_bucket_public_access_block.this[0]
module.s3.aws_s3_bucket_server_side_encryption_configuration.this[0]
module.s3.aws_s3_bucket_versioning.this[0]
```

- [ ] **Step 3: S3 bucket actual existence + lifecycle (base role)**

```bash
zsh -ic 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws s3api head-bucket --bucket tempo-559744160976
aws s3api get-bucket-location --bucket tempo-559744160976
aws s3api get-bucket-lifecycle-configuration --bucket tempo-559744160976 --query "Rules[*].Expiration.Days"'
```

Expected: 200 OK + `LocationConstraint: ap-northeast-1` + `[7]` (= 7d retention)

- [ ] **Step 4: Pod Identity Association 確認 (base role)**

```bash
zsh -ic 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1 \
  --query "associations[?serviceAccount==\`tempo\`]"'
```

Expected:
```json
[
    {
        "namespace": "monitoring",
        "serviceAccount": "tempo",
        "associationArn": "arn:aws:eks:ap-northeast-1:559744160976:podidentityassociation/eks-production/a-...",
        "associationId": "a-..."
    }
]
```

- [ ] **Step 5: IAM bucket-wide 確認 (Sub-project 3 fix 反映)**

```bash
zsh -ic 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws iam get-role-policy --role-name eks-production-tempo --policy-name s3-access \
  --query "PolicyDocument.Statement[?Sid==\`ObjectLevelOperations\`].Resource"'
```

Expected: `["arn:aws:s3:::tempo-559744160976/*"]` (= bucket-wide、Sub-project 3 fix で `${bucket}/${env}/*` から拡張済)

- [ ] **Step 6: Cluster state 確認 (kubectl context)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- gp3 StorageClass ---"
kubectl get storageclass gp3
echo ""
echo "--- Sub-project 2 / 3 stack 稼働状態 ---"
kubectl get pods -n monitoring | grep -E "prometheus|alertmanager|grafana|mimir|loki|fluent-bit"'
```

Expected:
- `gp3` StorageClass exists (provisioner: `ebs.csi.aws.com`)
- monitoring ns に Prometheus / Alertmanager / Grafana / Mimir / Loki / Fluent Bit 全 component が `Running`

- [ ] **Step 7: Flux state 確認 (suspended でないこと)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux get kustomizations 2>&1'
```

Expected: `flux-system` `SUSPENDED=False`、`READY=True`、`Applied revision: main@sha1:e2df912` (= 直近 main = Sub-project 3 learnings PR #293 merge 済) もしくはそれ以降の commit

---

## Task 1: production Tempo component (`kubernetes/components/tempo/production/`)

**Files:**
- Create: `kubernetes/components/tempo/production/helmfile.yaml`
- Create: `kubernetes/components/tempo/production/values.yaml.gotmpl`

**Context:** Sub-project 2 (mimir/production) / Sub-project 3 (loki/production) と同形 pattern を踏襲。Tempo Monolithic mode + S3 backend (`tempo-559744160976`) + Pod Identity (`tempo` SA) + ServiceMonitor enable + 7d retention は S3 lifecycle で担保 (application retention OFF)。

### Step 1: helmfile.yaml を作成

```yaml
# =============================================================================
# Tempo Helmfile for production
# =============================================================================
# Phase 3 Sub-project 4a で deploy する Traces stack の Tempo 本体。
# Monolithic mode (= chart 内蔵の single binary deploy、distributor + ingester +
# querier + compactor を 1 process に統合、small production OK の Tempo 公式
# position に準拠)。S3 backend は Sub-project 1 で provision 済の
# tempo-559744160976 を Pod Identity 経由でアクセス。
#
# Decision references:
# - D3: Monolithic mode (HA upgrade path 保持、Phase 4 で grafana/tempo-distributed への切替検討)
# - D5: application retention OFF (chart default)、S3 lifecycle 7d で担保
# - D7: bucket-wide IAM (Sub-project 3 fix で 3 stack 同型済) + application-level
#       prefix env scope (s3.prefix: production)
# - D8: multitenancy OFF (1 tenant 運用、Mimir / Loki と対称)
# - D12: PVC 10Gi gp3 (WAL + 短期 compactor cache)
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と
    # 同期すること (tempo.bucketName / tempo.bucketPathPrefix)。
    values:
      - tempo:
          bucketName: tempo-559744160976
          bucketPathPrefix: production
---
repositories:
  - name: grafana
    url: https://grafana.github.io/helm-charts

releases:
  - name: tempo
    namespace: monitoring
    chart: grafana/tempo
    version: "1.24.4"
    values:
      - values.yaml.gotmpl
```

### Step 2: values.yaml.gotmpl を作成

```yaml
# Tempo Configuration for production
# Monolithic mode + S3 backend (Sub-project 1 outputs) + Pod Identity (tempo SA)

# =============================================================================
# Tempo Core Configuration
# =============================================================================
tempo:
  # 1 tenant 運用 (panicboat) のため multitenancy OFF (Decision 8)
  multitenancyEnabled: false

  # -------------------------------------------------------------------------
  # Resources (small production)
  # -------------------------------------------------------------------------
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 2Gi

  # -------------------------------------------------------------------------
  # Storage Config (S3 backend, Sub-project 1 outputs)
  # -------------------------------------------------------------------------
  storage:
    trace:
      backend: s3
      s3:
        bucket: {{ .Values.tempo.bucketName }}
        endpoint: s3.ap-northeast-1.amazonaws.com
        # application-level env scope (= Sub-project 3 L2 適用、IAM bucket-wide と整合)
        prefix: {{ .Values.tempo.bucketPathPrefix }}
        # AWS S3 native (HTTPS) = insecure: false (default)
        # Pod Identity 経由のため access_key / secret_key 不要

  # -------------------------------------------------------------------------
  # Receivers (= 4b で OTel Collector からの OTLP 受信用、4a では未接続)
  # -------------------------------------------------------------------------
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  # -------------------------------------------------------------------------
  # Retention 機能は OFF (= chart default に任せる、Decision 5)
  # -------------------------------------------------------------------------
  # NOTE: 3 stack で application retention は OFF + S3 lifecycle で uniform 担保
  # の panicboat pattern (Sub-project 3 L4 適用)。Tempo 内 retention 機能は
  # per-tenant rules 等の advanced feature 用、panicboat の uniform 7d retention
  # は aws/eks-traces/ S3 lifecycle で担保。

  # -------------------------------------------------------------------------
  # Metrics generator は OFF (= advanced features、Phase 4 で再検討)
  # -------------------------------------------------------------------------
  metricsGenerator:
    enabled: false

# =============================================================================
# ServiceAccount (Pod Identity for S3 access)
# =============================================================================
serviceAccount:
  create: true
  # aws/eks-traces/ で provision 済の Pod Identity Association が
  # monitoring/tempo SA を IAM role eks-production-tempo に紐付け済
  name: tempo
  # Pod Identity は IRSA と異なり annotation 不要 (cluster-side で managed)
  annotations: {}

# =============================================================================
# Persistence (= WAL + 短期 compactor cache、Decision 12)
# =============================================================================
persistence:
  enabled: true
  storageClassName: gp3
  size: 10Gi
  accessModes:
    - ReadWriteOnce

# =============================================================================
# Service Configuration
# =============================================================================
service:
  type: ClusterIP

# =============================================================================
# ServiceMonitor (Prometheus auto-scrape, Decision 9)
# =============================================================================
# NOTE: chart の serviceMonitor key 名は `additionalLabels` (Tempo chart 固有)。
# OTel Collector chart の `extraLabels` とは別 key 名なので注意 (Sub-project 3 L3
# = chart probe / serviceMonitor key 確認の実装段階精査の結果)。
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kube-prometheus-stack
  interval: 15s
```

### Step 3: helmfile template で render verify

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation/kubernetes
make hydrate-component COMPONENT=tempo ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/tempo/manifest.yaml` が新規生成される
- 中身に以下が含まれる:
  - `kind: StatefulSet` (tempo)
  - `kind: Service` (tempo)
  - `kind: ServiceMonitor` (Prometheus auto-scrape) — local の CRD 不在で skip される可能性あり、production deploy 時には正常生成
  - `kind: ServiceAccount` (name: tempo)
  - `bucket: tempo-559744160976` (storage.trace.s3)
  - `prefix: production` (storage.trace.s3)
  - `multitenancy_enabled: false` (Tempo runtime config)
  - `storageClassName: gp3`

確認:
```bash
grep -E "kind:|bucket:|prefix:|multitenancy_enabled|storageClassName" kubernetes/manifests/production/tempo/manifest.yaml | head -20
```

### Step 4: Commit

```bash
git add kubernetes/components/tempo/production/
git commit -s -m "feat(eks): add production Tempo (Monolithic + S3 + Pod Identity)

Phase 3 Sub-project 4a で deploy する Traces stack の Tempo 本体。
grafana/tempo v1.24.4 (Tempo 2.9.0) chart の Monolithic mode で 1 StatefulSet
構成、Pod Identity (tempo SA) 経由で S3 (tempo-559744160976) backend に
アクセス。

主要設定:
- multitenancyEnabled: false (1 tenant 運用、Decision 8)
- storage.trace.backend: s3 + s3.prefix: production (= application-level
  env scope、Sub-project 3 L2 適用、IAM bucket-wide と整合)
- application retention は OFF (chart default、Decision 5)、S3 lifecycle 7d
  で uniform 担保 = 3 stack 一貫 pattern (Mimir/Loki/Tempo)
- metricsGenerator: false (advanced features、Phase 4 で再検討)
- ServiceMonitor enabled with additionalLabels: release: kube-prometheus-stack
  (Tempo chart 固有 key、Sub-project 3 L3 で chart 別 key 名確認済)
- gp3 PVC 10Gi (Sub-project 2 で provision 済 StorageClass 再利用)

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md
      Decision 3 / 5 / 7 / 8 / 9 / 12"
```

`echo -n "feat(eks): add production Tempo (Monolithic + S3 + Pod Identity)" | wc -m` で文字数確認 (= 概ね 65 chars、≤ 72 OK)。

---

## Task 2: production OTel Collector component (`kubernetes/components/opentelemetry-collector/production/`)

**Files:**
- Create: `kubernetes/components/opentelemetry-collector/production/helmfile.yaml`
- Create: `kubernetes/components/opentelemetry-collector/production/values.yaml.gotmpl`

**Context:** OTel Collector Deployment mode + 4a では traces pipeline のみ (= receivers OTLP + Tempo exporter)。chart default の logs / metrics pipelines は active のまま放置 (= 4b で source 接続、4a では effective に inactive)。Sub-project 3 L3 適用で chart-specific key 名 (`extraLabels` for serviceMonitor、`ports.metrics.enabled: true` 必須) を実装段階で精査。

### Step 1: helmfile.yaml を作成

```yaml
# =============================================================================
# OpenTelemetry Collector Helmfile for production
# =============================================================================
# Phase 3 Sub-project 4a で deploy する Traces stack の OTel Collector。
# Deployment mode で 1 replica の集約 hub として deploy。4a では OTLP receivers
# + Tempo exporter のみの traces pipeline を完成、metrics / logs pipelines は
# 4b で sources (Beyla / Hubble / Fluent Bit) 接続と同時に追加。
#
# Decision references:
# - D2: OpenTelemetry Operator は production deploy しない (YAGNI)
# - D4: Deployment + replicas=1 (集約 hub、HA upgrade path 保持)
# - D6: chart version v0.153.0 (= local 揃い、最新と一致)
# - D11: 4a では traces pipeline のみ scope、metrics / logs は 4b で追加
# =============================================================================
environments:
  production:
---
repositories:
  - name: opentelemetry
    url: https://open-telemetry.github.io/opentelemetry-helm-charts

releases:
  - name: opentelemetry-collector
    namespace: monitoring
    chart: opentelemetry/opentelemetry-collector
    version: "0.153.0"
    values:
      - values.yaml.gotmpl
```

### Step 2: values.yaml.gotmpl を作成

```yaml
# OpenTelemetry Collector Configuration for production
# Deployment mode + 4a では traces pipeline only (Decision 11、metrics/logs は 4b で追加)

# =============================================================================
# Deployment Mode (Decision 4)
# =============================================================================
mode: deployment
replicaCount: 1

# =============================================================================
# Image (contrib for k8sattributes processor 等の拡張機能、4b で利用)
# =============================================================================
image:
  repository: otel/opentelemetry-collector-contrib
  tag: 0.151.0

# =============================================================================
# Resources (small production)
# =============================================================================
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 1Gi

# =============================================================================
# Service Configuration
# =============================================================================
service:
  type: ClusterIP

# =============================================================================
# Ports (= metrics port を必ず enable、ServiceMonitor 用)
# =============================================================================
# NOTE: chart README に明記「The metrics port is disabled by default. However
# you need to enable the port in order to use the ServiceMonitor」。Sub-project 3
# L3 (chart probe / port enable 設定の実装段階精査) を適用、明示的に enable する。
ports:
  metrics:
    enabled: true
    containerPort: 8888
    servicePort: 8888
    protocol: TCP

# =============================================================================
# ServiceMonitor (Prometheus auto-scrape, Decision 9)
# =============================================================================
# NOTE: chart の serviceMonitor key 名は `extraLabels` (OTel Collector chart 固有)。
# Tempo chart の `additionalLabels`、fluent-bit chart の `selector` とは別 key
# 名なので注意 (Sub-project 3 L3 = chart 固有 key 確認の実装段階精査の結果)。
serviceMonitor:
  enabled: true
  extraLabels:
    release: kube-prometheus-stack
  metricsEndpoints:
    - port: metrics
      interval: 15s

# =============================================================================
# Collector Config (4a 範囲 = traces pipeline のみ override、Decision 11)
# =============================================================================
# NOTE: chart default で logs / metrics pipelines も pre-configure されるが、
# 4a では source 未接続 (= 4b で wire up 予定) のため effective に inactive。
# 4b で metrics / logs sources (Hubble / Beyla / Fluent Bit) を接続するときに
# pipelines を実利用化する。本 4a で override するのは:
#   1. exporters: otlp/tempo を追加 (= traces を Tempo に export)
#   2. service.pipelines.traces: chart default の exporters [debug] を
#      [otlp/tempo] に上書き
config:
  exporters:
    # 4a で追加: Tempo exporter (4b で metrics / logs exporters 追加予定)
    otlp/tempo:
      endpoint: tempo.monitoring.svc.cluster.local:4317
      tls:
        insecure: true
  service:
    pipelines:
      traces:
        # chart default の exporters: [debug] を override、Tempo に export
        exporters:
          - otlp/tempo
        # processors / receivers は chart default を継承 (= memory_limiter + batch / otlp)
        processors:
          - memory_limiter
          - batch
        receivers:
          - otlp
```

### Step 3: helmfile template で render verify

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation/kubernetes
make hydrate-component COMPONENT=opentelemetry-collector ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/opentelemetry-collector/manifest.yaml` が新規生成される
- 中身に以下が含まれる:
  - `kind: Deployment` (opentelemetry-collector)
  - `kind: Service` (opentelemetry-collector + opentelemetry-collector-monitoring)
  - `kind: ConfigMap` (opentelemetry-collector の config)
  - `kind: ServiceMonitor` (Prometheus auto-scrape) — local の CRD 不在で skip される可能性あり
  - `kind: ServiceAccount` (default name)
  - ConfigMap 内 config に `otlp/tempo` exporter + `tempo.monitoring.svc.cluster.local:4317` endpoint
  - ConfigMap 内 service.pipelines.traces に `exporters: [otlp/tempo]`
  - service の `metrics` port (= 8888) が expose されている

確認:
```bash
grep -E "kind:|otlp/tempo|tempo.monitoring|port: 8888|metrics" kubernetes/manifests/production/opentelemetry-collector/manifest.yaml | head -15
```

### Step 4: Commit

```bash
git add kubernetes/components/opentelemetry-collector/production/
git commit -s -m "feat(eks): add production OTel Collector (Deployment + traces pipeline)

Phase 3 Sub-project 4a で deploy する Traces stack の集約 hub。
opentelemetry/opentelemetry-collector v0.153.0 (= contrib 0.151.0) chart の
Deployment mode で 1 replica、OTLP receivers (gRPC + HTTP) + Tempo exporter
の traces pipeline を 4a で完成。metrics / logs pipelines は 4b で source
接続と同時に追加 (Decision 11)。

主要設定:
- mode: deployment (Decision 4、集約 hub)
- replicaCount: 1 (small production、HA upgrade path 保持)
- image: contrib (= k8sattributes processor 等の拡張機能、4b で利用)
- ports.metrics.enabled: true (ServiceMonitor 用、chart README に明記の必須設定)
- serviceMonitor.extraLabels.release: kube-prometheus-stack (chart 固有 key、
  Sub-project 3 L3 で chart 別 key 名確認済)
- config.exporters.otlp/tempo: tempo.monitoring.svc.cluster.local:4317
- config.service.pipelines.traces.exporters: [otlp/tempo] (chart default の
  [debug] を override)

chart default の logs / metrics pipelines は active のまま放置 (= 4b で
source 接続予定、4a では effective に inactive、debug exporter で stdout
に何も流れない)。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md
      Decision 2 / 4 / 6 / 9 / 11"
```

`echo -n "feat(eks): add production OTel Collector (Deployment + traces pipeline)" | wc -m` で文字数確認 (= 概ね 70 chars、≤ 72 OK)。

---

## Task 3: Cross-stack values + Grafana datasource update

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl`

**Context:** Plan 1c-β L4 pattern (= placeholder 不採用、直接実値書き) を踏襲。Grafana datasource は Sub-project 2 / 3 で確立した pattern (= `datasources.yaml` に追加)、default は Mimir 維持 (Decision 10)。

### Step 1: kubernetes/helmfile.yaml.gotmpl の production env values block に tempo cross-stack values を追加

現状の関連箇所を確認:
```bash
grep -n -B 2 -A 30 "production:" kubernetes/helmfile.yaml.gotmpl | head -50
```

production env block の `loki:` 直下に同形の `tempo:` block を追加 (alphabetical ではなく既存 mimir / loki の順序で後ろに、Sub-project 3 で確立した pattern):

`kubernetes/helmfile.yaml.gotmpl` の production env values block 内、`loki:` block の終端 (`podIdentityRoleName: eks-production-loki`) の **直後** に以下を挿入:

```yaml
        tempo:
          # Source: aws/eks-traces/envs/production terragrunt output
          bucketName: tempo-559744160976
          bucketPathPrefix: production
          podIdentityRoleName: eks-production-tempo
```

確認 (実装後):
```bash
grep -A 4 "tempo:" kubernetes/helmfile.yaml.gotmpl
```

Expected: `bucketName: tempo-559744160976` + `bucketPathPrefix: production` + `podIdentityRoleName: eks-production-tempo`

### Step 2: kubernetes/components/prometheus-operator/production/values.yaml.gotmpl で Grafana datasource に Tempo entry を追加

現状の `grafana.datasources.datasources.yaml.datasources` block を確認:
```bash
grep -n -B 2 -A 50 "datasources:" kubernetes/components/prometheus-operator/production/values.yaml.gotmpl | head -60
```

`Loki` entry の **後ろ** に Tempo entry を追加 (Mimir = default 維持、Tempo = `isDefault: false`、Decision 10):

`Loki` entry の最後 (`secureJsonData.httpHeaderValue1: anonymous` 行) の **直後** に以下を挿入:

```yaml
        # Phase 3 Sub-project 4a (Traces stack foundation)
        - name: Tempo
          uid: tempo
          type: tempo
          url: http://tempo.monitoring.svc.cluster.local:3200
          access: proxy
          isDefault: false
          jsonData:
            # 1 tenant 運用 (= Decision 8、multitenancy OFF)
            httpMethod: GET
            tracesToLogsV2:
              datasourceUid: loki
            tracesToMetrics:
              datasourceUid: mimir
```

加えて、section header コメントを更新 (= Sub-project 3 で `# Data Sources (Mimir primary、Prometheus local secondary、Loki logs)` とした箇所):

```yaml
  # -------------------------------------------------------------------------
  # Data Sources (Mimir primary、Prometheus local secondary、Loki logs、Tempo traces)
  # -------------------------------------------------------------------------
```

確認:
```bash
grep -B 1 -A 12 "name: Tempo" kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
```

Expected: 上記 Tempo entry 全体が返る。

### Step 3: Re-hydrate prometheus-operator manifest

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation/kubernetes
make hydrate-component COMPONENT=prometheus-operator ENV=production
```

Expected:
- error なく完了
- `kubernetes/manifests/production/prometheus-operator/manifest.yaml` の Grafana datasources Secret (= `kube-prometheus-stack-grafana` Secret) で `name: Tempo` entry が含まれる diff

確認:
```bash
git diff kubernetes/manifests/production/prometheus-operator/manifest.yaml | head -40
```

Expected: `name: Tempo` / `type: tempo` / `url: http://tempo.monitoring.svc.cluster.local:3200` の追加 diff が含まれる。

### Step 4: Commit

```bash
git add kubernetes/helmfile.yaml.gotmpl \
        kubernetes/components/prometheus-operator/production/values.yaml.gotmpl \
        kubernetes/manifests/production/prometheus-operator/manifest.yaml
git commit -s -m "feat(eks): add Tempo cross-stack values + Grafana datasource

Phase 3 Sub-project 4a Task 3: Tempo integration の cross-stack 連携。

1. kubernetes/helmfile.yaml.gotmpl
   production env values block に tempo: bucketName / bucketPathPrefix /
   podIdentityRoleName を追加 (Sub-project 1 outputs と整合、Plan 1c-β L4
   pattern で直接実値書き)。

2. kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
   grafana.datasources.datasources.yaml.datasources に Tempo entry 追加。
   Mimir = default 維持 (Decision 10)、Tempo = isDefault: false。
   tracesToLogs / tracesToMetrics で Loki / Mimir との correlation を設定。

3. prometheus-operator manifest を再 hydrate、datasources Secret 反映。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md
      Decision 9 / 10"
```

`echo -n "feat(eks): add Tempo cross-stack values + Grafana datasource" | wc -m` で文字数確認 (= 60 chars、≤ 72 OK)。

---

## Task 4: Hydrate manifests + kustomization update

**Files:**
- Auto-generate: `kubernetes/manifests/production/tempo/{kustomization.yaml, manifest.yaml}`
- Auto-generate: `kubernetes/manifests/production/opentelemetry-collector/{kustomization.yaml, manifest.yaml}`
- Modify: `kubernetes/manifests/production/kustomization.yaml`

**Context:** Sub-project 3 で確認した `make hydrate-index` の auto-insert 挙動で、`kustomization.yaml` に `./tempo` + `./opentelemetry-collector` が alphabetical 位置に追加される。

### Step 1: hydrate-index で manifests/production/ を再生成 + cleanup

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation/kubernetes
make hydrate-index ENV=production
```

Expected:
- `kubernetes/manifests/production/tempo/kustomization.yaml` が新規作成される (`resources: [manifest.yaml]`)
- `kubernetes/manifests/production/opentelemetry-collector/kustomization.yaml` が新規作成される
- 既存の tempo / opentelemetry-collector manifest.yaml も再生成
- `kubernetes/manifests/production/kustomization.yaml` の resources に `./tempo` + `./opentelemetry-collector` が auto-insert される

確認:
```bash
ls kubernetes/manifests/production/tempo/
ls kubernetes/manifests/production/opentelemetry-collector/
cat kubernetes/manifests/production/kustomization.yaml
```

Expected (`kubernetes/manifests/production/kustomization.yaml`):
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
  - ./opentelemetry-collector  # ← 4a で auto-insert (alphabetical: mimir < opentelemetry-collector < prometheus-operator)
  - ./prometheus-operator
  - ./storage-class
  - ./tempo                    # ← 4a で auto-insert (alphabetical: storage-class < tempo)
```

15 entries (= 13 既存 + ./tempo + ./opentelemetry-collector の 2 件追加)。

### Step 2: kustomize build で全体 manifest を render verify

```bash
kubectl kustomize kubernetes/manifests/production/ > /tmp/production-rendered.yaml
echo "Total resources: $(grep -c '^kind:' /tmp/production-rendered.yaml)"
echo ""
echo "=== Tempo resources (kind 別) ==="
grep -B 1 "name: tempo$\|name: tempo-" /tmp/production-rendered.yaml | grep "kind:" | sort | uniq -c
echo ""
echo "=== OTel Collector resources (kind 別) ==="
grep -B 1 "name: opentelemetry-collector" /tmp/production-rendered.yaml | grep "kind:" | sort | uniq -c
echo ""
echo "=== Tempo datasource entry in Grafana Secret ==="
grep -A 5 "name: Tempo" /tmp/production-rendered.yaml | head -8
```

Expected:
- error なく完了
- Tempo resource: StatefulSet 1 + Service 数件 + ServiceAccount 1 + ConfigMap 1
- OTel Collector resource: Deployment 1 + Service 1 + ServiceAccount 1 + ConfigMap 1
- Grafana datasources Secret に `name: Tempo` entry 含む

### Step 3: Commit

```bash
git add kubernetes/manifests/production/tempo/ \
        kubernetes/manifests/production/opentelemetry-collector/ \
        kubernetes/manifests/production/kustomization.yaml
git commit -s -m "chore(kubernetes/manifests): hydrate tempo + opentelemetry-collector

Phase 3 Sub-project 4a Task 4: hydrate-index で全 component 再 hydrate、
kustomization.yaml の resources list に ./tempo + ./opentelemetry-collector
を alphabetical 位置に auto-insert (Sub-project 3 で確認した make hydrate-index
の挙動)。

manifest.yaml は components/{tempo,opentelemetry-collector}/production/ の
helmfile.yaml + values.yaml.gotmpl から auto-generated。

Refs: docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md"
```

`echo -n "chore(kubernetes/manifests): hydrate tempo + opentelemetry-collector" | wc -m` で文字数確認 (= 67 chars、≤ 72 OK)。

---

## Task 5: PR push + Pre-flight check + Ready for review

**Files:** (= no file changes、PR 操作のみ)

**Context:** Sub-project 3 L4 learnings 適用。Pre-flight check 全件 ✅ を PR description に記録してから Ready for review に切替。

### Step 1: branch 状態を確認

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-observability-traces-stack-foundation
git log --oneline origin/main..HEAD
```

Expected: 5 commits ahead (Task 1 から Task 4 まで + spec commit)
```
<sha> chore(kubernetes/manifests): hydrate tempo + opentelemetry-collector
<sha> feat(eks): add Tempo cross-stack values + Grafana datasource
<sha> feat(eks): add production OTel Collector (Deployment + traces pipeline)
<sha> feat(eks): add production Tempo (Monolithic + S3 + Pod Identity)
<sha> docs(eks): Phase 3 Sub-project 4a (Traces foundation) design spec
```

### Step 2: branch を origin に push

```bash
git push 2>&1 | tail -3
```

Expected: branch が track 設定済 (Sub-project 4a の spec commit で `git push -u origin HEAD` 済の前提)

### Step 3: Draft PR を作成 (Pre-flight check 結果を含む)

PR title (≤ 72 chars 確認):
```bash
echo -n "feat(eks): Phase 3 Sub-project 4a — Traces foundation (Tempo + OTel)" | wc -m
```

Expected: 70 chars (em dash 含む、visible ≈ 67 chars、Sub-project 2 / 3 の PR title 命名 pattern と整合)

PR body は以下:

```markdown
## Summary

Phase 3 Sub-project 4a (Traces stack foundation) の implementation。`grafana/tempo` v1.24.4 (Monolithic mode、Tempo 2.9.0) + `opentelemetry/opentelemetry-collector` v0.153.0 を `monitoring` namespace に deploy。Sub-project 1 で provision 済の AWS infra (`tempo-559744160976` bucket + `eks-production-tempo` IAM role + `tempo` Pod Identity SA) + Sub-project 3 fix で適用済の bucket-wide IAM を活用、Sub-project 2 / 3 で確立した ServiceMonitor pattern + Grafana datasource 統合 path に従う。

**Architecture (4a 完了時):** Tempo Monolithic StatefulSet で S3 backend に Pod Identity 経由でアクセス。OTel Collector Deployment で OTLP receivers + Tempo exporter のみの **traces pipeline** を完成。**source 未接続** = Beyla / Hubble / Fluent Bit から OTLP push は Sub-project 4b で wire up。

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-06-eks-production-observability-traces-stack-foundation-design.md` (13 Decisions、Sub-project 3 learnings 全項目適用)
- Plan: `docs/superpowers/plans/2026-05-06-eks-production-observability-traces-stack-foundation.md` (6 tasks)

## Notable Decisions

- **D1**: Sub-project 4 を 4a + 4b に分割 (= 4b は別途 brainstorming)
- **D2**: OTel Operator は production deploy しない (YAGNI、Beyla 採用済)
- **D3**: Tempo Monolithic (small production OK、Loki と対称、Mimir Microservices と非対称)
- **D5**: application retention OFF (chart default)、S3 lifecycle 7d で uniform 担保 (= 3 stack 一貫 pattern)
- **D11**: 4a では traces pipeline のみ、metrics / logs は 4b で追加
- **D13**: 3 stack (Mimir / Loki / Tempo) で application retention OFF + S3 lifecycle 担保 + bucket-wide IAM + application-level prefix env scope の panicboat pattern が完全に揃う

## Pre-flight check

- [ ] aws/eks-traces/ terragrunt state 8 resources confirmed (Task 0 Step 2)
- [ ] S3 bucket tempo-559744160976 head-bucket 200 OK + lifecycle 7d (Task 0 Step 3)
- [ ] Pod Identity Association monitoring/tempo exists (Task 0 Step 4)
- [ ] IAM ObjectLevelOperations Resource bucket-wide (Sub-project 3 fix 反映、Task 0 Step 5)
- [ ] gp3 StorageClass exists (Task 0 Step 6)
- [ ] Sub-project 2 / 3 stack all Running (Task 0 Step 6)
- [ ] Flux not suspended (Task 0 Step 7)

## Test plan (post-flight, after merge)

### 10 分以内
- [ ] Tempo `tempo-0` `1/1 Running` (StatefulSet)
- [ ] OTel Collector `1/1 Running` (Deployment)
- [ ] PVC `tempo-tempo-0` Bound (gp3 10Gi)
- [ ] Prometheus targets で `tempo` / `opentelemetry-collector` が `UP`

### 30 分以内
- [ ] Tempo S3 backend ready (= Pod Identity 動作確認、Tempo logs で `s3 backend` 接続成功)
- [ ] OTel Collector startup 成功 (= Tempo gRPC connection established)
- [ ] self-metrics (`tempo_*` / `otelcol_*`) が Mimir に remote_write されて Grafana で query 可能
- [ ] Grafana Tempo datasource `Save & test` で 緑
- [ ] Sub-project 2 / 3 stack regression なし

**注**: 4a では source 未接続のため **actual traces data は流れない**。実 traces 検証は 4b で source 接続後。

## Sub-project 3 learnings 適用

| Sub-project 3 learnings | 本 PR での適用 |
|---|---|
| L1 (chart 内部固定 path 問題) | Tempo は `s3.prefix` で path 制御可能、Loki のような問題なし |
| L2 (IAM 公式準拠) | Sub-project 3 fix で 3 stack 同型済 → そのまま利用、Tempo は `s3.prefix: production` で application-level env scope |
| L3 (chart probe / serviceMonitor key 確認) | Tempo: `additionalLabels` / OTel Collector: `extraLabels` + `ports.metrics.enabled: true` 必須 を実装段階で精査済 |
| L4 (uniform retention は S3 lifecycle で) | Tempo application retention 設定なし、S3 lifecycle 7d で担保 = 3 stack 一貫 pattern |
| L5 (Flux suspend pattern) | 通常 deploy で進める、問題発見時のみ reactive 発動 |
| L6 (Loki `auth_enabled: false` 時 internal default) | Tempo は `multitenancyEnabled: false` で 1 tenant 運用、Mimir / Loki と対称 |
| L7 (sibling stack symmetric) | 3 stack 同型 IAM 維持 (Sub-project 3 fix で適用済) |
| L8 (post-flight check) | 13 項目を Test plan で明示 |
| L9 (公式 docs 引用) | Tempo 公式 IAM template と整合確認済 (Sub-project 3 fix の bucket-wide が公式形式) |
| L10 (Phase 3 全体 9 件 runtime issue) | 本 sub-project は 4a / 4b 分割 + L1-L9 適用で runtime issue 数 minimize 目標 |

## Rollback 手順 (想定外障害時)

```bash
flux suspend kustomization flux-system
kubectl delete -k kubernetes/manifests/production/tempo/
kubectl delete -k kubernetes/manifests/production/opentelemetry-collector/
kubectl get pods -n monitoring | grep -v -E "tempo|opentelemetry-collector"  # Sub-project 2 / 3 影響なき確認
gh pr create --title "revert: Phase 3 Sub-project 4a (Traces stack foundation)" ...
flux reconcile source git flux-system
flux resume kustomization flux-system
```

aws/eks-traces/ は Sub-project 1 で provision 済 + Sub-project 3 fix で IAM 適用済 = AWS-side rollback 不要。
```

```bash
gh pr create --draft \
  --title "feat(eks): Phase 3 Sub-project 4a — Traces foundation (Tempo + OTel)" \
  --body "$(<above body>)"
```

Expected: PR URL 出力 (例: `https://github.com/panicboat/platform/pull/<N>`)

### Step 4: PR URL を確認

```bash
gh pr view --json title,url,isDraft --jq '.'
```

Expected:
```json
{
    "isDraft": true,
    "title": "feat(eks): Phase 3 Sub-project 4a — Traces foundation (Tempo + OTel)",
    "url": "https://github.com/panicboat/platform/pull/<N>"
}
```

(ここで USER GATE: PR review + Ready for review + merge は user 操作)

---

## Self-review

### Spec coverage

| Spec section | 実装 task | カバレッジ |
|---|---|---|
| Architecture (mermaid) | Task 1 / 2 / 3 / 4 | ✅ Tempo + OTel Collector + ServiceMonitor + Grafana datasource すべて Task で網羅 |
| Components table | Task 1 / 2 | ✅ Tempo Monolithic / OTel Collector Deployment / ServiceMonitor / Grafana datasource すべてカバー |
| Data flow (Step 1-4 + side flows) | Task 1 / 2 | ✅ OTel Collector → Tempo → S3 path、Prometheus scrape path を全 step 実装 |
| AWS infra (Sub-project 1 + Sub-project 3 fix 利用) | Task 0 (verify only) | ✅ pre-flight check で existence + IAM bucket-wide 反映確認、変更なし |
| Decision 1 (4a + 4b 分割) | (構成決定、本 plan は 4a 範囲) | ✅ |
| Decision 2 (OTel Operator なし) | (= 本 plan で deploy しない、Operator 関連 task 不在) | ✅ |
| Decision 3 (Tempo Monolithic) | Task 1 (chart: grafana/tempo) | ✅ |
| Decision 4 (OTel Collector Deployment + replicas=1) | Task 2 (mode: deployment + replicaCount: 1) | ✅ |
| Decision 5 (retention OFF + S3 lifecycle) | Task 1 (retention 設定なし、NOTE で意図記録) | ✅ |
| Decision 6 (chart version local 揃え) | Task 1 / 2 (helmfile.yaml chart version) | ✅ |
| Decision 7 (bucket-wide IAM + s3.prefix) | Task 0 (verify) + Task 1 (s3.prefix: production) | ✅ |
| Decision 8 (multitenancy OFF) | Task 1 (multitenancyEnabled: false) | ✅ |
| Decision 9 (ServiceMonitor + Grafana datasource) | Task 1 / 2 (ServiceMonitor) + Task 3 (Grafana datasource) | ✅ |
| Decision 10 (Mimir = default 維持) | Task 3 (Tempo: isDefault: false) | ✅ |
| Decision 11 (4a traces pipeline のみ) | Task 2 (config に exporters/otlp/tempo + service.pipelines.traces 上書き) | ✅ |
| Decision 12 (Tempo PVC 10Gi gp3) | Task 1 (persistence.storageClassName: gp3 + size: 10Gi) | ✅ |
| Decision 13 (3 stack 一貫 pattern) | (= 設計レベルの確認、本 plan の各 task で具体実装、Sub-project 4a 完了時に整合) | ✅ |
| Test plan (pre-flight 7 + post-flight 13) | Task 0 (pre-flight 7) + Task 5 (PR description で post-flight 13 明示) | ✅ |

### Placeholder scan

- [x] "TBD" / "TODO" / "FIXME" 等の placeholder なし
- [x] 各 Step で actual code block (helmfile.yaml / values.yaml.gotmpl / commit message) を完全に書き出し済
- [x] "Similar to Task N" 形式の reference なし

### Type / naming consistency

- [x] SA name `tempo` は Task 1 + Task 0 (pre-flight check) + spec で一貫
- [x] Bucket name `tempo-559744160976` は Task 1 / Task 3 / Task 0 で一貫
- [x] Service name `tempo.monitoring.svc.cluster.local` は Task 2 (OTel Collector exporter endpoint) + Task 3 (Grafana datasource url) で一貫 (port は Tempo 4317 / 3200 で各用途別)
- [x] OTel Collector chart `extraLabels` (= Tempo `additionalLabels` と異なる、Sub-project 3 L3 確認済)
- [x] OTel Collector `ports.metrics.enabled: true` は ServiceMonitor 用、chart README の必須設定 (Task 2 で明示)
- [x] kube-prometheus-stack ServiceMonitor selector label `release: kube-prometheus-stack` は Task 1 (Tempo) + Task 2 (OTel Collector) で一貫

### CLAUDE.md 準拠

- [x] 出力言語日本語 (見出し英語、本文日本語)
- [x] コミット `-s` (Signed-off-by) 全 task の commit step で指定
- [x] `Co-Authored-By` 不付与 (全 commit message に無し)
- [x] PR は `--draft` (Task 5 Step 3)
- [x] Conventional Commits 全 commit が `feat(eks):` / `chore(kubernetes/manifests):` / `docs(eks):` 形式
- [x] commit subject ≤ 72 chars 全 task で wc -m 確認

### Plan 1c-β / Plan 2 / Plan tuning / Sub-project 1-3 の知見反映

- [x] **Plan 1c-β L4 (REPLACE_FROM_TERRAGRUNT_OUTPUT 不要)** → Task 3 で helmfile.yaml.gotmpl に直接実値 (`tempo-559744160976`) を書く、placeholder pattern 不採用
- [x] **Plan 1c-β L5 (squash merge 後 branch reset rollback)** → Task 0 Step 1 で `git fetch origin main && git log --oneline origin/main..HEAD` 確認
- [x] **Sub-project 1 L1 (IAM policy 3 statement)** → 本 sub-project は IAM 触らない (= Sub-project 3 fix で確立済の bucket-wide pattern を verify のみ)
- [x] **Sub-project 1 L5 (sibling stacks symmetric)** → 3 stack の IAM template は同型維持 (Sub-project 3 fix で適用済)、本 plan は K8s-side のみ追加
- [x] **Sub-project 2 L1 (chart upgrade での upstream changelog 確認)** → Tempo + OTel Collector chart の最新 version は local 揃い、organizational migration なしを確認済 (Decision 6)
- [x] **Sub-project 2 L2 (chart auto-generated ConfigMap 衝突)** → Sub-project 2 PR #289 の `defaultDatasourceEnabled: false` 設定継続、新たな衝突なし
- [x] **Sub-project 2 L3 (EBS RWO + RollingUpdate → Recreate)** → Tempo は StatefulSet (OrderedReady)、OTel Collector は Deployment + PVC なし、新規 Recreate 設定不要
- [x] **Sub-project 2 L4 (Spec verification を pre-flight / post-flight 分割)** → Task 0 (pre-flight 7 件) + Task 5 PR description (post-flight 13 件) で明示分離
- [x] **Sub-project 2 L5 (Flux suspend pattern)** → Spec Test plan section に Rollback 手順として明示
- [x] **Sub-project 2 L6 (gp3 StorageClass)** → Sub-project 2 で provision 済再利用、本 sub-project では作らない
- [x] **Sub-project 2 L7 (Pod Identity webhook injection は Pod 作成時のみ)** → 新規 deploy のため初回起動時に正しく injection
- [x] **Sub-project 2 L8 (storage_prefix 英数字制約)** → Tempo `s3.prefix: production` で英数字のみ、slash 不要 = Mimir / Loki と整合
- [x] **Sub-project 3 L1 (chart 内部固定 path 問題)** → Tempo は `s3.prefix` で全 path 制御可能、Loki のような問題なしを確認
- [x] **Sub-project 3 L2 (IAM 公式準拠)** → Sub-project 3 fix で 3 stack bucket-wide IAM 同型済、Tempo はそのまま利用
- [x] **Sub-project 3 L3 (chart probe / serviceMonitor key 確認)** → Tempo `additionalLabels` / OTel Collector `extraLabels` + `ports.metrics.enabled: true` を実装段階で精査済、Task 1 / 2 の values で正しい key を使用
- [x] **Sub-project 3 L4 (uniform retention は S3 lifecycle で)** → Tempo application retention OFF (chart default)、S3 lifecycle 7d で担保
- [x] **Sub-project 3 L5 (Flux suspend pattern)** → Rollback 手順として明示、通常 deploy で進める
- [x] **Sub-project 3 L6 (Loki `auth_enabled: false` 時 default tenant `fake`)** → Tempo は `multitenancyEnabled: false` で 1 tenant 運用、将来 multi-tenant 化時に tenant ID を 3 stack で揃える前提
- [x] **Sub-project 3 L7 (sibling stack symmetric)** → 本 sub-project は Tempo 単独追加、3 stack IAM template は Sub-project 3 fix で同型済
- [x] **Sub-project 3 L8 (post-flight check)** → 13 項目を spec / PR description で明示
- [x] **Sub-project 3 L9 (公式 docs 引用)** → Tempo 公式 docs を spec の Decisions section で direct citation
- [x] **Sub-project 3 L10 (Phase 3 全体 9 件 runtime issue)** → 4a / 4b 分割 + L1-L9 適用で runtime issue 数 minimize 目標
