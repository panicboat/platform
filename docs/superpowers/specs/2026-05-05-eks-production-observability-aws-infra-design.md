# EKS Production: Observability AWS Infrastructure Design (Phase 3 Sub-project 1)

## Background

Roadmap (`docs/superpowers/specs/2026-05-02-eks-production-platform-roadmap-design.md`) の **Phase 3 Observability** は kube-prometheus-stack + Loki + Tempo + Fluent Bit + OpenTelemetry Operator + Beyla + Grafana の 10+ コンポーネント、S3 bucket × 3、IRSA × 3 (Pod Identity に変更) を含む大規模な phase。1 spec / 1 plan で扱うのは無理なので **4 sub-projects に分解** し、各 sub-project が独立した spec / plan / PR cycle を持つ:

1. **Sub-project 1 (本 spec)**: AWS-side infra (S3 × 3 + Pod Identity × 3) — 全 sub-projects の前提
2. Sub-project 2: Metrics stack (kube-prometheus-stack + Thanos sidecar + Grafana)
3. Sub-project 3: Logs stack (Loki + Fluent Bit)
4. Sub-project 4: Traces stack (OpenTelemetry Operator + Tempo + Beyla + Hubble OTLP integration)

本 spec は Sub-project 1 の design。Phase 3 各 service が S3 backend に書き込むための AWS-side リソース (S3 bucket + Pod Identity Association + IAM role + S3 policy) を 3 つの independent terragrunt stack で provisioning する。

## Goals

### G1: Phase 3 観測スタック用の S3 backend を 3 stack で provisioning

Prometheus (Thanos sidecar) / Loki / Tempo の各 service が長期データを書き込む S3 bucket を 3 つ作成する。各 bucket は独立した stack で管理することで、将来の単一 service 移行 (例: Prometheus → AMP) で stack 単位の atomic な destroy / re-create が可能になる。

### G2: 各 service が自分の S3 bucket の production env path にのみ access する Pod Identity Association を構築

各 service の K8s ServiceAccount を IAM role に紐付ける Pod Identity Association を 3 つ作成。IAM permission scope は `arn:aws:s3:::<bucket>/${env}/*` で env path に絞り、minimum permission 原則を採用。

### G3: data-type 中立な stack 命名で将来 managed service 移行に対応

Stack 名を `aws/eks-metrics/`, `aws/eks-logs/`, `aws/eks-traces/` の data-type 中立な命名にする。将来:

- Prometheus → Amazon Managed Prometheus (AMP) 移行時、`aws/eks-metrics/` 内に `aws_prometheus_workspace` を追加 + S3 destroy で **stack 名そのまま** 移行完了
- Loki → CloudWatch Logs 移行時、`aws/eks-logs/` 内に CloudWatch Log group + IAM role を追加で同様
- Tempo → AWS X-Ray 移行時、`aws/eks-traces/` 内で X-Ray IAM role を追加で同様

self-hosted (Thanos / Loki / Tempo) と managed (AMP / CloudWatch / X-Ray) の parallel run 期間も同 stack 内で並列存在可能。

### G4: env 分離は bucket 内 path prefix で実現

bucket 名は `<component>-<account-id>` (env 識別子なし) とし、env 分離は bucket 内 prefix `${var.environment}/` で行う。同 account 内で staging を構築する場合に同じ bucket を共有可能。将来別 account に env 分離する場合は account-id 自体が変わるので bucket migration が自然に必要 = env 識別子による冗長性なし。

## Non-goals

- Sub-project 2-4 の Helm chart 導入 (= Prometheus / Loki / Tempo の K8s 側構築) — 別 sub-project
- Hubble OTLP integration の AWS 側変更 — Sub-project 4 (本 sub-project は infra のみ)
- Karpenter stack rename (`aws/karpenter/` → `aws/eks-karpenter/`) — 命名 consistency 改善は Future Specs / 別 plan
- KMS CMK encryption への切り替え — compliance 要件発生時に別 spec
- CloudWatch alarm (storage size monitoring) / Athena workgroup (S3 query) — Out of scope
- staging env を同 account で構築する Pod Identity 追加 — staging 立ち上げ時に別 spec
- managed service 移行 (AMP / CloudWatch Logs / X-Ray の resource 追加) — 顕在化時に別 spec

## Architecture decisions

### Decision 1: 3 つの independent terragrunt stack で構成

3 stack に分割:

- `aws/eks-metrics/` (Prometheus + Thanos sidecar 用 S3 + Pod Identity)
- `aws/eks-logs/` (Loki 用 S3 + Pod Identity)
- `aws/eks-traces/` (Tempo 用 S3 + Pod Identity)

各 stack は独立した terragrunt cache を持ち、`terragrunt apply` を順次 (or 並列) 実行できる。stack 間の依存なし。

各 stack の boilerplate (Plan 2 `aws/karpenter/` を踏襲):

```
aws/eks-metrics/
├── Makefile
├── root.hcl
├── envs/production/
│   ├── env.hcl
│   └── terragrunt.hcl
└── modules/
    ├── terraform.tf
    ├── variables.tf
    ├── lookups.tf      # cross-stack lookup (aws/eks/lookup から cluster name 取得)
    ├── main.tf
    └── outputs.tf
```

**Trade-off**: 3 stack 分の boilerplate (root.hcl / env.hcl / terragrunt.hcl 等で約 21-24 ファイル増) が単一 stack より多い。ただし Plan 2 で `aws/karpenter/` を新規 stack で作成した経験から、boilerplate 重複は管理可能なコストで、stack 単位の atomic 性 (将来 managed 移行時の柔軟性) のメリットが大きい。

**不採用案**:
- 単一 `aws/observability/` stack: 全 service の S3 + Pod Identity を 1 stack に集約。boilerplate 最小だが、将来 managed 移行時に S3 destroy + AMP create が同 stack 内で混在し plan diff が複雑化
- service ごと分離 (`aws/prometheus/`, `aws/loki/`, `aws/tempo/`): self-hosted 名を直接採用。AMP 移行時に stack 名変更が必要 (= rename 操作で historical context 喪失)

### Decision 2: S3 bucket 命名は `<component>-<account-id>`

bucket 名:

- `thanos-559744160976` (Prometheus 長期保管用、Thanos sidecar が write)
- `loki-559744160976`
- `tempo-559744160976`

**根拠**:

- S3 bucket 名はグローバル名前空間で全 AWS account を跨いで一意である必要がある
- account-id を含めることで衝突回避を完全担保 (terragrunt-state bucket `terragrunt-state-559744160976` の既存 pattern と consistency)
- env 識別子は bucket 名に含めず、bucket 内 path prefix で env 分離 (Decision 3)
- component 名 (`thanos` / `loki` / `tempo`) を bucket 名に直接含めることで、将来 managed service と並列存在する移行期に **どの bucket がどの self-hosted service のものかが bucket 名から即座に判別可能**

**Bucket 名長**: 各 33 chars 以下、S3 bucket name 上限 63 chars に十分収まる。

### Decision 3: env 分離は bucket 内 prefix で行う

各 service が bucket に書き込む path を `${var.environment}/` prefix で分離する:

- `s3://thanos-559744160976/production/...`
- `s3://loki-559744160976/production/...`
- `s3://tempo-559744160976/production/...`

**Service 側の prefix 指定**:

- **Thanos**: `objstore.config_file` の `config.prefix: production` (Sub-project 2 で chart values に設定)
- **Loki**: storage config の `s3.bucketnames` (`<bucket>`) + `s3.s3.endpoint` で URI 指定、`storage_config.aws.s3` の path-style endpoint で prefix 反映 (Sub-project 3 で chart values に設定)
- **Tempo**: `tempo.storage.trace.s3.prefix: production` (Sub-project 4 で chart values に設定)

将来 staging を **同 account** で構築する場合、別 IAM role + 別 Pod Identity Association を `staging` env path 用に追加 (= bucket 共有、path で論理分離)。

### Decision 4: Lifecycle retention

各 bucket に env path 別の lifecycle policy を設定 (production path のみ filter):

| Stack | bucket | lifecycle filter | retention |
|---|---|---|---|
| `aws/eks-metrics/` | `thanos-559744160976` | `prefix: production/` | 90 日 |
| `aws/eks-logs/` | `loki-559744160976` | `prefix: production/` | 30 日 |
| `aws/eks-traces/` | `tempo-559744160976` | `prefix: production/` | 7 日 |

**根拠**:

- Thanos 90 日: 長期トレンド分析、SLO 評価、capacity planning に十分
- Loki 30 日: trouble-shoot、incident review。compliance 要件 (typically 14-90 日) のミドル
- Tempo 7 日: trace は high-volume (各 request 1 trace)。debug / performance investigation は最近のものに集中、長期保管は cost に見合わない

`Expiration` action のみ設定 (= 古いオブジェクトを delete)。`Transition` (Glacier 等) は cost と access pattern を見て将来評価。

