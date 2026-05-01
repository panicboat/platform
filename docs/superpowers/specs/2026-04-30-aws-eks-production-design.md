# aws/eks — Production EKS Cluster Design

## Purpose

`ap-northeast-1` の production VPC（`aws/vpc/envs/production`）上に EKS クラスタ `eks-production` を構築する。将来的に `kubernetes/components/*/production/` で展開するプラットフォームコンポーネント（Cilium / Prometheus-Operator / Loki / Tempo / OTel Collector / Beyla 等）と、その後乗せるアプリケーションワークロードのホスト基盤を提供する。

GitOps（Flux CD）前提のため、クラスタ作成後の Kubernetes リソース変更は CI / 人手ではなく Flux 経由で行う。本 spec のスコープは AWS リソース（cluster / node group / IAM / addon / Access Entry）の構築のみ。

## Scope

### In Scope

- `aws/{service}/modules + envs/{env}` 規約に沿って `aws/eks/` を新設し、`production` 環境を構築。
- 含めるリソース：
  - EKS Cluster（v1.33、public + private endpoint、Access Entries モード）
  - Initial Managed Node Group `system`（m6g.large × 2-4、AL2023_ARM_64、ON_DEMAND、3 AZ private subnet 配置）
  - Cluster IAM role / Node IAM role（SSM Session Manager 権限含む）
  - IRSA OIDC provider（EKS module が自動作成）
  - Add-ons：vpc-cni / kube-proxy / coredns / aws-ebs-csi-driver / eks-pod-identity-agent
  - Addon 用 IRSA ロール（vpc-cni、ebs-csi-driver）
  - CloudWatch Log group（control plane logs：audit + authenticator、retention 7 日）
  - Access Entry：人間 kubectl 用 admin role を `AmazonEKSClusterAdminPolicy` で登録
  - 新規 IAM role `eks-admin-production`（人間 kubectl 用）
- VPC 出力の参照は `aws/vpc/lookup` を経由（terragrunt `dependency` ブロックは使わない）。
- `.github/renovate.json` に customManager を追加し、`env.hcl` の `cluster_version` を `endoflife-date` datasource で自動更新対象にする。

### Out of Scope（次以降の spec で扱う）

- `kubernetes/clusters/production/` の Flux bootstrap（GitRepository / Kustomization）。
- `kubernetes/components/*/production/` の作成と動作確認（multi-arch image 検証、Cilium chaining mode 設定含む）。
- `helmfile.yaml.gotmpl` の production 環境追加。
- Karpenter（`aws/karpenter/envs/production/` を別 spec で）。
- ALB Ingress Controller / external-dns / cert-manager 等のクラスタ内コントローラ。
- Secrets KMS envelope encryption（現時点で機密データ要件なし、後追い可）。
- StorageClass `gp3` の default 切替（Kubernetes provider が必要なため次の Kubernetes spec へ）。
- VPC endpoint（S3 / ECR / STS 等。NAT GW 経由の egress コスト最適化として後追い）。
- VPC Flow Logs / GuardDuty for EKS。
- Cluster autoscaler（Karpenter で代替予定）。
- `develop` / `staging` 環境の追加（必要時に `envs/production/` を複製）。

## Background

### 採択した方針

