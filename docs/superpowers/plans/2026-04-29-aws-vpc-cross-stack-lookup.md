# AWS VPC Cross-Stack Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws/vpc` の出力（VPC / subnets / DB subnet group）を、tfstate を介さずタグベースで他 stack（EKS / ECS / RDS / ALB を直近想定）から取得できる lookup module を新設する。

**Architecture:** 既存 VPC stack の subnet に `Tier` タグを追加し、`aws/vpc/lookup/` に AWS data source（`aws_vpc` / `aws_subnets` / `aws_db_subnet_group`）をラップした再利用 Terraform module を実装する。consumer は Terragrunt の `include_in_copy` で lookup ディレクトリをキャッシュに同梱して `module` 参照する。汎用 module 用の枠として `aws/_modules/` を確保する（実体は別 spec）。

**Tech Stack:** OpenTofu/Terraform `>= 1.11.6`, Terragrunt, AWS provider `6.42.0`（producer）／`>= 6.0, < 7.0`（lookup）, `terraform-aws-modules/vpc/aws ~> 6.6`

**Spec:** `docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `aws/vpc/modules/main.tf` | modify | VPC module 呼び出しに `*_subnet_tags = { Tier = ... }` を追加 |
| `aws/vpc/lookup/terraform.tf` | create | lookup の `required_version` / `required_providers`（provider 宣言は持たない） |
| `aws/vpc/lookup/variables.tf` | create | 入力 `environment` の宣言 |
| `aws/vpc/lookup/main.tf` | create | `data "aws_vpc"` / `data "aws_subnets"` × 3 / `data "aws_db_subnet_group"` |
| `aws/vpc/lookup/outputs.tf` | create | `vpc` / `subnets` / `db_subnet_group` の pass-through output |
| `aws/_modules/.gitkeep` | create | 将来の汎用 module 用ディレクトリ確保 |
| `aws/_test-consumer/...` | ephemeral | Task 4 の動作確認専用、commit せず削除 |

---

### Task 1: VPC subnet に `Tier` タグを追加

**Files:**
- Modify: `aws/vpc/modules/main.tf`

`terraform-aws-modules/vpc/aws` の `*_subnet_tags` 入力で subnet 単位に `Tier` タグを付与する。これが lookup 側で subnet を識別するキーになる。subnet ID やルーティングは変わらず、in-place tag update のみ発生する。

- [ ] **Step 1: Edit `aws/vpc/modules/main.tf`**

`create_database_nat_gateway_route = false` 直後（空行の後）に 3 行を追加する：

Old:
```hcl
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  tags = var.common_tags
}
```

New:
```hcl
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

- [ ] **Step 2: Validate the module standalone (AWS 認証不要)**

Run: `terraform -chdir=aws/vpc/modules init -backend=false`
Expected: `terraform-aws-modules/vpc/aws` と AWS provider が取得され `Terraform has been successfully initialized!`

Run: `terraform -chdir=aws/vpc/modules validate`
Expected: `Success! The configuration is valid.`

`.terraform/` は `.gitignore` 済みのため未追跡ファイルは増えない。Terragrunt の backend 接続を介さないため AWS 認証なしで完了する。

- [ ] **Step 3: Format check**

Run: `terraform fmt -check aws/vpc/modules/main.tf`

Expected: 出力なし（exit 0）。差分が出る場合は `terraform fmt aws/vpc/modules/main.tf` を実行して再 commit。

- [ ] **Step 4: Commit**

```bash
git add aws/vpc/modules/main.tf
git commit -s -m "feat(aws/vpc): tag subnets with Tier for cross-stack lookup

aws/vpc/lookup から subnet を tag:Tier で識別するために、public / private / database 各 subnet group に Tier タグを付与する。Name 命名や AZ 構成への依存を避ける。"
```

---

### Task 2: lookup module の実装

**Files:**
- Create: `aws/vpc/lookup/terraform.tf`
- Create: `aws/vpc/lookup/variables.tf`
- Create: `aws/vpc/lookup/main.tf`
- Create: `aws/vpc/lookup/outputs.tf`

producer 側のタグ規約（`Name = vpc-${env}` と `Tier = public|private|database`）でリソースを動的 lookup し、pass-through output で公開する。consumer 側 provider を共有するため lookup 自身は `provider "aws"` を持たない。

- [ ] **Step 1: Create `aws/vpc/lookup/terraform.tf`**

```hcl
# terraform.tf - Version constraints for the VPC lookup module.
# This module does not declare a provider; consumers supply the aws provider.

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

- [ ] **Step 2: Create `aws/vpc/lookup/variables.tf`**

```hcl
# variables.tf - Inputs for the VPC lookup module.

variable "environment" {
  description = "Environment name used to locate the VPC (matches the producer's `vpc-$${environment}` Name tag)."
  type        = string
}
```

- [ ] **Step 3: Create `aws/vpc/lookup/main.tf`**

```hcl
# main.tf - Tag-based discovery of VPC, subnets, and DB subnet group.

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

- [ ] **Step 4: Create `aws/vpc/lookup/outputs.tf`**

```hcl
# outputs.tf - Pass-through outputs of the underlying data sources.

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

- [ ] **Step 5: Validate the module standalone**

Run: `terraform -chdir=aws/vpc/lookup init -backend=false`
Expected: `Terraform has been successfully initialized!`（provider のみ取得）

Run: `terraform -chdir=aws/vpc/lookup validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Format check**

Run: `terraform fmt -check -recursive aws/vpc/lookup`
Expected: 出力なし。差分があれば `terraform fmt -recursive aws/vpc/lookup` で修正。

- [ ] **Step 7: Commit**

