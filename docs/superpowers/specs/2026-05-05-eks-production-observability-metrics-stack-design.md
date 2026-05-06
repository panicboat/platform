# EKS Production: Observability Metrics Stack Design (Phase 3 Sub-project 2)

## Background

Roadmap (`docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`) の **Phase 3 Observability** を 4 sub-projects に分解したうちの **Sub-project 2 (Metrics stack)**。Sub-project 1 (`docs/superpowers/specs/2026-05-05-eks-production-observability-aws-infra-design.md`) で provision した AWS-side infra を K8s 側 chart で消費し、production 観測スタックの metrics 機能を完成させる。

**重要な design pivot**: 当初 Roadmap spec は "Thanos sidecar + S3 long-term storage" を想定していたが、本 sub-project の brainstorming で **Grafana Mimir** に切り替えた。理由:

1. Bitnami の有償化方針で `bitnami/thanos` chart の long-term sustainability に懸念
2. Mimir は Thanos の概念的後継 (Grafana Labs 公式)、long-term metrics + multi-tenant ready で future-proof
3. S3 backend は Sub-project 1 の resource をそのまま再利用可能 (rename して命名 clean に)

Sub-project 1 で provision した resource 命名 (`thanos-...` bucket / `eks-production-prometheus` IAM role / `monitoring:prometheus` Pod Identity Association SA) は Mimir 採用 design pivot により historical artifact になる。本 sub-project で **Mimir 用に rename** して clean な命名に揃える (data 0 byte で migration cost なし、新規構築フェーズの利点を活用)。

## Goals

### G1: kube-prometheus-stack chart を production env で deploy

local cluster で動作中の kube-prometheus-stack chart (`kubernetes/components/prometheus-operator/local/`) を production env 派生で deploy する。Prometheus が cluster の metrics を scrape し、Mimir に remote write する形。

含む components:
- Prometheus (scrape agent + 短期 retention)
- Alertmanager (alerting hub、Phase 4 で receiver 追加)
- Grafana (visualization、data source は Mimir / Loki / Tempo)
- node-exporter (host metrics)
- kube-state-metrics (K8s API metrics)
- prometheus-operator (CRD 管理、ServiceMonitor / PodMonitor / PrometheusRule)

### G2: Grafana Mimir chart (Microservices mode) を deploy

Mimir Microservices mode (chart default、`grafana/mimir-distributed` v6.0.6 の standard pattern) で long-term metrics storage を提供する。Prometheus が remote write 経由で Mimir nginx gateway → distributor に metrics を送り、ingester が S3 (Sub-project 1 で provision) に flush。長期データは Mimir querier / store-gateway 経由で Grafana から query 可能。

Microservices mode の本 sub-project で deploy する component:

| Component | Workload kind | 役割 |
|---|---|---|
| nginx (gateway) | Deployment | Mimir API HTTP 入口 (Prometheus からの remote write + Grafana からの query 全て nginx 経由) |
| distributor | Deployment | nginx から受信した metrics を ingester に分散 |
| ingester | StatefulSet | recent metrics の memory + WAL + S3 batch flush |
| querier | Deployment | ingester + store-gateway を統合 query |
| query-frontend | Deployment | query 最適化 + cache |
| store-gateway | StatefulSet | S3 から metrics を query 提供 |
| compactor | StatefulSet | S3 内 metric の compaction (cost 削減) |
| memcached (chunks-cache) | StatefulSet | cache (querier の S3 query 高速化) |

**disable する component (= chart values で `enabled: false`)**:

| Component | 理由 |
|---|---|
| alertmanager | kube-prometheus-stack 内蔵 Alertmanager を使用 (D6) |
| ruler | kube-prometheus-stack 内蔵 Prometheus rule で評価 |
| overrides-exporter | multi-tenant 不要 (panicboat 1 tenant) |
| smoke-test / continuous-test | production 不要 (= 動作確認 Job) |