| 論点 | 採択 | 却下した代替案と理由 |
|---|---|---|
| Compute モデル | Managed Node Groups + 将来 Karpenter（別 spec） | Fargate 単独：DaemonSet（Cilium / Prometheus / OTel / Beyla）が動かない。Karpenter 同時導入：判断軸が増えレビュー濃度が落ちる。 |
| API endpoint | public + private 両方有効、public は CIDR 制限なし | private only：CI / ローカル kubectl で VPN/bastion 必須。public IP allowlist：GitHub Actions runner の IP レンジ運用が破綻しがち。 |
| 認証方式 | Access Entries（`authentication_mode = "API"`） | aws-auth ConfigMap：legacy、ConfigMap 編集の競合リスク。SSO 連携：solo dev でオーバースペック。 |
| CNI | Cilium chaining mode（次 spec で適用、本 spec は VPC CNI を残す前提） | Cilium replace mode：Pod IP が VPC IP でなくなり、Security Group for Pods / ALB IP target / VPC Flow Logs での Pod 観測が破綻。VPC CNI のみ：Cilium の L7 / NetworkPolicy / Hubble を捨てる。 |
| Addons | vpc-cni / kube-proxy / coredns / aws-ebs-csi-driver / eks-pod-identity-agent | mountpoint-s3 / efs CSI：要件未確立。snapshot-controller：当面 backup 戦略を持たない。 |
| Compute IAM | CI apply role には Kubernetes RBAC を付与しない | `bootstrap_cluster_creator_admin_permissions = true` + apply role 明示登録：CI が暗黙に Kubernetes admin 権限を持ち GitOps 原則に反する。GitOps では Flux 経由でしか Kubernetes リソースを変更しないため、CI に Kubernetes admin は不要。 |
| 人間 kubectl | 専用 IAM role `eks-admin-production` を新設、Access Entry に登録 | account 内既存 `AdministratorAccess` を流用：assume 権限が AWS admin 全般と紐づきすぎ、EKS だけのデバッグ用途には過大。 |
| VPC 参照 | `aws/vpc/lookup` を `module "vpc"` として呼び出す | terragrunt `dependency` ブロック：`aws/vpc/lookup` cross-stack lookup spec で却下済（tfstate 結合を作らない方針）。 |
| EKS module | `terraform-aws-modules/eks/aws` 21.19.0（exact pin） | raw resource 自前定義：boilerplate（IRSA 設定、addon 依存順、access entry）が多くレビュー負担増。`aws/vpc` も `terraform-aws-modules/vpc/aws` を採用しており整合。 |

### Out of Scope の依存

- `kubernetes/components/cilium/production/` で Cilium を `cni.chainingMode=aws-cni` / `kubeProxyReplacement=false` で構成する想定。本 spec では VPC CNI と kube-proxy を有効のまま残し、Cilium の動作前提を整えるところまで。

## Architecture

### 全体像

```
                 GitHub Actions (apply role, OIDC)
                        │  AWS API (eks:*, iam:*, ec2:*)
                        │  ※ Kubernetes API は触らない
                        ▼
         ┌──────────────────────────────┐
         │  EKS Control Plane (1.33)    │   public + private endpoint
         │  authentication_mode = API   │   (Access Entries only)
         │  Logs: audit + authenticator │── CloudWatch Logs (7 day retention)
         │  IRSA OIDC provider          │
         └────────────┬─────────────────┘
                      │ via private endpoint
                      ▼
         ┌──────────────────────────────────────┐
         │  Managed Node Group "system"         │
         │  m6g.large × 2-4, AL2023_ARM_64,     │
         │  ON_DEMAND, gp3 50 GiB, SSM access   │
         │  Spread across 3 AZ private subnets  │
         └──────────────────────────────────────┘
                      │
                      ▼
         ┌──────────────────────────────────────┐
         │  AWS-managed addons                  │
         │  vpc-cni (IRSA) ─ Cilium chaining 前提│
         │  kube-proxy                          │
         │  coredns                             │
         │  aws-ebs-csi-driver (IRSA)           │
         │  eks-pod-identity-agent              │
         └──────────────────────────────────────┘

         ┌──────────────────────────────────────┐
         │  Human kubectl path                  │
         │  IAM user (account 559744160976)     │
         │   → sts:AssumeRole                   │
         │   → eks-admin-production role        │
         │      (eks:DescribeCluster only)      │
         │   → Access Entry: ClusterAdmin RBAC  │
         │   → kubectl                          │
         └──────────────────────────────────────┘

         ┌──────────────────────────────────────┐
         │  GitOps path (本 spec の Out of Scope) │
         │  Flux CD (in-cluster SA)             │
         │   → Git polling                       │
         │   → reconcile Kubernetes resources    │
         └──────────────────────────────────────┘
```

