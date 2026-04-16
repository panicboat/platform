# aws/vpc — Production VPC Design

## Purpose

`ap-northeast-1` に production VPC を構築する。将来的に EKS / ECS クラスタや RDS 等のワークロードをホストする基盤ネットワークであり、2026-04-16 に削除したデフォルト VPC の後継となる。

## Scope

- `aws/{service}/modules + envs/{env}` の既存構成慣習（`claude-code`, `claude-code-action`, `github-oidc-auth` で採用済み）に沿って `aws/vpc/` を新設する。
- 当面は `production` 環境のみを用意する。`develop` / `staging` が必要になった時点で `envs/production/` を複製して対応する。
- 含めるリソース: VPC、サブネット（3 tier × 3 AZ）、IGW、単一 NAT Gateway、ルートテーブル、DB サブネットグループ。

## Out of Scope

- EKS / ECS / RDS 等のワークロード本体（別サービスとして切り出す）。
- VPC endpoint（S3, ECR 等）。必要になったワークロード側で追加する。
- Transit Gateway / VPC peering。
- VPC Flow Logs。監査要件が出た段階で追加する。
- EKS 用のサブネットタグ（`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`）は EKS モジュール側で付与する。

## Architecture

### Network Layout

| Tier | AZ 1a | AZ 1c | AZ 1d | Route |
|---|---|---|---|---|
| Public | `10.0.0.0/24` | `10.0.1.0/24` | `10.0.2.0/24` | IGW |
| Database (isolated) | `10.0.10.0/24` | `10.0.11.0/24` | `10.0.12.0/24` | **default route なし** |
| Private (compute) | `10.0.32.0/19` | `10.0.64.0/19` | `10.0.96.0/19` | NAT GW |

- **VPC CIDR**: `10.0.0.0/16`
- **IGW**: VPC に 1 つアタッチ。public サブネットは `0.0.0.0/0` を IGW へ向ける。
- **NAT GW**: public-1a に単一配置し、3 つの private サブネットすべてが `0.0.0.0/0` を共有 NAT に向ける。AZ 1a 障害時には 1c / 1d の private サブネットも egress できなくなるトレードオフを許容する。
- **Database subnet**: 完全 isolated。専用ルートテーブルに default route を持たせない。シークレットローテーション等で外部通信が必要になったら VPC endpoint を後追いで追加する。
- **DNS**: `enable_dns_support = true`, `enable_dns_hostnames = true`（EKS 要件）。

### CIDR Allocation (10.0.0.0/16)

```
10.0.0.0/24   - 10.0.2.0/24    public   (3 x /24)
10.0.3.0/24   - 10.0.9.0/24    reserved
10.0.10.0/24  - 10.0.12.0/24   database (3 x /24)
10.0.13.0/24  - 10.0.31.0/24   reserved
10.0.32.0/19                   private-1a
10.0.64.0/19                   private-1c
10.0.96.0/19                   private-1d
10.0.128.0/17                  reserved
```

EKS の VPC CNI が Pod ごとに ENI IP を消費するため、private サブネットは `/19`（各 8192 IP）と広めに確保する。

## Implementation

### Module

- source: [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) `~> 6.0`。
- 既存 3 サービス（raw リソース定義）とは実装方針が異なるが、本サービスでは記述量削減とエッジケース吸収のため意識的にモジュール利用に切り替える。

### Key Module Inputs

```hcl
name = "${var.project_name}-${var.environment}"
cidr = var.vpc_cidr                    # "10.0.0.0/16"
azs  = var.availability_zones          # ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

public_subnets   = var.public_subnet_cidrs
private_subnets  = var.private_subnet_cidrs
database_subnets = var.database_subnet_cidrs

enable_nat_gateway     = true
single_nat_gateway     = true
one_nat_gateway_per_az = false

enable_dns_support   = true
enable_dns_hostnames = true

create_database_subnet_group           = true
create_database_subnet_route_table     = true
create_database_internet_gateway_route = false
create_database_nat_gateway_route      = false
```

### Files

```
aws/vpc/
├── Makefile                        # 既存サービスの Makefile を踏襲（ENV=production）
├── root.hcl                        # aws/claude-code/root.hcl と同パターン、project_name = "vpc"
├── modules/
│   ├── main.tf                     # module "vpc" { source = "terraform-aws-modules/vpc/aws" ... }
│   ├── variables.tf                # vpc_cidr, availability_zones, *_subnet_cidrs, single_nat_gateway
│   ├── outputs.tf                  # 下記 Outputs を参照
│   └── terraform.tf                # terraform >= 1.14.8, aws ~> 6.40 (既存サービスと揃える)
└── envs/
    └── production/
        ├── terragrunt.hcl          # include root + env、terraform.source = "../../modules"
        └── env.hcl                 # environment = "production", aws_region = "ap-northeast-1"
```

### Outputs

- `vpc_id`, `vpc_cidr_block`
- `public_subnet_ids`, `private_subnet_ids`, `database_subnet_ids`
- `public_subnet_cidrs`, `private_subnet_cidrs`, `database_subnet_cidrs`
- `database_subnet_group_name`（RDS モジュール側が参照しやすいように）
- `nat_public_ips`（IP allowlist 用）
- `availability_zones`

### State

既存の共有バックエンド（`aws/claude-code/root.hcl` 参照）を再利用する。

- Bucket: `terragrunt-state-<account_id>`
- Key: `platform/vpc/production/terraform.tfstate`
- Lock table: `terragrunt-state-locks`

## Data Flow / Failure Modes

- Public サブネット: IGW 経由で ingress / egress。
- Private サブネット: NAT GW 経由で egress。単一 NAT のため AZ 1a 障害で全 private サブネットの egress が停止する。コスト優先で許容するが、可用性要件が上がれば `single_nat_gateway = false` に切り替えて再検討する。
- Database サブネット: 仕様として internet 経路を持たない。RDS / ElastiCache は同一 VPC 内の private サブネットからアクセスする前提。クロスリージョンレプリケーションや SaaS 起因のローテーションが必要になったら VPC endpoint を後追いで追加する。

## Testing

- `envs/production/` で `terragrunt validate` を実行する。
- `terragrunt plan` の結果をレビューしてから apply する。
- Apply 後は `aws ec2 describe-vpcs`, `describe-subnets`, `describe-nat-gateways`, `describe-route-tables` でトポロジを確認する。

## Dependencies

- `workflow-config.yaml` で `production` 環境が有効化されていること（本ブランチ上に未コミットの編集として存在）。これが CI 側で本サービスの production stack をターゲットにするための前提条件となる。
