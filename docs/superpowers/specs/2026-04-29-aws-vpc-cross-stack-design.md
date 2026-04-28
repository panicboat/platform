# aws/vpc — Cross-Stack Lookup Design

## Purpose

`aws/vpc` の出力（VPC ID、各層 subnet、DB subnet group など）を、tfstate を介さずタグベースで他 stack（直近想定: EKS / ECS / RDS / ALB）から取得できるようにする。VPC stack のリソースを破棄しても消費者側コードが壊れにくい疎結合を実現する。

## Scope

### In Scope

- `aws/vpc/modules/` の subnet に `Tier` タグ（`public` / `private` / `database`）を追加
- `aws/vpc/lookup/` を新設し、AWS data source（`aws_vpc` / `aws_subnets` / `aws_db_subnet_group`）をラップした再利用 Terraform module を提供
- リポジトリ規約として、producer-owned lookup は `aws/<service>/lookup/` 同居、汎用 module は `aws/_modules/<name>/` 配置とすることを明文化
- `aws/_modules/.gitkeep` を追加して将来の汎用 module 受け皿を用意（実体は本 spec の対象外）

### Out of Scope

- `aws/_modules/` 配下の具体モジュール（必要時に別 spec で追加）
- 消費者 stack（EKS / ECS / RDS / ALB）の本体作成（lookup の使用例として一時 plan 検証のみ実施）
- `aws/vpc` の `develop` / `staging` 環境追加（`2026-04-16-aws-vpc-design.md` の方針を踏襲し、必要時に複製）
- `terraform_remote_state` data source 経由の参照方式
- SSM Parameter Store をサービスレジストリとする方式

## Background

### 採択した却下条件

消費者は VPC の出力を以下の制約で得たい：

1. **tfstate を直接読まない**（state アクセス権分離・依存の隠れた結合を回避）
2. **producer のリソース破棄に対して消費者側コードが壊れにくい**（タグ／命名規約での自己発見）

### 検討した方式

| 案 | 概要 | 採否 |
|---|---|---|
| Terragrunt `dependency` ブロック | 他 stack の tfstate 出力を読む | ✗（条件 1 違反） |
| `data "terraform_remote_state"` | 同上 | ✗（条件 1 違反） |
| 各消費者で `data "aws_vpc"` 直書き | 共有モジュールなし | ✗（同 lookup ロジックが 4+ stack に重複） |
| **共有 lookup module + AWS data source** | 本 spec の採択案 | ✓ |
| SSM Parameter Store | producer が SSM に publish、consumer が `data "aws_ssm_parameter"` で読む | ✗（パラメータ運用負担、`StringList` 規約整備が必要） |

## Architecture

### Directory Layout

```
aws/
  vpc/
    modules/                  # 既存：VPC 本体（リソース定義）
    lookup/                   # 新規：data source ラッパ
      terraform.tf
      variables.tf
      main.tf
      outputs.tf
    envs/production/          # 既存
    root.hcl                  # 既存
    Makefile                  # 既存
  _modules/                   # 新規：枠のみ
    .gitkeep
```

### 配置規約（本 spec で確定）

| 種別 | 配置先 | 例 |
|---|---|---|
| Stack（自前 tfstate を持つデプロイ単位） | `aws/<service>/` + `envs/<env>/` | `aws/vpc/envs/production/` |
| Producer-owned lookup（特定 stack の出力をタグで読み出す） | `aws/<service>/lookup/` | `aws/vpc/lookup/` |
| 汎用 resource-set module（producer 紐付けなし） | `aws/_modules/<name>/` | `aws/_modules/<future-module>/` |

### 参照パス規約

- Producer-owned lookup: consumer の `aws/<consumer>/modules/main.tf` から `source = "../../vpc/lookup"`
- 汎用 module: 同上の規則で `source = "../../_modules/<name>"`

### Terragrunt キャッシュ越しの相対 module 解決