### Cluster

| 項目 | 値 |
|---|---|
| name | `eks-production` |
| version | `1.33`（renovate marker で `endoflife-date/amazon-eks` から自動更新） |
| endpoint | `endpoint_public_access = true`（CIDR 制限なし）/ `endpoint_private_access = true` |
| authentication_mode | `API`（aws-auth ConfigMap 無効化） |
| `enable_cluster_creator_admin_permissions` | `false`（GitOps 原則：暗黙 admin を作らない） |
| Secrets envelope encryption | 無効（Out of Scope） |
| IRSA | 有効（OIDC provider 自動作成） |
| Subnet | `aws/vpc/lookup` 経由で `private` tier の 3 AZ subnet を取得 |
| Cluster security group | EKS module のデフォルト挙動に委譲（cluster SG + 追加 SG） |

### Control plane logging

- 出力対象：`audit`, `authenticator` のみ（`api` / `controllerManager` / `scheduler` は除外）
- CloudWatch Log group：`/aws/eks/eks-production/cluster`
- retention：7 日
- KMS：CloudWatch Logs 用 KMS は使用しない（AWS 管理キー）

### Node Group: `system`

| 項目 | 値 |
|---|---|
| AMI type | `AL2023_ARM_64_STANDARD` |
| Instance type | `m6g.large`（Graviton ARM64、2 vCPU / 8 GiB） |
| Capacity type | `ON_DEMAND` |
| desired / min / max | `2 / 2 / 4` |
| Subnet | `aws/vpc/lookup` の private subnet IDs（3 AZ 全部） |
| Disk | gp3 / 50 GiB |
| Update strategy | `max_unavailable_percentage = 33` |
| Labels | `node-role/system = "true"` |
| Taints | なし（initial group なので汚染しない。Karpenter 導入時に system 専有を再検討） |
| Remote access | SSM Session Manager のみ（SSH key なし、22 番閉鎖） |

### IAM

#### Role 一覧

| Role | 用途 | Managed Policy | 備考 |
|---|---|---|---|
| Cluster IAM role | EKS control plane 用 | `AmazonEKSClusterPolicy`（module デフォルト） | EKS module が自動生成 |
| Node IAM role | Node group 用 | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore` | `AmazonEKS_CNI_Policy` は **付けない**（IRSA 経由で付与） |
| IRSA: vpc-cni | aws-node SA → ENI 操作 | `AmazonEKS_CNI_Policy` | EKS module の `addons` 設定で IRSA 自動連携 |
| IRSA: ebs-csi-driver | controller SA → EBS 操作 | `AmazonEBSCSIDriverPolicy` | 同上 |
| `eks-admin-production` | 人間 kubectl 用 | inline policy `eks:DescribeCluster` のみ | 本 spec で新規作成。詳細下記 |

#### `eks-admin-production` role 詳細

| 項目 | 値 |
|---|---|
| Role 名 | `eks-admin-${var.environment}` → `eks-admin-production` |
| Trust policy Principal | `arn:aws:iam::559744160976:root`（account 内 principal からの assume を許可） |
| Trust policy Condition | なし（MFA 必須化は今後の spec で追加） |
| Inline policy | `eks:DescribeCluster`（`Resource: arn:aws:eks:ap-northeast-1:559744160976:cluster/eks-production` で絞る） |
| Max session duration | `3600`（1 時間） |
| Tags | `common_tags` 継承 |

利用フロー（README 等に記述する想定）:

```bash
# 1. IAM user に sts:AssumeRole 権限がある状態で
aws sts assume-role \
  --role-arn arn:aws:iam::559744160976:role/eks-admin-production \
  --role-session-name kubectl-debug

# 2. credentials を環境変数にセット
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...