将来別 env (staging) を同 account で追加する場合、staging path 用の lifecycle filter を別途追加可能 (= staging は短い retention 等)。

### Decision 5: Server-side encryption は SSE-S3 (AES256)

各 bucket に SSE-S3 (AWS 管理鍵による AES256 暗号化) を default encryption として設定。

**不採用案**:

- SSE-KMS (`aws/s3` AWS managed key): KMS CloudTrail event で encrypt/decrypt audit が可能だが、observability data は機微情報なし設計 (= application secret は別 layer = ESO + Secrets Manager で扱う、Phase 4)。audit 必要性が顕在化した時点で別 spec で切り替え可能
- SSE-KMS (customer-managed CMK): $1/month/key + API call cost、key rotation policy 完全制御。compliance 要件 (PCI / HIPAA 等) が顕在化した時点で別 spec

terragrunt-state bucket も SSE-S3 (typical AWS default) と consistency。

### Decision 6: Public access block 4 setting すべて true

`aws_s3_bucket_public_access_block` で:

- `block_public_acls = true`
- `block_public_policy = true`
- `ignore_public_acls = true`
- `restrict_public_buckets = true`

production 標準設定。bucket policy / ACL で誤って public access を許可することを防止。

### Decision 7: Versioning は Disabled

各 bucket の versioning は disable。

**根拠**:

- Thanos / Loki / Tempo は immutable write pattern (一度書いた object は基本上書きしない、新規 object 作成 → 旧 object 削除のサイクル)
- versioning を enable すると object 数が約 2 倍に増え、high-volume backend で cost が顕著に増える
- accidental delete 対策は IAM policy で `s3:DeleteObject` の使用を minimize する形で実現

将来 compliance 要件 (legal hold, audit) が顕在化した時点で bucket-level setting 変更で enable 可能。

### Decision 8: Kubernetes namespace は `monitoring` 集約

3 service (Prometheus / Loki / Tempo) を `monitoring` namespace に集約配置。

**根拠**:

- kube-prometheus-stack chart の本来の設計 (`monitoring` namespace に Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics 等を集約)
- 観測スタック全体の install / upgrade を namespace 単位で扱える
- chart 推奨デフォルトに乗ることで chart upgrade 追従が楽

**不採用案**:

- service ごと namespace 分離 (`prometheus`, `loki`, `tempo`): namespace-level Network Policy で service 間 isolation がシンプルになるが、panicboat の現状で細かい Network Policy 運用していないため benefit 限定的。kube-prometheus-stack chart のデフォルト構成から逸脱する

将来 Network Policy / CiliumNetworkPolicy で service 間 isolation を細かく運用する方針が確定したら、`monitoring` 内の podSelector based policy で対応 (= chart label `app.kubernetes.io/name` に依存するため chart upgrade 時の追従が必要)。

### Decision 9: ServiceAccount 名は短縮 + role-explicit

各 service の chart `serviceAccount.name` を default の長い prefix 付き名 (例: `prometheus-kube-prometheus-prometheus`) ではなく、短縮した role-explicit な名前に override する:

- Prometheus: `prometheus`
- Loki: `loki`
- Tempo: `tempo`

**根拠**:

- Plan 2 `aws/karpenter/` で同パターン採用 (chart デフォルト override で SA 名 `karpenter`)
- IAM trust policy / Pod Identity Association の audit log で SA 名が role-explicit で読みやすい
- chart values での `serviceAccount.name` override は documented values で chart 動作に影響なし

### Decision 10: Authentication は Pod Identity Association

各 service の SA を IAM role に紐付ける authentication として Pod Identity Association を採用 (Plan 2 `aws/karpenter/` で確立)。

**実装**:

- terraform-aws-modules/eks 系の `eks-pod-identity` sub-module (or `aws_eks_pod_identity_association` resource 直接) を使用
- 各 stack に 1 つの Pod Identity Association を作成:
  - `aws/eks-metrics/`: namespace=`monitoring`, service_account=`prometheus`
  - `aws/eks-logs/`: namespace=`monitoring`, service_account=`loki`
  - `aws/eks-traces/`: namespace=`monitoring`, service_account=`tempo`

**IAM role の trust policy**: `pods.eks.amazonaws.com` service principal が AssumeRole 可能。Pod Identity Agent が EKS cluster で enable 済 (Phase 1 + Plan 2 で確認済)。

**不採用案**:

- IRSA (IAM Roles for Service Accounts via OIDC): Plan 1c-β L1 で random suffix の hassle が判明、Plan 2 で Pod Identity に切り替え済。本 spec も Pod Identity を採用 (consistency)

### Decision 11: IAM permission scope は production env path 限定

各 IAM role の S3 access policy は production env path のみに access 可能:

```hcl
# 3 statement に分離する:
# - BucketLevelListing: s3:prefix condition で env-scoped な ListBucket
# - BucketLocation: condition なし、bucket 全体への GetBucketLocation
#   (s3:prefix condition は GetBucketLocation には適用できない、
#    bundle すると condition が match せず call が deny される)
# - ObjectLevelOperations: env path に限定された Get/Put/Delete
{
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
}
```

**根拠**:

- Minimum permission 原則: production SA は staging path に書けるべきでない (将来同 account staging 構築時の安全性)
- ListBucket は bucket 全体に許可 + condition で `s3:prefix` を `${env}/*` に絞ることで listing も env-scoped
- GetBucketLocation は別 statement に分離: `s3:prefix` condition は API call の context key として GetBucketLocation には provide されないため、condition 付き bundle すると call が deny される
- DeleteObject は service の lifecycle (Thanos compaction、Loki/Tempo block deletion) で必要なため許可

### Decision 12: Cross-stack lookup pattern

各 stack は `aws/eks/lookup/` (Plan 2 で確立済) から EKS cluster info (cluster name、Pod Identity Association の cluster_name 引数用) を取得する:

```hcl
# aws/eks-metrics/modules/lookups.tf
module "eks" {
  source = "../../eks/lookup"
  environment = var.environment
}

# main.tf 内で `module.eks.cluster.name` を Pod Identity Association の cluster_name に渡す
```

各 stack 自身は `bucket_name`、`pod_identity_role_name`、`bucket_path_prefix` 等を terragrunt output として export し、Sub-project 2-4 の Helm chart 化 task で取得 (Plan 2 で確立した pattern)。

## Components matrix

| Stack | AWS resources | terragrunt outputs |
|---|---|---|
| `aws/eks-metrics/` | S3 bucket `thanos-559744160976` + lifecycle (90d, prefix `production/`) + SSE-S3 + Public Access Block + Pod Identity Association (`monitoring:prometheus`) + IAM role + S3 policy | `bucket_name`, `bucket_path_prefix` (= `production`), `pod_identity_role_name` |
| `aws/eks-logs/` | S3 bucket `loki-559744160976` + lifecycle (30d) + Pod Identity (`monitoring:loki`) | 同型 |
| `aws/eks-traces/` | S3 bucket `tempo-559744160976` + lifecycle (7d) + Pod Identity (`monitoring:tempo`) | 同型 |

各 stack の terraform resource 数: 約 10 (S3 bucket + 4 sub-resource + Pod Identity Association + IAM role + IAM policy + policy attachment + lookup module)。3 stack 合計 ~30 resources。

## Cross-stack value flow

```
aws/eks/lookup/         (EKS cluster lookup)
  └── outputs.cluster.name
      ↓
aws/eks-metrics/        (Sub-project 1)
  └── outputs.bucket_name = "thanos-559744160976"
  └── outputs.bucket_path_prefix = "production"
  └── outputs.pod_identity_role_name = "eks-production-prometheus-..."
      ↓
kubernetes/components/kube-prometheus-stack/production/  (Sub-project 2)
  └── helmfile values: thanos.objstoreConfig.bucket = ${output.bucket_name}
  └── helmfile values: thanos.objstoreConfig.prefix = ${output.bucket_path_prefix}
```

(eks-logs, eks-traces も同型)

## Migration sequence

3 stack は依存なし → 順次 or 並列で `terragrunt apply`:

1. `aws/eks-metrics/` を新規作成 → init / validate / plan / apply
2. `aws/eks-logs/` を新規作成 → 同様
3. `aws/eks-traces/` を新規作成 → 同様

各 stack の apply は ~1-2 分程度を想定 (S3 bucket 1 + IAM resources 数個)。

merge 順は recommended に並列でも 1 PR で全 3 stack を含めても OK。1 PR にすると CI Deploy で 3 stack 一括 apply。

### Cluster 影響

本 sub-project は AWS-side のみ provision (S3 + IAM + Pod Identity Association)。**K8s cluster 側で何も変化しない** (= 既存 pod / nodepool / namespace に影響なし)。

Sub-project 2-4 で chart install する際に cluster 側で `monitoring` namespace + 各 SA + Helm release が初めて作成される。