Terragrunt は consumer の `terragrunt.hcl` 評価時に `terraform.source` で指定したディレクトリをキャッシュ（`.terragrunt-cache/<hash1>/<hash2>/`）にコピーし、その内部で `terraform` を実行する。consumer の `main.tf` が `module "vpc" { source = "../../vpc/lookup" }` と書いても、`source = "../../modules"` でコピーされたキャッシュには consumer 側の `modules/` しか含まれず lookup には到達できない。

これを解決するため、各 consumer の `terragrunt.hcl` で go-getter の `//` subdir 記法を使い、`source` を `aws/` 全体に広げて working directory を `<consumer>/modules` に指定する。これによりキャッシュには `aws/` 配下の全 stack（自分の `modules/` と `aws/vpc/lookup/` を含む）がコピーされ、`module "vpc" { source = "../../vpc/lookup" }` が解決される。

```hcl
# aws/<consumer>/envs/<env>/terragrunt.hcl の terraform ブロック
terraform {
  source = "../../..//<consumer>/modules"
}
```

パス解釈:
- `../../..` は `aws/` を指す（`aws/<consumer>/envs/<env>/` から 3 階層上）
- `//<consumer>/modules` は `aws/` 内のサブディレクトリで、cache 内の working directory となる

Terragrunt v1.0.3 で動作確認済み。`include_in_copy` は同一 source dir 内のファイルをコピー対象に含めるための機能で、外部ディレクトリのコピーには使えない仕様（[公式ドキュメント参照](https://docs.terragrunt.com/reference/hcl/blocks)）。

### consumer 側のキャッシュサイズ

`aws/` 配下の全 stack が cache にコピーされる。`aws/` ディレクトリは tfvars / lock / Makefile を含めて数 MB 程度のため実用上の負担は無視できる。stack 追加で線形に増えるが、各 consumer の cache はローカルに 1 度生成すれば再利用される。

### workflow-config.yaml への影響

- `stack_conventions` の `aws/{service}` 規約は `envs/{environment}` の存在で stack を識別するため、`lookup/` のみのディレクトリ・`_modules/` 配下は CI のデプロイ対象外
- 設定変更は不要

## Implementation

### 1. Producer 側（`aws/vpc/modules/main.tf`）の変更

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "vpc-${var.environment}"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = false

  enable_dns_support   = true
  enable_dns_hostnames = true

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  public_subnet_tags   = { Tier = "public" }
  private_subnet_tags  = { Tier = "private" }
  database_subnet_tags = { Tier = "database" }

  tags = var.common_tags
}
```

差分は `*_subnet_tags` 3 行のみ。subnet ID やルーティングは変わらず、各 subnet に `Tier` タグの in-place update が発生する。

### 2. Lookup module（`aws/vpc/lookup/`）

#### `terraform.tf`

```hcl
terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
```

Lookup module は consumer 側の AWS provider を共有するため、provider 宣言は持たない。version は range で指定する。

#### `variables.tf`

```hcl
variable "environment" {
  description = "Environment name used to locate the VPC (matches the producer's `vpc-$${environment}` Name tag)."
  type        = string
}
```

VPC 名は `vpc-<environment>` 規約で固定。override 引数は導入しない。

#### `main.tf`

```hcl
data "aws_vpc" "this" {
  tags = {
    Name = "vpc-${var.environment}"
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "public" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "private" }
}

data "aws_subnets" "database" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "database" }
}

data "aws_db_subnet_group" "this" {
  name = "vpc-${var.environment}"
}
```

VPC は `Name` タグで一意に識別。subnet は `vpc-id` × `Tier` タグの AND で識別する（`Name` 命名規則には依存しない）。DB subnet group は `terraform-aws-modules/vpc/aws` 既定で `name = "vpc-${environment}"` となる。

#### `outputs.tf`

全 output を pass-through 方式で公開する。

```hcl
output "vpc" {
  description = "VPC data source (pass-through). See AWS provider docs for aws_vpc."
  value       = data.aws_vpc.this
}