# 3. kubeconfig 取得 → kubectl
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production
kubectl get nodes
```

### Access Entries

| Principal | Type | Policy | Scope |
|---|---|---|---|
| `aws_iam_role.eks_admin.arn`（= `eks-admin-production`） | `STANDARD` | `arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy` | `cluster` |

CI 上の `github-oidc-auth-production-github-actions-role` は **Access Entry に登録しない**。CI は AWS API（`eks:*`）のみで EKS リソースを管理し、Kubernetes API は叩かない。Kubernetes リソース変更はすべて Flux 経由。

### Add-ons

すべて AWS-managed addon として宣言：

| Addon | バージョン解決 | Conflict resolution | IRSA |
|---|---|---|---|
| `vpc-cni` | `most_recent = true` | `OVERWRITE` (create / update) | あり（`AmazonEKS_CNI_Policy`） |
| `kube-proxy` | EKS バージョン追従 | `OVERWRITE` | なし |
| `coredns` | `most_recent = true` | `OVERWRITE` | なし |
| `aws-ebs-csi-driver` | `most_recent = true` | `OVERWRITE` | あり（`AmazonEBSCSIDriverPolicy`） |
| `eks-pod-identity-agent` | `most_recent = true` | `OVERWRITE` | なし |

### Failure modes

| 症状 | 原因 | 対処 |
|---|---|---|
| `module "vpc"` が "no matching VPC" | `aws/vpc/envs/production` 未 apply、または `Tier` タグ未追加 | VPC stack を先に最新化して apply |
| `module "vpc"` の `subnets.private.ids` が空 | `Tier=private` タグ未付与 | 上に同じ |
| AZ 1a 障害時の egress 断 | VPC spec で single NAT GW を採用 | 許容済み（VPC spec のトレードオフ） |
| node 数不足での platform 起動失敗 | desired=2 で 1 ノード喪失 | max=4 への手動拡張で復旧、Karpenter 導入後は自動化 |
| EBS volume の AZ ローカル制約 | gp3 は AZ ローカル | 次の Kubernetes spec で StatefulSet の AZ 配置を考慮 |
| EKS バージョン upgrade 時の互換性破壊 | renovate PR で minor up | production パスは automerge 無効、手動レビュー必須 |
| Access Entry 設定漏れ | `eks-admin-production` の作成失敗 | `enable_cluster_creator_admin_permissions = false` のため誰も admin にならない。terragrunt destroy → 再 apply で復旧 |

## Implementation

### Directory layout

```
aws/eks/
├── Makefile                       # aws/vpc/Makefile を踏襲（ENV=production）
├── root.hcl                       # aws/vpc/root.hcl 同パターン、project_name = "eks"
├── modules/
│   ├── main.tf                    # module "eks" 本体
│   ├── lookups.tf                 # module "vpc"（aws/vpc/lookup を参照）
│   ├── node_groups.tf             # locals.eks_managed_node_groups
│   ├── addons.tf                  # locals.cluster_addons
│   ├── access_entries.tf          # locals.access_entries
│   ├── iam_admin.tf               # eks-admin-production role
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tf               # required_version, hashicorp/aws ピン留め
└── envs/
    └── production/
        ├── terragrunt.hcl         # include root + env, source = "../../..//eks/modules"
        ├── env.hcl                # environment / aws_region / cluster_version
        └── .terraform.lock.hcl    # commit する（既存 aws/vpc 方針と揃える）
```

### `modules/terraform.tf`

```hcl
terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.42.0"
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

`aws/vpc/modules/terraform.tf` と完全同一。AWS provider は exact pin、lock file は env 配下に commit する。

### `modules/lookups.tf`

```hcl
# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
```

`aws/vpc/lookup` の outputs（`vpc.id`, `subnets.private.ids` 等）を以降の `module "eks"` から `module.vpc.*` で参照する。

### `modules/main.tf`

```hcl
# main.tf - EKS cluster composition via terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  eks_managed_node_groups = local.eks_managed_node_groups
  addons                  = local.cluster_addons
  access_entries          = local.access_entries

  tags = var.common_tags
}
```

> 引数名は `terraform-aws-modules/eks/aws` v21 系のもの。実装時に v21.19.0 のドキュメントで最終確認する（特に `addons` / `cloudwatch_log_group_retention_in_days` の名称・存在）。