**NOTE:** 当初 `query-scheduler` も disable 対象としていたが、Mimir 3.x では `frontend_worker.frontend_address` が `worker.Config` 構造体から削除されている (= scheduler 経由のみ有効) ため、chart default の `query_scheduler.enabled: true` を採用する (post-merge fix)。

### G3: Grafana data source を Mimir query-frontend に設定

Grafana の primary metrics data source を Mimir query-frontend (Prometheus 互換 endpoint) に設定する。Prometheus 直接 query は localhost (= cluster 内 short-range query 用) で残し、長期データは Mimir 経由で Grafana から見える状態にする。

Loki (Sub-project 3) / Tempo (Sub-project 4) data source は本 sub-project では追加せず、後続 sub-projects で chart values に追加する。

### G4: Sub-project 1 の AWS-side resource を Mimir 用に rename

Sub-project 1 で provision した historical artifact (`thanos-` / `prometheus`) を Mimir 用に clean rename:

| 項目 | 現在 (Sub-project 1) | rename 後 |
|---|---|---|
| bucket 名 | `thanos-559744160976` | `mimir-559744160976` |
| IAM role 名 | `eks-production-prometheus` | `eks-production-mimir` |
| Pod Identity Association SA | `monitoring:prometheus` | `monitoring:mimir` |
| `aws/eks-metrics/` の `local.service_name` | `prometheus` | `mimir` |

terragrunt apply で旧 resource destroy + 新 resource create (data 0 byte で migration cost なし)。

## Non-goals

- Loki / Fluent Bit chart 導入 (Sub-project 3)
- Tempo / OpenTelemetry / Beyla chart 導入 + Hubble OTLP integration (Sub-project 4)
- Grafana 認証 (oauth2-proxy / ALB OIDC) — Phase 4
- Alertmanager receiver 設定 (Slack / SNS / PagerDuty) — Phase 4
- Grafana adminPassword の secret 化 (External Secrets Operator) — Phase 4
- Mimir Microservices mode の各 component 個別 replica scaling — cluster 規模拡大時 (active series 増 / multi-tenant 必要) に各 component で水平 scaling
- Mimir Ruler を使った PrometheusRule の長期評価 — 本 sub-project は kube-prometheus-stack 内蔵 Prometheus の rule 評価で十分
- Grafana Alloy への scrape agent 移行 — Phase 6+ Future Spec
- multi-tenant Mimir 設定 — panicboat 1 tenant のみ想定
- Grafana dashboard JSON の bulk import — 本 sub-project は default dashboards (kube-prometheus-stack chart 同梱) のみ、custom dashboard は Phase 5 / 6 で workload 観測時に追加

## Architecture decisions

### Decision 1: chart 構成 = kube-prometheus-stack + grafana/mimir-distributed の 2 chart 体制

production env では 2 つの helm chart を deploy:

- **kube-prometheus-stack** (prometheus-community/kube-prometheus-stack v84.5.0): Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator を bundle した defacto-standard chart。local で動作確認済の構成を production env 派生で deploy。
- **grafana/mimir-distributed** (Grafana Labs 公式) v6.0.6: Mimir の各 component を Microservices mode で deploy する chart (= chart の default pattern)。本 sub-project で必要な 9 component (nginx / distributor / ingester / querier / query-frontend / query-scheduler / store-gateway / compactor / memcached) を有効化、4 component (alertmanager / ruler / overrides-exporter / smoke-test) を disable する。

両 chart は `monitoring` namespace に集約 (Sub-project 1 で確定済)。

**不採用案**:

- bitnami/thanos chart: Bitnami の有償化方針で long-term sustainability 懸念
- 自前 manifests (helmfile + raw yaml): chart upgrade 自動追従なし、maintenance cost 大
- Grafana Mimir monolithic mode: Grafana 公式 docs で "not recommended for production"

### Decision 2: Mimir deployment mode = Microservices (chart default)

Microservices mode (= `grafana/mimir-distributed` chart v6.0.6 の standard pattern) を採用する。chart は各 component を別 Deployment / StatefulSet で deploy する設計で、本 sub-project では **必要 9 component を有効化、不要 4 component を disable** する。

**根拠**:

- Grafana Mimir chart v6.0.6 では Microservices mode が **chart default**、Read-Write mode は chart レベルで native support なし (= Read-Write mode は Mimir binary レベルの concept で、chart values で実装するなら custom config 必要)
- 公式 docs (2026 年現在) の推奨は "Microservices mode が production standard、any size"。Read-Write mode は deprecation 候補
- panicboat の規模 (small-medium cluster) で各 component 1 replica で start すれば resource overhead 許容範囲
- chart の design intent と一致 (= future-proof、chart upgrade 安全)

**将来の scaling**: active series 増加 / multi-tenant 必要 / HA 強化 等の規模拡大時は、各 component 個別に replica 増やす形で水平 scaling 可能 (= Microservices mode の利点)。

**不採用案**:

- Read-Write mode (chart レベル native support なし、custom config が必要、deprecation 候補): 当初 brainstorming で採用案だったが、chart 実態確認で revisit
- Monolithic mode (chart values で全 component を 1 deployment に集約): chart 標準から外れる、production 公式非推奨

### Decision 3: Mimir Pod Identity = chart-level 1 SA (`monitoring:mimir`)

Mimir chart の標準 pattern は **chart-level 単一 ServiceAccount** で全 component が S3 access を共有する。Sub-project 1 で provision した Pod Identity Association を **rename** して 1 つに集約:

- ServiceAccount: `mimir` (chart values で `serviceAccount.name = "mimir"`)
- Pod Identity Association: `monitoring:mimir` SA → `eks-production-mimir` IAM role に bind

**追加 Pod Identity Association は不要** (= Thanos の場合 Compactor / Query / Store Gateway に別 SA を割り当てる pattern と異なり、Mimir は chart-level 1 SA pattern が standard)。

### Decision 4: AWS-side rename (Sub-project 1 resource を Mimir 用に rename)

Sub-project 1 で provision した resource は Sub-project 2 の brainstorming 段階で Thanos 由来の命名であり、Mimir 採用 design pivot 後に historical artifact になる。新規構築フェーズで data 0 byte の状態を活かし、**clean rename** を実施:

`aws/eks-metrics/modules/main.tf` で:

- `local.bucket_name` を `thanos-${account_id}` から `mimir-${account_id}` に変更
- `local.service_name` を `prometheus` から `mimir` に変更
- IAM role 名は `eks-${var.environment}-${local.service_name}` で展開され `eks-production-mimir` に追従
- Pod Identity Association `service_account` も `local.service_name` で展開され `mimir` に追従
- header / inline comment 内の Thanos / Prometheus 参照を Mimir / kube-prometheus-stack に追従

`aws/eks-metrics/modules/outputs.tf` で:

- `bucket_name` / `bucket_path_prefix` / `pod_identity_role_name` / `pod_identity_role_arn` の output key 名は維持 (= Sub-project 2-4 で consume する interface 不変)
- description の `Thanos` / `prometheus` 参照を `Mimir` / `mimir` に追従

terragrunt apply 動作:

- 旧 bucket `thanos-559744160976` destroy (data 0 byte、安全)
- 新 bucket `mimir-559744160976` create
- 旧 IAM role `eks-production-prometheus` destroy
- 新 IAM role `eks-production-mimir` create
- 旧 Pod Identity Association `monitoring:prometheus` destroy
- 新 Pod Identity Association `monitoring:mimir` create

### Decision 5: Metrics flow = Prometheus scrape → remote write → Mimir → S3 → Grafana query

```
ServiceMonitor / PodMonitor (cluster 内全 namespace)
  ↓ scrape (prometheus.io/scrape: "true" 等)
Prometheus (kube-prometheus-stack 内蔵、namespace=monitoring)
  ↓ remote_write (HTTP POST to Mimir distributor)
Mimir distributor (Write-path)
  ↓ replicate
Mimir ingester (Write-path)
  ↓ flush (batch interval)
S3 bucket `mimir-559744160976/production/` (Sub-project 1 で provision)
  ↑ read
Mimir store-gateway (Read-path)
  ↑ query
Mimir querier (Read-path)
  ↑ query (cache + optimization)
Mimir query-frontend (Read-path)
  ↑ data source URL
Grafana (kube-prometheus-stack 内蔵)
```