output "subnets" {
  description = "Subnets grouped by tier (pass-through of aws_subnets data sources)."
  value = {
    public   = data.aws_subnets.public
    private  = data.aws_subnets.private
    database = data.aws_subnets.database
  }
}

output "db_subnet_group" {
  description = "DB subnet group data source (pass-through). See AWS provider docs for aws_db_subnet_group."
  value       = data.aws_db_subnet_group.this
}
```

参照例：

| 用途 | 参照式 |
|---|---|
| VPC ID | `module.vpc.vpc.id` |
| VPC CIDR | `module.vpc.vpc.cidr_block` |
| public subnet IDs | `module.vpc.subnets.public.ids` |
| private subnet IDs | `module.vpc.subnets.private.ids` |
| database subnet IDs | `module.vpc.subnets.database.ids` |
| DB subnet group 名 | `module.vpc.db_subnet_group.name` |

### 3. 汎用 module 受け皿（`aws/_modules/.gitkeep`）

将来の汎用 resource-set module 用にディレクトリを確保する。本 spec では空の `.gitkeep` のみ追加し、実体は別 spec で扱う。

## Data Flow

### plan / apply タイミング

```
[consumer stack]               [aws/vpc/lookup]              [AWS API]
terragrunt plan
  → terraform plan
    → module "vpc" 評価
      → data "aws_vpc"     → DescribeVpcs (tag:Name)
      → data "aws_subnets" → DescribeSubnets (vpc-id + tag:Tier)
      → data "aws_db_subnet_group" → DescribeDBSubnetGroups
    ← outputs を consumer の resource block に渡す
  ← consumer リソースの差分計算
```

- AWS API コールは consumer の `terraform plan` 時に毎回走る（数秒の追加遅延）
- producer / consumer は同一 region である必要がある（consumer 側 provider の region で API を引くため）

### 失敗モード

| 症状 | 原因 | 対処 |
|---|---|---|
| `data "aws_vpc"` が "no matching VPC" | producer 未 apply / `Name` タグ不一致 / region 不一致 | producer apply 確認、`var.environment` の値確認、provider region 確認 |
| `data "aws_subnets"` が空（`ids = []`） | `Tier` タグ未付与（producer 側変更が apply されていない） | producer の差分 apply |
| `data "aws_db_subnet_group"` 404 | DB subnet group 名が `vpc-${env}` でない | producer の `terraform-aws-modules/vpc/aws` 設定確認（`database_subnet_group_name` 上書きしていないか） |
| 同タグ VPC が複数ヒット | 同一アカウント・同一 region に同名 VPC | アカウント／環境分離見直し（運用上ほぼ起きない） |

## Testing

### 1. lookup module 単体の構文検証

```bash
terraform -chdir=aws/vpc/lookup init -backend=false
terraform -chdir=aws/vpc/lookup validate
```

### 2. producer 側の `Tier` タグ追加 plan / apply 確認

```bash
cd aws/vpc/envs/production
terragrunt plan
```

期待: 全 subnet（public/private/database 各 3 個）に `Tier` タグの in-place update のみ。リソース置換なし。

apply 後に確認：

```bash
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=<vpc-id> Name=tag:Tier,Values=public \
  --query 'Subnets[].SubnetId' --output table
```

各 Tier で 3 件返ること。

### 3. lookup の動作確認（仮 consumer + Terragrunt 経由）

`include_in_copy` 込みで Terragrunt がキャッシュへ lookup を同梱し、`terraform validate` / `terragrunt plan` が成功することを検証する。配置：

```
aws/_test-consumer/                   # 検証専用、検証後に削除
  modules/
    terraform.tf
    variables.tf
    main.tf
  envs/
    production/
      terragrunt.hcl
      env.hcl
```

`aws/_test-consumer/modules/terraform.tf`:

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
}
```

`aws/_test-consumer/modules/variables.tf`:

```hcl
variable "environment" { type = string }
variable "aws_region"  { type = string }
```

`aws/_test-consumer/modules/main.tf`:

```hcl
module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}

output "debug" {
  value = {
    vpc_id       = module.vpc.vpc.id
    vpc_cidr     = module.vpc.vpc.cidr_block
    public_ids   = module.vpc.subnets.public.ids
    private_ids  = module.vpc.subnets.private.ids
    database_ids = module.vpc.subnets.database.ids
    db_group     = module.vpc.db_subnet_group.name
  }
}
```

`aws/_test-consumer/envs/production/env.hcl`:

```hcl
locals {
  environment = "production"
  aws_region  = "ap-northeast-1"
}
```

`aws/_test-consumer/envs/production/terragrunt.hcl`:

```hcl
include "env" {
  path   = "env.hcl"
  expose = true
}

terraform {
  source = "../../..//_test-consumer/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region
}
```

`include "root"` は意図的に持たない（検証は state を必要としないため）。

検証手順（OpenTofu を terraform engine として使う場合は `TG_TF_PATH=tofu` を指定）：

```bash
cd aws/_test-consumer/envs/production
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt validate
TG_TF_PATH=tofu terragrunt plan   # AWS 認証が通っていれば lookup の data source が解決され、output debug の値が表示される
```

期待: キャッシュ（`.terragrunt-cache/<h1>/<h2>/`）配下に `aws/` 全体がコピーされ、その中の `_test-consumer/modules/` が working directory となる。同階層の `vpc/lookup/` も含まれるので `module.vpc.*` が解決される。確認後 `aws/_test-consumer/` をディレクトリごと削除し、本 PR の最終 commit には残さない。

### 4. CI 影響確認

- `aws/vpc/lookup/` に `envs/` がないため workflow-config の stack 解決で拾われない
- `aws/_modules/` も同様（`envs/` 不在）
- 既存 PR 既定 stack（`aws/vpc/envs/production`）の plan/apply には影響なし

## Trade-offs Accepted

- **subnet ID の順序が未定**: `data "aws_subnets"` は ids をソートせず返す。order 依存が必要な consumer 側で `sort()` を呼ぶ
- **不要フィールドの露出**: pass-through によって `data.aws_subnets.public.filter` 等の入力フィールドも参照可能になる。実害なし（`.ids` のみ使えばよい）
- **AWS provider スキーマ変更影響**: フィールド削除があれば consumer の参照が壊れる。AWS provider のフィールド削除はほぼ起きないため許容
- **plan 時の AWS API 遅延**: consumer の `terraform plan` ごとに data source 解決が走る（数秒）
- **consumer 側 `terragrunt.hcl` の `source` 規約変更**: lookup を利用する consumer は既存パターン `source = "../../modules"` の代わりに `source = "../../..//<service>/modules"` （go-getter `//` subdir 記法）を使う。`aws/` 全体が cache にコピーされる代わりに `include_in_copy` のような追加設定は不要。git source 化すれば network 経由で完全独立にできるが、ローカル参照を維持してオフライン動作と silent な version 流入回避を優先する

## Dependencies

- `aws/vpc/envs/production` が apply 済みで、本 spec の `Tier` タグ追加変更も apply されていること（lookup の前提）
- consumer 側の AWS provider が `aws/vpc` と同一 region で設定されていること

## Future Work（参考）

- 消費者（EKS / ECS / RDS / ALB）の stack 新設 PR で本 lookup を実利用する
- subnet 単位の CIDR / AZ が欲しくなった場合、`data "aws_subnet" "<tier>" { for_each = toset(...) }` を lookup に追加し、`subnets.<tier>.details = ...` のような追加キーで露出する（既存参照を壊さない）
- `aws/vpc` に `develop` / `staging` 環境を追加する場合は `envs/production/` を複製。lookup 側は `var.environment` を切り替えるだけで対応可能