### `modules/node_groups.tf`

```hcl
locals {
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      disk_size = var.node_disk_size
      disk_type = "gp3"

      labels = {
        "node-role/system" = "true"
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        # Node IAM role に SSM Session Manager 権限を追加
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }
}
```

### `modules/addons.tf`

```hcl
locals {
  cluster_addons = {
    vpc-cni = {
      most_recent              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn = module.eks.vpc_cni_irsa_role_arn  # module v21 の挙動を要確認
    }
    kube-proxy = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.eks.ebs_csi_irsa_role_arn  # 同上
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
}
```

> v21 の `addons` 引数で IRSA を関連付ける具体的な書き方は実装時に最終確認。`terraform-aws-modules/eks/aws` には `enable_irsa_xxx` 系 input または submodule を使うパターンがあり、最新ドキュメント参照が必須。

### `modules/access_entries.tf`

```hcl
locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
```

### `modules/iam_admin.tf`

```hcl
# iam_admin.tf - IAM role for human kubectl admin access via Access Entry.

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "eks_admin" {
  name                 = "eks-admin-${var.environment}"
  max_session_duration = 3600
  tags                 = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eks_admin_describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.eks_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/eks-${var.environment}"
      }
    ]
  })
}
```

### `modules/variables.tf`

```hcl
variable "environment" {
  type        = string
  description = "Environment name (e.g., production)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "common_tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to all resources"
}

variable "cluster_version" {
  type        = string
  description = "EKS Kubernetes version (e.g., \"1.33\")"
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["m6g.large"]
  description = "Instance types for the system managed node group"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size" {
  type        = number
  default     = 50
  description = "EBS volume size (GiB) for node group"
}

variable "log_retention_days" {
  type    = number
  default = 7
}
```

### `modules/outputs.tf`

```hcl
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Cluster security group created by EKS"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node security group"
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (for Karpenter / external addons)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "IRSA OIDC provider URL"
  value       = module.eks.oidc_provider
}

output "cluster_iam_role_arn" {
  description = "Cluster IAM role ARN"
  value       = module.eks.cluster_iam_role_arn
}

output "node_iam_role_arn" {
  description = "Node group IAM role ARN (for Karpenter etc.)"
  value       = module.eks.eks_managed_node_groups["system"].iam_role_arn
}

output "admin_role_arn" {
  description = "ARN of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.arn
}

output "admin_role_name" {
  description = "Name of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.name
}
```

### `root.hcl`

`aws/vpc/root.hcl` をそのまま踏襲し、`project_name = "eks"`、state key を `platform/eks/${local.environment}/terraform.tfstate` に変更：

```hcl
locals {
  project_name = "eks"

  path_parts  = split("/", path_relative_to_include())
  environment = element(local.path_parts, length(local.path_parts) - 1)

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Repository  = "monorepo"
    Component   = "eks"
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
    key            = "platform/eks/${local.environment}/terraform.tfstate"
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

### `envs/production/env.hcl`

```hcl
locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  # renovate: datasource=endoflife-date depName=amazon-eks versioning=loose
  cluster_version = "1.33"

  environment_tags = {
    Environment = local.environment
    Purpose     = "eks"
    Owner       = "panicboat"
  }
}
```

### `envs/production/terragrunt.hcl`

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

terraform {
  source = "../../..//eks/modules"
}

inputs = {
  environment     = include.env.locals.environment
  aws_region      = include.env.locals.aws_region
  cluster_version = include.env.locals.cluster_version

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
```

ポイント：

- `dependency "vpc"` ブロックは持たない。VPC 情報は `module "vpc"` の data source 解決で得る。`aws/vpc/lookup` cross-stack lookup spec の規約に準拠。
- `terraform.source = "../../..//eks/modules"`：`../../..` は `aws/` を指し、`//eks/modules` が cache 内 working dir。これで `aws/` 全体が cache にコピーされ、`module "vpc" { source = "../../vpc/lookup" }` が解決される。

### Makefile