Grafana data source 設定で Mimir query-frontend を **Prometheus 互換 endpoint** として登録 (= Mimir API は Prometheus query API と互換、Grafana から見ると Prometheus と同じ)。

Prometheus 自身の TSDB は短期保存 (retention 24h) で local query (= KEDA scaler / Phase 5 HPA 等の latency-sensitive query 用)。長期データは Mimir 経由で Grafana から query 可能。

### Decision 6: Alertmanager 配置 = kube-prometheus-stack 内蔵

kube-prometheus-stack chart 内蔵の Alertmanager を有効 (`alertmanager.enabled: true`、local と同じ)。Mimir 内蔵 Ruler / Alertmanager (multi-tenant) は本 sub-project で採用しない (= over-engineering、本 phase は 1 tenant)。

receiver 設定 (Slack / SNS / PagerDuty / OpsGenie 等) は **Phase 4 で別途追加** (= 通知方式の意思決定が必要、本 sub-project は alerting 機能の wiring のみ)。

### Decision 7: Grafana adminPassword = 暫定 hardcode + TODO

production env でも Grafana adminPassword を `values.yaml.gotmpl` に **暫定 hardcode** で記述 (= local と同じ pattern、`adminPassword: "..."`)。コメントに `# TODO: (Phase 4) External Secrets Operator + AWS Secrets Manager 経由で secret 化` を記載。

**根拠**:

- Phase 4 で External Secrets Operator + AWS Secrets Manager 連携を構築する想定
- 本 sub-project で先に Grafana を deploy する必要があり、その時点で valid な adminPassword が必要
- 短期間の hardcode は acceptable risk (= production access は ALB Ingress + 認証 layer は Phase 4 で追加するため、cluster 内 access のみ可能な状態)

### Decision 8: Pod placement = Karpenter system-components NodePool

全 monitoring namespace の Pod を Karpenter `system-components` NodePool 上で動作させる。chart values で nodeSelector / tolerations 設定:

- 不要: Karpenter `system-components` NodePool は taint 無し (general workload 用)、Karpenter NodeRequirements (`karpenter.k8s.aws/instance-category=m`, `instance-generation Gt 5` 等) で適合する node に provision
- 必要 (オプション): nodeSelector で `node-role/karpenter-system-components` 等の label を指定して affinity を明示

panicboat の現状: Karpenter `system-components` NodePool は taint 無しで、Pod は default で provision される (= 明示的 nodeSelector 不要)。本 spec では nodeSelector / tolerations を chart values で **設定しない** (= Karpenter による自動 provision に任せる)。

将来 monitoring 専用の NodePool (例: `monitoring-components`) を作る場合は別 sub-project で対応。

### Decision 9: PVC sizing (Microservices mode の各 component 個別)

各 component の persistent storage 要件 (StorageClass = gp3 = EKS 既定):

**kube-prometheus-stack 内 PVC:**

| Component | 用途 | size |
|---|---|---|
| Prometheus | TSDB (retention 24h、long-term は Mimir に remote write) | 20 GiB |
| Alertmanager | alert state | 2 GiB |
| Grafana | dashboard / user state (DB は SQLite local) | 5 GiB |

**Mimir Microservices 内 PVC (StatefulSet 持つ component のみ):**

| Component | 用途 | size |
|---|---|---|
| ingester | WAL buffer + recent metrics | 10 GiB |
| store-gateway | S3 chunks/index cache | 20 GiB |
| compactor | S3 metric compaction の temporary storage | 10 GiB |
| memcached (chunks-cache) | cache 永続化 (option、emptyDir でも可) | 5 GiB |

合計: 72 GiB (= 20+2+5 + 10+20+10+5)。EBS gp3 月額 ~$0.08/GiB なので **~$6-7/month**。

(Mimir の Deployment 持つ component (= nginx / distributor / querier / query-frontend) は PVC なし、stateless)