```bash
git add aws/vpc/lookup
git commit -s -m "feat(aws/vpc): add lookup module for cross-stack VPC reference

aws_vpc / aws_subnets / aws_db_subnet_group の data source を tag ベースでラップし、consumer 側に pass-through output で公開する。tfstate には触れず疎結合を維持する。"
```

---

### Task 3: 汎用 module 用ディレクトリの確保

**Files:**
- Create: `aws/_modules/.gitkeep`

将来の producer 紐付けなし汎用モジュール用に枠を用意する。本タスクで実体は追加しない。

- [ ] **Step 1: Create the placeholder file**

Run: `mkdir -p aws/_modules && : > aws/_modules/.gitkeep`

Expected: `aws/_modules/.gitkeep` が空ファイルとして作成される。

- [ ] **Step 2: Verify the file is staged-able**

Run: `git status aws/_modules/`

Expected: `aws/_modules/.gitkeep` が untracked として表示される。

- [ ] **Step 3: Commit**

```bash
git add aws/_modules/.gitkeep
git commit -s -m "chore(aws/_modules): reserve directory for shared resource modules

producer に紐付かない汎用 Terraform module の置き場を確保する。実体は別 spec で追加する。"
```

---

### Task 4: 仮 consumer による include_in_copy 動作確認（commit なし）

このタスクは検証専用で、ファイルの commit は行わない。Terragrunt の `include_in_copy` 越しに lookup module の相対 source が解決されること、および pass-through output が consumer 側で参照可能であることを確認する。

**Files (ephemeral, NOT committed):**
- Create: `aws/_test-consumer/modules/terraform.tf`
- Create: `aws/_test-consumer/modules/variables.tf`
- Create: `aws/_test-consumer/modules/main.tf`
- Create: `aws/_test-consumer/envs/production/terragrunt.hcl`
- Create: `aws/_test-consumer/envs/production/env.hcl`

**Pre-condition:** Task 1 の `Tier` タグ追加が `aws/vpc/envs/production` に対して `terragrunt apply` 済みであること。未 apply の場合、Step 5 の plan で subnet が空となる（init / validate は影響なし）。

- [ ] **Step 1: Create `aws/_test-consumer/modules/terraform.tf`**

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

- [ ] **Step 2: Create `aws/_test-consumer/modules/variables.tf`**

```hcl
variable "environment" { type = string }
variable "aws_region"  { type = string }
```

- [ ] **Step 3: Create `aws/_test-consumer/modules/main.tf`**

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

- [ ] **Step 4: Create `aws/_test-consumer/envs/production/env.hcl`**

```hcl
locals {
  environment = "production"
  aws_region  = "ap-northeast-1"
}
```

- [ ] **Step 5: Create `aws/_test-consumer/envs/production/terragrunt.hcl`**

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

`include "root"` は意図的に持たない（state を必要としない動作確認のため）。`source` の `//` 記法は go-getter のサブディレクトリ指定で、`../../..` を `aws/` 全体としてコピーし、cache 内の `_test-consumer/modules/` を working directory とする。

- [ ] **Step 6: Run terragrunt init / validate (AWS auth 不要)**

Run: `cd aws/_test-consumer/envs/production && TG_TF_PATH=tofu terragrunt init`
Expected:
- `.terragrunt-cache/<hash1>/<hash2>/` に `aws/` 配下全体がコピーされる
- cache 内に `vpc/lookup/main.tf` 等が含まれる
- working directory は cache 内の `_test-consumer/modules/`
- `OpenTofu has been successfully initialized!`

確認: `find .terragrunt-cache -path "*/vpc/lookup/main.tf"` が 1 件ヒットする。

Run: `TG_TF_PATH=tofu terragrunt validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: (Optional) Run terragrunt plan with AWS auth**

AWS 認証（`aws sso login` 等）が通っていれば実行する：

Run: `TG_TF_PATH=tofu terragrunt plan`

Expected:
- `Plan: 0 to add, 0 to change, 0 to destroy.` （consumer 側に作成リソースなし）
- `Changes to Outputs:` セクションに `debug = { vpc_id = "vpc-...", vpc_cidr = "10.0.0.0/16", public_ids = ["subnet-..."], ... }` の値が表示される

`subnet ids` が空配列になる場合は `Tier` タグが apply されていないので、`aws/vpc/envs/production` で `terragrunt apply` を実行してから再試行する。

- [ ] **Step 8: Cleanup**

Run: `cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat-aws-vpc-cross-stack-lookup && rm -rf aws/_test-consumer`

- [ ] **Step 9: Verify clean working tree**

Run: `git status`

Expected: `aws/_test-consumer/` 関連の untracked ファイルが残っていないこと。残っていれば再度削除する。

このタスクでは commit を作成しない。

---

## Post-Plan Operational Steps（参考）

本プランの commit が完了した後の運用手順（plan の対象外）:

1. PR を Draft で作成（`gh pr create --draft`）
2. CI の plan 結果で `aws/vpc/envs/production` の差分が `*_subnet_tags` の in-place update のみであることを確認
3. PR を ready にしてレビュー → merge
4. main ブランチで `terragrunt apply` を実施し、subnet に `Tier` タグを反映
5. apply 後、`aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> Name=tag:Tier,Values=public` で各 Tier 3 件返ることを確認

将来の consumer（EKS / ECS / RDS / ALB）の PR では、各 stack の `terragrunt.hcl` に `terraform { source = "../../..//<service>/modules" }`（go-getter `//` subdir 記法）を設定し、`modules/main.tf` で `module "vpc" { source = "../../vpc/lookup"; environment = var.environment }` と参照する。これにより cache に `aws/` 全体がコピーされ、相対 source が解決可能になる。