`aws/vpc/Makefile` を丸ごとコピーし、help テキストの "VPC" を "EKS" に差し替える。

### Renovate 連携

`.github/renovate.json` の末尾、既存 `packageRules` の後ろに `customManagers` セクションを追加する（既存 `packageRules` 自体は変更しない）：

```json
{
  "extends": ["..."],
  "...": "...",
  "packageRules": [ /* 既存のまま */ ],
  "customManagers": [
    {
      "customType": "regex",
      "description": "EKS Kubernetes version pinned in env.hcl",
      "fileMatch": ["^aws/eks/envs/.+/env\\.hcl$"],
      "matchStrings": [
        "#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)(?:\\s+versioning=(?<versioning>\\S+))?\\s*\\n\\s*cluster_version\\s*=\\s*\"(?<currentValue>[^\"]+)\""
      ]
    }
  ]
}
```

挙動：

- 既存 `packageRules` の `"matchPaths": ["**/production/**"]` ルールにより、`aws/eks/envs/production/env.hcl` の更新 PR は automerge 無効 + `⚠️ production` ラベル付き。手動 merge 必須。
- `versioning=loose` を指定するのは `1.33` 形式（major.minor、patch なし）に対応するため。
- `fileMatch` を `aws/eks/envs/.+/env\.hcl` にしているので、将来 `develop` / `staging` を追加した際にも自動で対象に入る。
- datasource `endoflife-date` の package `amazon-eks` は AWS 公式 EKS サポート期間情報源にマッチし、現在 supported な major.minor を返す。

### State

既存の共有バックエンドを再利用：

- Bucket：`terragrunt-state-559744160976`
- Key：`platform/eks/production/terraform.tfstate`
- Lock table：`terragrunt-state-locks`
- Region：`ap-northeast-1`

### CI 連携

- `workflow-config.yaml` の `production` 環境には既に `terragrunt` stack が登録済み。
- `aws/eks/envs/production` を新設すれば、既存の `stack_conventions: aws/{service}` 規約により label-resolver が自動的に terragrunt stack の対象として認識する。
- `workflow-config.yaml` 自体の編集は不要。

## Testing

### 1. 構文・lint（apply 不要）

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt validate
terraform fmt -recursive ../..
```

期待：`validate` 成功。go-getter `//` 記法でキャッシュに `aws/` 全体がコピーされ `aws/vpc/lookup` が解決されること。

注意：`module "vpc"` は data source なので `init` / `validate` でも AWS 認証が必要。AWS 認証情報がローカルにある状態で実行する。

### 2. plan 検証

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan -out=eks.tfplan
```

期待される出力（要点）：

- 新規作成リソース：
  - `module.eks.aws_eks_cluster.this[0]`
  - `module.eks.aws_iam_role.this[0]`（cluster role）
  - `module.eks.aws_eks_node_group.this["system"]`
  - `module.eks.aws_iam_role.eks_managed_node_group["system"]`（node role）
  - `module.eks.aws_iam_role_policy_attachment.*`（worker / ECR / SSM）
  - `module.eks.aws_iam_openid_connect_provider.oidc_provider[0]`
  - `module.eks.aws_eks_addon.this["vpc-cni"]` 他 4 addons
  - `module.eks.module.vpc_cni_irsa.aws_iam_role.this[0]` 他 IRSA role
  - `module.eks.aws_eks_access_entry.this["human_admin"]`
  - `module.eks.aws_eks_access_policy_association.this["human_admin_cluster_admin"]`
  - `module.eks.aws_cloudwatch_log_group.this[0]`（retention 7 日）
  - `aws_iam_role.eks_admin`
  - `aws_iam_role_policy.eks_admin_describe_cluster`
- VPC への変更がないこと（subnet / SG / route table 等の差分が無い）。
- `data "aws_vpc" "this"`, `data "aws_subnets" "private"` が解決済みで、`subnet_ids` に 3 つの ID が並ぶ。

### 3. apply

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt apply eks.tfplan
```