将来 active series が増えた場合、observation で sizing 見直し (= resource adjustments の plan で対応)。

### Decision 10: Resource requests/limits = production-grade (Microservices mode の各 component 個別)

各 component の resource を production-grade に設定:

**kube-prometheus-stack 内:**

| Component | requests CPU | requests Memory | limits CPU | limits Memory |
|---|---|---|---|---|
| Prometheus | 200m | 512Mi | 1 | 2Gi |
| Alertmanager | 100m | 128Mi | 500m | 512Mi |
| Grafana | 100m | 256Mi | 500m | 1Gi |
| node-exporter (DaemonSet) | 100m | 64Mi | 200m | 128Mi |
| kube-state-metrics | 100m | 128Mi | 500m | 512Mi |
| prometheus-operator | 100m | 128Mi | 500m | 512Mi |

**Mimir Microservices 内 (各 component 1 replica):**

| Component | requests CPU | requests Memory | limits CPU | limits Memory |
|---|---|---|---|---|
| nginx (gateway) | 100m | 128Mi | 200m | 256Mi |
| distributor | 100m | 256Mi | 500m | 1Gi |
| ingester | 200m | 512Mi | 1 | 2Gi |
| querier | 100m | 256Mi | 500m | 1Gi |
| query-frontend | 100m | 256Mi | 500m | 512Mi |
| store-gateway | 100m | 512Mi | 500m | 2Gi |
| compactor | 100m | 512Mi | 500m | 2Gi |
| memcached (chunks-cache) | 100m | 512Mi | 200m | 1Gi |

**合計 requests** (Microservices 8 component): ~900m / ~3Gi
**合計 requests** (kube-prometheus-stack 6 component): ~700m / ~1.2Gi (DaemonSet node-exporter は node 数倍)
**合計 limits**: 全体で ~10 / ~20Gi

panicboat の Karpenter NodePool で必要な node 数は m6g.large (2 vCPU / 8 GiB) 換算で 3-4 nodes 想定 (= 既存の Karpenter NodePool で provision 可能)。

将来 observation で resource 過剰 / 不足を見極めて sizing 見直し。

### Decision 11: Grafana data source = Mimir primary + (Phase 4 で Loki / Tempo 追加)

Grafana の data source 設定 (`grafana.additionalDataSources` chart values):

```yaml
grafana:
  # Mimir (primary metrics data source)
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Mimir
          uid: mimir
          type: prometheus
          url: http://mimir-query-frontend.monitoring.svc.cluster.local:8080/prometheus
          access: proxy
          isDefault: true
        - name: Prometheus (local)
          uid: prometheus-local
          type: prometheus
          url: http://prometheus-operated.monitoring.svc.cluster.local:9090
          access: proxy
          isDefault: false
  # Loki / Tempo は Sub-project 3 / 4 で additionalDataSources に追加
```

**根拠**:

- Mimir を `isDefault: true` に: Grafana の dashboard panel が default で Mimir 経由 (= 長期 query 可能)
- Prometheus (local) も登録: 短期 latency-sensitive query (KEDA scaler / Phase 5 HPA debug 等) で利用
- Loki / Tempo は Sub-project 3 / 4 完了後に `grafana.additionalDataSources` に追加 (= 本 sub-project では設定しない)

### Decision 12: namespace = `monitoring` (Sub-project 1 と consistency)

Sub-project 1 で確定した `monitoring` namespace に kube-prometheus-stack + Mimir を集約。chart のデフォルト pattern と一致。

将来 service 単位の Network Policy / RBAC 細分化が必要になった時に namespace 分離を検討 (= 本 sub-project では `monitoring` 集約で simple に保つ)。

## Components matrix