## Verification checklist

### PR merge → terragrunt apply 完了直後

- [ ] `aws s3 ls` で 3 bucket (`thanos-559744160976`, `loki-559744160976`, `tempo-559744160976`) が表示される
- [ ] `aws s3api get-bucket-encryption --bucket <bucket>` で SSE-S3 (AES256) confirm (3 bucket すべて)
- [ ] `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>` で env path 別 retention confirm:
  - `thanos-559744160976`: filter `prefix: production/` で expiration 90 日
  - `loki-559744160976`: 同 30 日
  - `tempo-559744160976`: 同 7 日
- [ ] `aws s3api get-public-access-block --bucket <bucket>` で 4 setting すべて true (3 bucket すべて)
- [ ] `aws s3api get-bucket-versioning --bucket <bucket>` で `Status` が空 (Disabled、3 bucket すべて)
- [ ] `aws iam list-roles --query 'Roles[?starts_with(RoleName, ` で 3 IAM role 確認 (Pod Identity Association 用)
- [ ] `aws eks list-pod-identity-associations --cluster-name eks-production --region ap-northeast-1` で 3 association 確認:
  - namespace=`monitoring`, service_account=`prometheus`, role_arn = ...
  - namespace=`monitoring`, service_account=`loki`, role_arn = ...
  - namespace=`monitoring`, service_account=`tempo`, role_arn = ...
- [ ] `terragrunt output` で各 stack の `bucket_name` / `bucket_path_prefix` / `pod_identity_role_name` が取得できる

### 後続 sub-project に対する readiness

- [ ] Sub-project 2 の helmfile values 構築時に `aws/eks-metrics/envs/production` の terragrunt output が参照可能
- [ ] Sub-project 3 / 4 でも同様
- [ ] cluster 側で **何も変化していない** (= 本 PR は AWS-side only、K8s 側 manifest なし)

## Trade-offs (accepted explicitly)

- **3 stack 分の boilerplate 増 (root.hcl / env.hcl / terragrunt.hcl 等で約 21-24 ファイル)**: 単一 stack より管理ファイル多い。Plan 2 `aws/karpenter/` と同型 boilerplate なので習熟済 + stack 単位の atomic 性 (将来 managed 移行時の柔軟性) のメリットが大きいと判断
- **`monitoring` 集約 namespace に複数 service 同居**: kube-prometheus-stack chart のデフォルト pattern。service 単位の Network Policy isolation は podSelector で書く必要があり chart label 依存 (chart upgrade で label key 変わると policy 無効化リスク)。現状 panicboat で細かい Network Policy 運用していないため accept
- **bucket 名に env 識別子なし (= account-id のみで衝突回避)**: 同 account staging 構築時に env path 分離で対応。別 account 移行時は bucket migration 必要 (S3 bucket 名は immutable) — env 識別子の有無は migration 必要性に影響しない
- **IAM permission DeleteObject 含む**: Thanos compaction / Loki Tempo の block lifecycle で必要。Versioning Disabled と組み合わせて accidental delete 不可逆な risk あり、将来 critical な data 保護要件発生時は IAM の DeleteObject 削除 + lifecycle policy の expire のみで管理する形に切り替え可能

## Rollback strategy

- **Stack apply 失敗 / リソース provisioning エラー**: terragrunt destroy で当該 stack を rollback (3 stack 独立なので他 stack への影響なし)
- **本 PR の merge 後問題発生**: `git revert <merge-sha>` で revert PR を作成 → CI が destroy 適用
- **Sub-project 1 完了後に重大な設計変更が発生**: `aws/eks-{metrics,logs,traces}/` を一斉 destroy → 別 spec で再 design (S3 bucket 内に data なしの状態なので migration 不要)

## Future Specs (本 spec の Out of scope)

- Sub-project 2-4 の Helm chart 導入 (Phase 3 残作業)
- Hubble OTLP integration (Sub-project 4)
- Karpenter stack rename (`aws/karpenter/` → `aws/eks-karpenter/`) で命名 consistency 統一
- managed service 移行 (各 stack 内に AMP workspace / CloudWatch Log group / X-Ray IAM role 追加 + S3 destroy)
- KMS CMK encryption への切り替え (compliance 要件発生時)
- CloudWatch alarm (storage size monitoring)
- Athena workgroup (S3 query)
- staging env を同 account で構築する場合の Pod Identity 追加
- 別 account への env 分離 (production-account / staging-account の AWS account 分離)