期待：エラーなく完了（クラスタ作成は 10〜15 分程度）。

### 4. apply 後の動作確認（人間 kubectl 経路）

```bash
# 1. eks-admin-production を assume
aws sts assume-role \
  --role-arn $(cd aws/eks/envs/production && terragrunt output -raw admin_role_arn) \
  --role-session-name kubectl-debug

# 2. credentials を環境変数にセット（出力 JSON から AccessKeyId / SecretAccessKey / SessionToken を抽出）
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...

# 3. kubeconfig 生成
aws eks update-kubeconfig --region ap-northeast-1 --name eks-production

# 4. control plane 接続確認
kubectl version
kubectl get nodes -o wide          # 期待: m6g.large × 2、3 AZ に分散、ARM64
kubectl get pods -A                # 期待: kube-system に aws-node, kube-proxy, coredns, ebs-csi-* が Running
kubectl get sa -n kube-system aws-node -o yaml | grep eks.amazonaws.com/role-arn
                                    # 期待: vpc-cni IRSA role の ARN がアノテーションされている
```

### 5. CI 連携確認

- 本 spec の PR 上で、`auto-label--deploy-trigger` が `aws/eks/envs/production` を terragrunt stack として認識し、`reusable--terragrunt-executor` で `terragrunt plan` が実行されること。
- PR コメントに plan 結果が貼られること。

### 6. Renovate 動作確認

```bash
# customManagers の構文確認
npx --yes renovate-config-validator .github/renovate.json
```

加えて、PR マージ後の最初の renovate スケジュール（平日 4am 前）で：

- `aws/eks/envs/production/env.hcl` の `cluster_version` が dependency dashboard issue に `amazon-eks` として現れること。
- 最新 EKS バージョン（執筆時点：1.33 が GA）に応じて適切に PR が起票される（または更新不要メッセージが表示される）こと。

### 7. ロールバック想定

- 部分的問題（特定 addon / node group）は terragrunt 経由で当該リソースだけ修正・再 apply。
- クラスタ全体破棄が必要な場合は `terragrunt destroy`。control plane 破棄に 5〜10 分。VPC や github-oidc-auth は影響を受けない。
- KMS は使っていないので、destroy で blocking する待機リソースなし。
- Access Entry は EKS API 経由で管理されているため、cluster 削除と同時に消える（aws-auth ConfigMap 残骸の懸念なし）。

## Trade-offs Accepted

- **`module "vpc"` の AWS API 呼び出し**：consumer の `terraform plan` ごとに data source 解決が走る（数秒の追加遅延）。`aws/vpc/lookup` 設計のトレードオフを継承。
- **public endpoint を CIDR 制限なしで開ける**：GitHub Actions IP allowlist 運用の破綻を避ける選択。EKS の認証は IAM 必須なので未認証アクセスは API レベルで弾かれる。
- **single NAT GW（VPC spec の決定）に依存する egress**：AZ 1a 障害時に全 private subnet egress 断。現時点のコスト最適化方針を継承。
- **`enable_cluster_creator_admin_permissions = false` による初回 apply の脆さ**：仮に Access Entry 設定に typo があると、誰も Kubernetes admin にアクセスできないクラスタが生まれる。terragrunt destroy → 再 apply で復旧する想定で許容。
- **MFA 必須化を見送る**：solo dev で MFA デバイス管理の運用負担を当面避ける。`eks-admin-production` の trust policy に condition 追加は後続 spec で対応。
- **`module.eks.vpc_cni_irsa_role_arn` 等の参照名は v21 系の最新ドキュメントで再確認が必要**：本 spec では `terraform-aws-modules/eks` v21 系のドキュメント未確定箇所があるため、実装プランで具体的な引数名を確定させる。

## Dependencies