| Layer | File | 内容 |
|---|---|---|
| AWS (terragrunt) | `aws/eks-metrics/modules/main.tf` | `local.bucket_name` / `local.service_name` を `mimir` 用に rename + header/inline comment 更新 |
| AWS (terragrunt) | `aws/eks-metrics/modules/outputs.tf` | description を Mimir 用に追従 (output key 名は維持) |
| K8s (helmfile) | `kubernetes/components/prometheus-operator/production/helmfile.yaml` | kube-prometheus-stack chart v84.5.0 install (release 名 `kube-prometheus-stack`) |
| K8s (helmfile) | `kubernetes/components/prometheus-operator/production/values.yaml.gotmpl` | local の values.yaml をベースに production override (Prometheus retention / resources / PVC / remote_write to Mimir / Grafana adminPassword) |
| K8s (helmfile) | `kubernetes/components/prometheus-operator/production/namespace.yaml` | `monitoring` namespace 作成 (chart 共有用) |
| K8s (helmfile) | `kubernetes/components/prometheus-operator/production/kustomization/` | (オプション) Grafana ConfigMap 等の追加リソース |
| K8s (helmfile) | `kubernetes/components/mimir/production/helmfile.yaml` | grafana/mimir-distributed chart v6.0.6 install (Microservices mode = chart default) |
| K8s (helmfile) | `kubernetes/components/mimir/production/values.yaml.gotmpl` | Mimir Microservices mode (9 component 有効化 + 4 component disable) + S3 backend (Sub-project 1 outputs) + Pod Identity (`serviceAccount.name=mimir`) + resources / PVC |
| K8s (helmfile) | `kubernetes/components/mimir/production/kustomization/` | (オプション) Mimir ConfigMap 等 |
| K8s | `kubernetes/helmfile.yaml.gotmpl` | production env values に Mimir 関連 cross-stack values 追加 (`mimir.bucketName` / `mimir.podIdentityRoleName` 等) |
| K8s | `kubernetes/manifests/production/{prometheus-operator,mimir}/` | hydrate 結果 (auto-generated) |
| K8s | `kubernetes/README.md` | 新 component (prometheus-operator/production / mimir/production) の追加と Phase 3 進捗反映 |

## Cross-stack value flow

```
aws/eks-metrics/  (Sub-project 1 + 本 sub-project で rename)
  └── outputs.bucket_name = "mimir-559744160976"
  └── outputs.bucket_path_prefix = "production"
  └── outputs.pod_identity_role_name = "eks-production-mimir"
      ↓
kubernetes/helmfile.yaml.gotmpl (production env)
  └── mimir.bucketName = ${terragrunt output bucket_name}
  └── mimir.bucketPathPrefix = ${terragrunt output bucket_path_prefix}
  └── mimir.podIdentityRoleName = ${terragrunt output pod_identity_role_name}
      ↓
kubernetes/components/mimir/production/values.yaml.gotmpl
  └── common.storage.s3.bucket = {{ .Values.mimir.bucketName }}
  └── common.storage.s3.endpoint = "s3.{{ .Values.cluster.region }}.amazonaws.com"
  └── serviceAccount.name = "mimir"  # Sub-project 1 rename 後の Pod Identity Association SA
      ↓
kubernetes/components/prometheus-operator/production/values.yaml.gotmpl
  └── prometheus.prometheusSpec.remoteWrite[0].url = "http://mimir-distributor.monitoring.svc.cluster.local:8080/api/v1/push"
  └── grafana.datasources[0].url = "http://mimir-query-frontend.monitoring.svc.cluster.local:8080/prometheus"
```

## Migration sequence

### PR 作成 → review → merge

1. 本 sub-project 用 1 PR (`feat/eks-production-observability-metrics-stack`) を Draft 作成
2. AWS-side: aws/eks-metrics/ rename を含む terragrunt plan で:
   - `module.s3.aws_s3_bucket.this[0]` destroy (`thanos-559744160976`) + create (`mimir-559744160976`)
   - `aws_iam_role.pod_identity` destroy + create
   - `aws_iam_role_policy.s3_access` destroy + create
   - `aws_eks_pod_identity_association.this` destroy + create
   - 合計 ~8 destroy + 8 create (本来の create-then-destroy ではなく rename なので destroy-create 順序、data 0 byte で安全)
