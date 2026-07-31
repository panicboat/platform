# OpenCost Integration — Design

## Purpose

Grafana から AWS cost を可視化できるようにする。 Cost Explorer を都度開く運用を減らし、 特に system-components node pool (ほぼ spot) のコストを既存の Grafana/Mimir パイプラインで見られるようにする。

## Scope

- [OpenCost](https://opencost.io/) (CNCF incubating, Apache 2.0) を production cluster に導入する
- コスト算出は **AWS Pricing API モードのみ** (CUR/Athena は導入しない)
- spot instance の価格精度確保のため **AWS Spot Instance Data Feed** を新規に有効化する
- OpenCost 公式 Grafana dashboard を導入する

## Out of Scope

- **CUR + Athena によるコスト reconciliation**: 個人アカウントには negotiated discount / savings plan 等の値引きがなく、 CUR 導入の主な価値 (実請求額との突合) がほぼ得られない。 一方 S3+Athena の追加インフラと Athena query 課金というランニングコストだけが乗るため見送る
- **Slack 等への通知パイプライン**: 既存の `aws/cost-management` (Cost Optimization Hub / Compute Optimizer) と同様、 まずは Grafana で見られる状態を作ることが目的。 通知は別途検討
- **Cost Optimization Hub / Compute Optimizer との連携**: 既存 stack だが実際には有効化されているのみで消費されていない (design spec `2026-05-03-aws-cost-management-design.md` の scope 通り)。 本設計では触れない

## Architecture

```
EC2 (spot) --hourly--> S3 (spot data feed, 新規 bucket)
                              │
AWS Pricing API <-------------┼------ OpenCost pod (Pod Identity 認証)
                              │              │
kube-state-metrics/           │              │ /metrics
node-exporter/cAdvisor -------┘              ▼
  (既存 kube-prometheus-stack が scrape)  ServiceMonitor
                                             │
                                    kube-prometheus-stack Prometheus
                                             │ remote-write (既存 pipeline)
                                             ▼
                                           Mimir
                                             │
                                           Grafana (公式 OpenCost dashboard)
```

## Components

### `kubernetes/components/opencost/production/`

新規 component。 既存 component (mimir 等) と同じ helmfile hydrate pattern に従う。

- namespace: `monitoring` (mimir/loki/tempo/prometheus-operator/beyla/opentelemetry-collector と同居、 既存 convention)
- 認証: EKS Pod Identity (IRSA ではなく、 mimir/cilium-operator/aws-load-balancer-controller/karpenter と同じ既存 pattern)
- ServiceMonitor: `release: kube-prometheus-stack` label を付与し既存 Prometheus に scrape させる (cilium の ServiceMonitor と同じ pattern)。 `trustCRDsExist: true` で offline hydrate 時の CRD 未登録エラーを回避

### `aws/eks-cost/` (新規 stack)

OpenCost 用 Pod Identity IAM role。 `aws/eks-metrics`/`eks-logs`/`eks-traces` と同じ「1 AWS 機能 = 1 stack」pattern に従う。 cluster と一蓮托生の resource のため `docs/runbooks/eks-production-recreate.md` の destroy/recreate cycle 対象に含める (= `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の STACKS 配列に追加)。

- IAM role: Pod Identity Association で `monitoring:opencost` ServiceAccount にひも付け
- 権限: AWS Pricing API (`pricing:GetProducts` 等) + EC2 read (instance/spot price history 参照用)。 具体的な最小権限 policy は実装時に実際の OpenCost 呼び出しログで検証しながら確定する

### `aws/cost-management/` (既存 stack、 拡張)

Spot Instance Data Feed 用の S3 bucket + `aws_spot_datafeed_subscription`。

**なぜ既存 stack に足すか**: `aws_spot_datafeed_subscription` は **1 AWS account に1つしか作れない singleton resource** (今日の `AWSServiceRoleForEC2Spot` service-linked role と同種の制約)。 `aws/eks-cost` のような cluster 一蓮托生の stack に置くと、 cluster recreate の度に破棄・再作成を試みてしまう。 `aws/cost-management` は既に「account 単位の AWS cost 関連設定を置く場所」として teardown cycle 対象外で運用されており、 置き場所として適切

### `kubernetes/components/dashboard/production/kustomization/grafana/`

OpenCost 公式 Grafana dashboard JSON を追加。 既存の sidecar auto-discovery (`grafana_dashboard` label) にそのまま乗る。

## Data Flow

1. EC2 が spot instance 稼働時間分の価格情報を毎時 S3 (新規 bucket) に書き出す。 instance が稼働していない時間帯は data feed ファイルが生成されない
2. OpenCost pod が Pod Identity で AWS 認証し、 S3 data feed (spot 価格) + AWS Pricing API (on-demand 価格) を読む
3. 既存の kube-state-metrics / node-exporter / cAdvisor (既に kube-prometheus-stack が scrape 済み) の resource 使用量と突き合わせ、 pod/namespace/node/deployment 単位のコストを算出
4. OpenCost 自身の `/metrics` を ServiceMonitor 経由で Prometheus が scrape → 既存の remote-write pipeline で Mimir へ
5. Grafana (公式 dashboard、 datasource は Mimir) で可視化

## Known Constraints

- **S3 bucket の Object Ownership**: Spot Data Feed は AWS 側が bucket ACL に write 権限を付与する legacy 方式に依存する。 新規 bucket を `Bucket owner enforced` (ACL 無効、 現行 S3 のデフォルト) のままにすると data feed が書き込めない。 明示的に ACL を有効化する設定が必要
- **データ遅延**: spot data feed は毎時到着、 かつ instance が稼働していない時間は生成されない。 bootstrap 直後や instance 起動直後はしばらく "no data" になりうる
- **見積り精度の限界**: Pricing API モードは on-demand 料金表ベースで、 negotiated discount / savings plan は反映されない (本アカウントには該当なしのため実害なし)

## Testing / Verification

- deploy 後、 OpenCost pod のログで AWS 認証成功 + Pricing API 呼び出し成功を確認する (VERIFIED として記録)
- `/metrics` (または Prometheus 経由の query) で cost metric に非ゼロ・妥当な値が出ることを確認する
- 既知の node の spot 価格 (`aws ec2 describe-spot-price-history` で実測した値) と OpenCost の算出値を突き合わせて sanity check する
- Grafana dashboard が "no data" にならず描画されることを確認する
- `aws/eks-cost` と `aws/cost-management` それぞれで `terragrunt plan` が意図した差分のみになることを確認する