- `aws/vpc/envs/production` が apply 済みかつ、cross-stack lookup spec で導入された `Tier` タグ追加が apply 済みであること（`module "vpc"` lookup の前提）。
- `aws/vpc/envs/production` の `terragrunt plan` が clean（追加変更なし）であること。残差分があるなら EKS apply 前に必ず VPC 側を先に apply する。
- `aws/github-oidc-auth/envs/production` が apply 済みで、`github-oidc-auth-production-github-actions-role` が存在し EKS / IAM / EC2 / KMS 操作権限を持っていること（CI から terragrunt apply するために必要）。
- consumer 側 provider の region（`ap-northeast-1`）が VPC と一致していること。
- `aws/_modules/.gitkeep` および `aws/vpc/lookup/` が main branch に取り込まれていること（cross-stack lookup spec の前提）。

## Future Work（参考）

- Karpenter 導入（`aws/karpenter/envs/production/`）：node group とは別経路でアプリケーション用ノードを動的プロビジョニング。
- Secrets KMS envelope encryption の有効化：機密データを扱うアプリ追加時。
- VPC endpoint（S3 / ECR / STS）：NAT GW egress コストが見えてきた段階で。
- VPC Flow Logs / GuardDuty for EKS：監査要件が出た段階で。
- `eks-admin-production` の MFA 必須化、source IP 制限：運用が安定した段階で trust policy に Condition 追加。
- ALB Ingress Controller / external-dns / cert-manager：Ingress 公開 workload を載せる段階で。
- `develop` / `staging` 環境の追加：必要時に `envs/production/` を複製。renovate fileMatch は対応済み。

## Errata（PR #234 マージ後の apply で判明した誤りと訂正）

PR #234（本 spec の初回実装）を apply した際に 2 件の誤り、および 1 件の version 古化が判明し、後続 PR で修正している。本セクションは設計判断の記録として残す（実装は後続 PR 反映済み）。

### E-1: Access Policy の `policy_arn` フォーマット誤り

**当初の指定**:

```hcl
policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
```

**誤り**: これは IAM Managed Policy の ARN フォーマット。`aws_eks_access_policy_association` には EKS 専用の Access Policy ARN フォーマット (`arn:aws:eks::aws:cluster-access-policy/<NAME>`) を渡す必要がある。

**訂正**:

```hcl
policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
```

apply 時に `InvalidParameterException: The policyArn parameter format is not valid` で失敗した。

### E-2: vpc-cni addon の bootstrap 順序

**当初の構成**: `aws/eks/modules/node_groups.tf` で `iam_role_attach_cni_policy = false` を指定し、CNI 権限を IRSA 経由で aws-node ServiceAccount に付与する設計を採用したが、`aws/eks/modules/addons.tf` の `vpc-cni` には `before_compute` を指定しなかった。

**誤り**: `before_compute` を指定しない場合、addon は node group 作成「後」に apply される。node 起動時には IRSA を使う aws-node DaemonSet がまだ動かず、CNI が機能しないため、ノードは Ready にならず `NodeCreationFailure: Unhealthy nodes in the kubernetes cluster` で node group が CREATE_FAILED になる。

**訂正**: `vpc-cni` に `before_compute = true` を追加。これで addon が node group 作成「前」に apply され、ノード起動時点で IRSA バウンドの aws-node が利用可能になる。

```hcl
vpc-cni = {
  before_compute              = true
  most_recent                 = true
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.vpc_cni_irsa.arn
}
```

### E-3: cluster_version の更新（1.33 → 1.35）

PR #234 では `cluster_version = "1.33"` で設計したが、後続 PR の作成時点で AWS EKS の最新標準サポートバージョンは `1.35` に更新済（1.33 / 1.34 / 1.35 が標準サポート）。新規 cluster 作成のため、最新 GA バージョンに揃える。

**注**: EKS の Kubernetes version は **1 minor ずつしか upgrade できない**（1.33 → 1.35 のような skip 不可）。PR #234 で作成された cluster は apply 失敗 + node group 未稼働により実質的に空状態だったため、`terragrunt destroy` で一旦破棄し、`1.35` で新規作成する方針を採った。

将来の minor up は Renovate（`endoflife-date/amazon-eks` datasource）が起票する PR を 1 minor ずつ手動 merge する運用とする。