3. K8s 側: kubernetes/components/{prometheus-operator,mimir}/production/ + helmfile.yaml.gotmpl + manifests/* を含む
4. PR Ready for review → merge → CI Deploy

### CI / Flux apply 後の cluster behavior

1. **terragrunt apply (AWS-side rename)**: aws/eks-metrics/ の resources が rename (旧 destroy + 新 create)
2. **Flux reconcile (K8s 側)**:
   - `monitoring` namespace 作成
   - kube-prometheus-stack chart install (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator)
   - grafana/mimir-distributed chart install (Mimir Microservices mode、8 component 有効化、Pod Identity Association `monitoring:mimir` で S3 access)
3. Prometheus Pod 起動後、ServiceMonitor / PodMonitor を discover して scrape 開始
4. Prometheus が Mimir distributor に remote write 開始 (= S3 に metrics flush 開始)
5. Grafana で Mimir data source 経由の query が動作確認可能

### 観察すべきタイミング

- AWS-side rename 完了確認: `aws s3 ls` で `mimir-559744160976` (新) / `thanos-559744160976` (削除済) / `aws iam list-roles` で `eks-production-mimir` (新)
- Pod 起動: `kubectl get pods -n monitoring -o wide`
- Prometheus → Mimir remote write 確認: `kubectl logs -n monitoring prometheus-... -c prometheus | grep -i remote_write`
- Mimir S3 upload 確認: `aws s3 ls s3://mimir-559744160976/production/ --recursive | head -20` で metrics block 表示
- Grafana data source 動作確認: Grafana UI から Explore で Mimir query 実行 (= cluster 内 metrics が返る)

### エラーシナリオと対処

| 事象 | 原因 | 対処 |
|---|---|---|
| terragrunt apply で旧 bucket destroy 失敗 | bucket に object が残っている (= 想定外、本 sub-project 着手前に確認しているはず) | `aws s3 rm s3://thanos-559744160976/ --recursive` で空にしてから再 apply |
| Mimir Pod が CrashLoopBackOff | Pod Identity Association 反映遅延、または S3 access 失敗 | `kubectl describe pod` で events 確認、Pod Identity Agent (Sub-project 1 で確認済) が動作しているか check、IAM policy が正しいか check |
| Prometheus remote write 503 / connection refused | Mimir distributor が起動前 / startup probe 失敗 | Mimir Pod の readiness 待ち (chart の install 順序が helmfile dependency で制御されている前提)、`kubectl wait` で順次起動 |
| Grafana data source が "no data" | Mimir に metrics が flush されるまで時間がかかる (= ingester の batch interval 1-2 min) | 5-10 分待ってから再 query。それでも no data なら Prometheus の remote write log + Mimir distributor の log 確認 |

## Verification checklist

### PR merge → terragrunt apply + Flux reconcile 完了後

- [ ] AWS-side rename 完了:
  - `aws s3 ls --region ap-northeast-1` で `mimir-559744160976` 表示、`thanos-559744160976` 消滅
  - `aws iam list-roles --query 'Roles[?starts_with(RoleName, \`eks-production-mimir\`)].RoleName'` で `eks-production-mimir` 表示
  - `aws eks list-pod-identity-associations --cluster-name eks-production --query 'associations[?serviceAccount==\`mimir\`]'` で 1 association 表示
- [ ] K8s 側 chart install:
  - `kubectl get namespace monitoring` で namespace 存在
  - `kubectl get pods -n monitoring` で kube-prometheus-stack + Mimir の全 Pod が `Running 1/1`
  - `kubectl get pvc -n monitoring` で 5+ PVC (Prometheus / Alertmanager / Grafana / Mimir ingester / Mimir store-gateway 等) が `Bound`
- [ ] Metrics flow:
  - `kubectl logs -n monitoring prometheus-kube-prometheus-prometheus-0 -c prometheus | grep -i 'remote_write'` で Mimir distributor への送信 log
  - `aws s3 ls s3://mimir-559744160976/production/ --recursive | head -20` で metrics block 表示 (~5-10 分後)
- [ ] Grafana 動作:
  - `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` で Grafana UI access
  - data source で Mimir / Prometheus (local) 両方 "Working" 表示
  - Explore で Mimir 経由 query (例: `up`) が結果を返す
  - Default dashboards (kube-prometheus-stack 同梱) で cluster metrics 表示

### 後続 sub-project に対する readiness

- [ ] Sub-project 3 (Loki) で `kubernetes/components/loki/production/` を追加する際の `monitoring` namespace 共有が確認可能
- [ ] Sub-project 4 (Tempo + OpenTelemetry + Beyla) で同 namespace 共有が確認可能
- [ ] Sub-project 3 / 4 で Grafana の `additionalDataSources` に Loki / Tempo を追加する際の chart values 構造が consume 可能 (= helmfile-builder で Grafana data source list を増分可能)

## Trade-offs (accepted explicitly)

- **bucket / IAM role / Pod Identity Association の destroy + recreate を実施**: data 0 byte で safe だが、terragrunt apply の plan diff が `8 destroy + 8 create` で見た目が大きい。reviewer に対する説明として spec / PR description で明示
- **Grafana adminPassword の暫定 hardcode**: Phase 4 まで cluster 内 access のみ可能な状態 (= ALB Ingress / 認証 layer は Phase 4 で追加)、短期間の risk として accept
- **Mimir Microservices mode の HA 化**: 各 component が default で 1 replica (= chart values で `replicas: 1`)、ingester の AZ-spread はしない (本 phase は単 AZ で start、Phase 5 / 6 で multi-AZ 検討)。Microservices mode は将来 component 個別に replica 増やすだけで scaling 可能 (= 当初 Read-Write mode 想定の利点を継承)
- **PVC AZ pinning**: gp3 EBS が AZ scoped、Karpenter NodePool が複数 AZ にまたがる場合に Pod が PVC の AZ に pin される (= rolling update 時に Pod 再 schedule の AZ 制約)。本 sub-project では accept (= EKS の通常運用)
- **Mimir compactor を本 sub-project で deploy**: Microservices mode で compactor を有効化、S3 cost 削減のため compaction を有効化 (= Thanos Compactor と同等の役割を Mimir 内で兼務)
- **Mimir Ruler / Receiver / Alertmanager (Mimir built-in) を本 sub-project で disable**: kube-prometheus-stack 内蔵 Alertmanager + Prometheus rule で alerting を担う traditional pattern を採用、Mimir 内蔵 multi-tenant features は over-engineering

## Rollback strategy

- **terragrunt apply 失敗 (AWS-side rename)**: `git revert <merge-sha>` で Sub-project 2 PR を revert → CI Deploy が destroy + create で旧名 (`thanos-` / `prometheus`) に戻す
- **K8s 側 chart install 失敗**: `helmfile destroy -e production -l name=kube-prometheus-stack` および `helmfile destroy -e production -l name=mimir-distributed` で chart removal、AWS-side resource は維持
- **Grafana adminPassword issue (= sign-in 不可)**: chart values の `grafana.adminPassword` を update して helmfile sync で再 deploy、または Grafana Pod に kubectl exec で password reset

## Future Specs (本 spec の Out of scope)

- Sub-project 3 (Logs stack: Loki + Fluent Bit) — kubernetes/components/loki/production + fluent-bit/production
- Sub-project 4 (Traces stack: Tempo + OpenTelemetry + Beyla + Hubble OTLP integration) — kubernetes/components/tempo/production + opentelemetry/production + beyla/production
- Phase 4 で Grafana 認証 (oauth2-proxy or ALB OIDC) + Alertmanager receiver + ESO / Vault による adminPassword secret 化
- Mimir Microservices mode への移行 (cluster 規模 10M+ active series 時)
- Mimir Ruler を使った PrometheusRule の長期評価
- Grafana Alloy への scrape agent 移行 (Phase 6+ Future Spec)
- multi-tenant Mimir 設定 (panicboat 1 tenant 想定の現状から拡張時)
- Grafana custom dashboard の bulk import (Phase 5 / 6 で workload 観測時)
