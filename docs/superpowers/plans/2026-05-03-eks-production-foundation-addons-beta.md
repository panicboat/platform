# EKS Production Foundation Addons (beta) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster `eks-production` に **AWS Load Balancer Controller (chart 3.2.2)** + **ExternalDNS (chart 1.21.1)** + **ACM wildcard cert `*.panicboat.net`** + 関連 IRSA roles + VPC subnet tags を導入し、IngressGroup `panicboat-platform` で 1 ALB を共有する形で `Ingress` から ALB / Route53 record / HTTPS 終端が自動 provisioning される状態を作る。

**Architecture:** 本 plan は **2-PR split** で実装する。PR 1 は AWS 側のみ（`aws/route53/lookup` 新設 / VPC subnet tags / EKS IRSA roles / 新 stack `aws/alb`）、PR 2 は kubernetes 側（component 2 つ + helmfile values の IRSA ARN 転記 + hydrate + README 更新）。PR 1 merge → CI が aws/* apply → terragrunt output で IRSA role ARN / vpc_id を取得 → PR 2 でその値を helmfile values に転記 → PR 2 merge → Flux 自動 reconcile。

**Tech Stack:** Kubernetes 1.35, Cilium 1.18.6, AWS Load Balancer Controller chart 3.2.2 / app v3.2.2, ExternalDNS chart 1.21.1 / app 0.21.0, ACM, Route53, Helmfile, Kustomize, FluxCD 2.x, Terraform/OpenTofu, Terragrunt, AWS provider 6.x, terraform-aws-modules/iam ~> 6.0

**Spec:** `docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md`

---

## File Structure

### PR 1: AWS infrastructure（aws/* 配下のみ）

| File | Status | Responsibility |
|---|---|---|
| `aws/route53/lookup/terraform.tf` | create | provider 制約（`aws/vpc/lookup/` 同型） |
| `aws/route53/lookup/variables.tf` | create | inputs（現状なし、空でも可） |
| `aws/route53/lookup/main.tf` | create | `data "aws_route53_zone" "panicboat_net"` を定義 |
| `aws/route53/lookup/outputs.tf` | create | `zones.panicboat_net.{id, arn, name}` を export |
| `aws/vpc/modules/main.tf` | modify | `public_subnet_tags` に `kubernetes.io/role/elb = "1"` を追加、`private_subnet_tags` に `kubernetes.io/role/internal-elb = "1"` を追加 |
| `aws/eks/modules/lookups.tf` | modify | `module "route53"` を追加 |
| `aws/eks/modules/addons.tf` | modify | `module "alb_controller_irsa"` + `module "external_dns_irsa"` を追加（後者は `external_dns_hosted_zone_arns` で panicboat.net zone に scope 制限） |
| `aws/eks/modules/outputs.tf` | modify | `alb_controller_role_arn` / `external_dns_role_arn` / `vpc_id` を export |
| `aws/alb/Makefile` | create | terragrunt 実行 helper（`aws/eks/Makefile` 踏襲） |
| `aws/alb/root.hcl` | create | terragrunt root（`project_name = "alb"`） |
| `aws/alb/envs/production/env.hcl` | create | environment 固有値（aws_region 等） |
| `aws/alb/envs/production/terragrunt.hcl` | create | env から module へ inputs 渡し |
| `aws/alb/envs/production/.terraform.lock.hcl` | create | provider lock file（terragrunt init で生成） |
| `aws/alb/modules/terraform.tf` | create | provider 設定（AWS provider 6.x exact pin） |
| `aws/alb/modules/variables.tf` | create | environment / aws_region / common_tags |
| `aws/alb/modules/lookups.tf` | create | `module "route53" { source = "../../route53/lookup" }` |
| `aws/alb/modules/main.tf` | create | `aws_acm_certificate "wildcard_panicboat_net"` + DNS validation record + `aws_acm_certificate_validation` |
| `aws/alb/modules/outputs.tf` | create | `wildcard_panicboat_net_cert_arn` を export |

### PR 2: Kubernetes layer（kubernetes/* + values bridge）

| File | Status | Responsibility |
|---|---|---|
| `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` | create | Helm chart `eks/aws-load-balancer-controller` 3.2.2 を pin、namespace `kube-system` |
| `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl` | create | `clusterName: eks-production`、`region: ap-northeast-1`、`vpcId` を `.Values.cluster.vpcId` から差し込み、`serviceAccount.annotations` で IRSA role ARN を `.Values.cluster.albControllerRoleArn` から差し込み |
| `kubernetes/components/external-dns/production/helmfile.yaml` | create | Helm chart `external-dns/external-dns` 1.21.1 を pin、namespace `external-dns` |
| `kubernetes/components/external-dns/production/values.yaml.gotmpl` | create | `provider: aws`、`policy: sync`、`domainFilters: [panicboat.net]`、`txtOwnerId: eks-production`、`serviceAccount.annotations` で IRSA role ARN を差し込み |
| `kubernetes/components/external-dns/production/namespace.yaml` | create | `external-dns` namespace 定義 |
| `kubernetes/helmfile.yaml.gotmpl` | modify | production env values に `cluster.vpcId` / `cluster.albControllerRoleArn` / `cluster.externalDnsRoleArn` を追加（PR 1 の terragrunt output から実値を転記） |
| `kubernetes/manifests/production/aws-load-balancer-controller/` | create (hydrated) | `make hydrate ENV=production` 出力 |
| `kubernetes/manifests/production/external-dns/` | create (hydrated) | 同上 |
| `kubernetes/manifests/production/00-namespaces/namespaces.yaml` | regenerated | `external-dns` namespace 追加 |
| `kubernetes/manifests/production/kustomization.yaml` | regenerated | 2 component 追加 |
| `kubernetes/README.md` | modify | Production Operations セクションに ALB Controller / ExternalDNS / ACM 運用を追加 |

> **依存 spec / plan の前提**:
> - ロードマップ spec: `2026-05-02-eks-production-platform-roadmap-design.md`（merged）
> - Plan 1a (Flux bootstrap): merged in PR #255
> - Plan 1b (Cilium chaining): merged in PR #257 / 学び反映 #259
> - Plan 1c-α (Foundation addons alpha): merged in PR #260 / 学び反映 #261
> - Plan 1c-β 設計 spec: `2026-05-03-eks-production-foundation-addons-beta-design.md`（同 PR で merge 予定）

> **Out of scope（spec を継承）**: cert-manager (Phase 4) / dystopia.city ACM cert / WAF / Shield / Internal ALB / OIDC 認証 / Source IP allowlist 等は本 plan 範囲外、Phase 4 や Future Specs で扱う

---

## Task 0: 前提条件の確認

**Files:** （read only）

実装前に prerequisite が揃っていることを確認する。

- [ ] **Step 1: worktree とブランチを確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-foundation-addons-beta
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/eks-production-foundation-addons-beta`

- [ ] **Step 2: 必須 CLI 確認**

```bash
flux --version
kubectl version --client | head -1
helmfile --version
helm version --short
kustomize version
which terragrunt
```

Expected: 各 CLI が version を返す。

- [ ] **Step 3: Helm chart リポジトリの reachability を確認**

```bash
helm repo add eks https://aws.github.io/eks-charts 2>&1 || true
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns 2>&1 || true
helm repo update >/dev/null 2>&1
helm search repo eks/aws-load-balancer-controller --version=3.2.2 --output=table | tail -2
helm search repo external-dns/external-dns --version=1.21.1 --output=table | tail -2
```

Expected: ALB Controller chart 3.2.2 + ExternalDNS chart 1.21.1 が見つかる。

- [ ] **Step 4: AWS 認証確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
aws sts get-caller-identity --query Account --output text
```

Expected: `559744160976`

- [ ] **Step 5: Route53 zone reachability**

```bash
aws route53 list-hosted-zones --query "HostedZones[?Name=='panicboat.net.'].{Id:Id,Name:Name}" --output table
```

Expected: `panicboat.net.` zone の hosted zone ID が表示される（後の verification で使う）。

---

# PR 1 implementation: AWS infrastructure

## Task 1: aws/route53/lookup module を新設

**Files:**
- Create: `aws/route53/lookup/terraform.tf`
- Create: `aws/route53/lookup/variables.tf`
- Create: `aws/route53/lookup/main.tf`
- Create: `aws/route53/lookup/outputs.tf`

`aws/vpc/lookup/` パターンに倣い、Route53 zone の data resource lookup を集約。

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p aws/route53/lookup
```

- [ ] **Step 2: terraform.tf 作成**

`aws/route53/lookup/terraform.tf`:

```hcl
# terraform.tf - Version constraints for the Route53 lookup module.
# This module does not declare a provider; consumers supply the aws provider.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
```

- [ ] **Step 3: variables.tf 作成**

`aws/route53/lookup/variables.tf`:

```hcl
# variables.tf - Inputs for the Route53 lookup module.
# Currently no environment-specific behavior; all zones are looked up by name.
# Reserved for future per-environment overrides.
```

- [ ] **Step 4: main.tf 作成**

`aws/route53/lookup/main.tf`:

```hcl
# main.tf - Lookup of Route53 hosted zones by domain name.
#
# Add new zones here as they're brought into scope (e.g., dystopia.city
# for monorepo migration). Consumers reference outputs.zones.<key>.

data "aws_route53_zone" "panicboat_net" {
  name         = "panicboat.net."
  private_zone = false
}
```

- [ ] **Step 5: outputs.tf 作成**

`aws/route53/lookup/outputs.tf`:

```hcl
# outputs.tf - Pass-through outputs of the underlying data sources.

output "zones" {
  description = "Route53 hosted zones grouped by domain key (pass-through of aws_route53_zone data sources)."
  value = {
    panicboat_net = {
      id   = data.aws_route53_zone.panicboat_net.zone_id
      arn  = data.aws_route53_zone.panicboat_net.arn
      name = data.aws_route53_zone.panicboat_net.name
    }
  }
}
```

- [ ] **Step 6: terraform validate**

```bash
cd aws/route53/lookup
terraform init -backend=false 2>&1 | tail -3
terraform validate
cd ../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add aws/route53/lookup/
git commit -s -m "$(cat <<'EOF'
feat(aws/route53): add lookup module for hosted zones

Route53 zone を data resource で参照する shared module を新設する。
aws/vpc/lookup/ パターンに倣う。consumers (aws/alb/, aws/eks/) は
module "route53" { source = "../../route53/lookup" } で参照し、
outputs.zones.panicboat_net.{id, arn, name} を取得する。

dystopia.city 等の追加 zone は将来 main.tf に data resource を増やす
形で拡張する（monorepo 移行 spec で扱う）。
EOF
)"
```

---

## Task 2: VPC subnet tags 追加

**Files:**
- Modify: `aws/vpc/modules/main.tf`

ALB Controller の subnet auto-discovery 用タグを追加する。既存の `Tier` タグは維持。

- [ ] **Step 1: 現状確認**

```bash
grep -A 3 "subnet_tags" aws/vpc/modules/main.tf
```

Expected:
```
public_subnet_tags   = { Tier = "public" }
private_subnet_tags  = { Tier = "private" }
database_subnet_tags = { Tier = "database" }
```

- [ ] **Step 2: subnet_tags 編集**

`aws/vpc/modules/main.tf` の該当 3 行を以下に書き換える：

```hcl
  public_subnet_tags = {
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
  database_subnet_tags = { Tier = "database" }
```

`database_subnet_tags` は ALB Controller 対象外なので Tier タグのみ維持（変更なし）。

- [ ] **Step 3: terraform validate**

```bash
cd aws/vpc/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: terragrunt plan で差分確認（apply はしない）**

```bash
cd aws/vpc/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(\\+|will be)" | head -20
cd ../../../..
```

Expected: 各 public subnet（3 AZ）に `kubernetes.io/role/elb = "1"` 追加、各 private subnet（3 AZ）に `kubernetes.io/role/internal-elb = "1"` 追加で計 6 件の `tags` 変更が表示される。`Plan: 0 to add, 6 to change, 0 to destroy.` 程度。

- [ ] **Step 5: Commit**

```bash
git add aws/vpc/modules/main.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/vpc): add ALB Controller auto-discovery subnet tags

AWS Load Balancer Controller の subnet auto-discovery 用に
public_subnet_tags に kubernetes.io/role/elb=1、private_subnet_tags に
kubernetes.io/role/internal-elb=1 を追加する。Tier タグは既存維持。
database_subnet_tags は ALB Controller 対象外のため変更なし。
EOF
)"
```

---

## Task 3: aws/eks/modules に IRSA + Route53 lookup + outputs を追加

**Files:**
- Modify: `aws/eks/modules/lookups.tf`
- Modify: `aws/eks/modules/addons.tf`
- Modify: `aws/eks/modules/outputs.tf`

ALB Controller / ExternalDNS の IRSA roles を `vpc_cni_irsa` / `ebs_csi_irsa` の隣に追加。ExternalDNS は `external_dns_hosted_zone_arns` で panicboat.net zone に scope 制限。

- [ ] **Step 1: lookups.tf に route53 module 追加**

`aws/eks/modules/lookups.tf` の末尾に append：

```hcl

module "route53" {
  source = "../../route53/lookup"
}
```

完成形：

```hcl
# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}

module "route53" {
  source = "../../route53/lookup"
}
```

- [ ] **Step 2: addons.tf に IRSA modules 追加**

`aws/eks/modules/addons.tf` の `module "ebs_csi_irsa"` ブロックの直後（`locals { ... }` の前）に以下 2 modules を追加：

```hcl
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                              = "eks-${var.environment}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.common_tags
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                          = "eks-${var.environment}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [module.route53.zones.panicboat_net.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = var.common_tags
}
```

> ServiceAccount 名は chart デフォルトに従う：
> - ALB Controller chart 3.2.2: SA 名 `aws-load-balancer-controller` (namespace `kube-system`)
> - ExternalDNS chart 1.21.1: SA 名 `external-dns` (namespace `external-dns`)

- [ ] **Step 3: outputs.tf に新規 output 追加**

`aws/eks/modules/outputs.tf` の末尾に append：

```hcl

output "alb_controller_role_arn" {
  description = "IRSA role ARN for AWS Load Balancer Controller"
  value       = module.alb_controller_irsa.arn
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS"
  value       = module.external_dns_irsa.arn
}

output "vpc_id" {
  description = "VPC ID where the EKS cluster lives (for ALB Controller chart values)"
  value       = module.vpc.vpc.id
}
```

- [ ] **Step 4: terraform validate**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt init --backend=false 2>&1 | tail -3
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: terragrunt plan で差分確認**

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(will be created|Plan:)" | head -20
cd ../../../..
```

Expected: `module.alb_controller_irsa.aws_iam_role.this[0]` / `module.external_dns_irsa.aws_iam_role.this[0]` + 関連 IAM policy attachments が `will be created` で表示。`Plan: ~10 to add, 0 to change, 0 to destroy.` 程度。

- [ ] **Step 6: Commit**

```bash
git add aws/eks/modules/lookups.tf aws/eks/modules/addons.tf aws/eks/modules/outputs.tf
git commit -s -m "$(cat <<'EOF'
feat(aws/eks): add ALB Controller / ExternalDNS IRSA + outputs

terraform-aws-modules/iam ~> 6.0 の iam-role-for-service-accounts を使い、
ALB Controller (attach_load_balancer_controller_policy) と
ExternalDNS (attach_external_dns_policy + external_dns_hosted_zone_arns で
panicboat.net zone に scope 制限) の IRSA roles を addons.tf に追加。

lookups.tf に aws/route53/lookup module を追加（ExternalDNS の zone ARN
取得用）。outputs.tf に alb_controller_role_arn / external_dns_role_arn
/ vpc_id を追加（PR 2 で kubernetes/helmfile.yaml.gotmpl に転記する）。
EOF
)"
```

---

## Task 4: aws/alb stack を新設

**Files:**
- Create: `aws/alb/Makefile`
- Create: `aws/alb/root.hcl`
- Create: `aws/alb/envs/production/env.hcl`
- Create: `aws/alb/envs/production/terragrunt.hcl`
- Create: `aws/alb/modules/terraform.tf`
- Create: `aws/alb/modules/variables.tf`
- Create: `aws/alb/modules/lookups.tf`
- Create: `aws/alb/modules/main.tf`
- Create: `aws/alb/modules/outputs.tf`

ACM wildcard cert + DNS validation を terragrunt 管理にする新 stack。`aws/eks/` を参考に同型構造。

- [ ] **Step 1: ディレクトリ構造作成**

```bash
mkdir -p aws/alb/envs/production aws/alb/modules
```

- [ ] **Step 2: Makefile 作成**

`aws/alb/Makefile`:

```makefile
# Makefile - terragrunt helpers for aws/alb.
# Usage:
#   make plan      # terragrunt plan
#   make apply     # terragrunt apply -auto-approve
#   make destroy   # terragrunt destroy -auto-approve
#
# Environment is selected via ENV variable (default: production).

ENV ?= production

.PHONY: plan apply destroy

plan:
	@cd envs/$(ENV) && TG_TF_PATH=tofu terragrunt plan

apply:
	@cd envs/$(ENV) && TG_TF_PATH=tofu terragrunt apply -auto-approve

destroy:
	@cd envs/$(ENV) && TG_TF_PATH=tofu terragrunt destroy -auto-approve
```

- [ ] **Step 3: root.hcl 作成**

`aws/alb/root.hcl`（`aws/eks/root.hcl` 構造を踏襲）:

```hcl
# root.hcl - terragrunt root for aws/alb stack.

locals {
  project_name = "alb"
  common_tags = {
    Project    = local.project_name
    ManagedBy  = "terragrunt"
    Owner      = "panicboat"
    Repository = "panicboat/platform"
  }
}

remote_state {
  backend = "s3"
  config = {
    bucket         = "panicboat-terraform-state-559744160976"
    key            = "${local.project_name}/${path_relative_to_include()}/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "panicboat-terraform-locks"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
```

> 注: bucket 名 / dynamodb_table 名は `aws/eks/root.hcl` から正確な値を **コピーすること**（Step 8 で照合）。本 plan 草案では推測値を記載。

- [ ] **Step 4: env.hcl 作成**

`aws/alb/envs/production/env.hcl`:

```hcl
# env.hcl - environment-specific values for aws/alb production.

locals {
  environment = "production"
  aws_region  = "ap-northeast-1"
  environment_tags = {
    Environment = "production"
    Purpose     = "alb"
  }
}
```

- [ ] **Step 5: terragrunt.hcl 作成**

`aws/alb/envs/production/terragrunt.hcl`（go-getter `//` subdir 記法で `aws/` 全体を cache に同梱）:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env_vars = read_terragrunt_config("env.hcl")
}

terraform {
  source = "../../..//alb/modules"
}

inputs = {
  environment = local.env_vars.locals.environment
  aws_region  = local.env_vars.locals.aws_region
  common_tags = merge(
    include.root.locals.common_tags,
    local.env_vars.locals.environment_tags
  )
}
```

> 注: go-getter `//` 記法の正確な記述は `aws/eks/envs/production/terragrunt.hcl` を **照合してコピーする**（Step 8）。

- [ ] **Step 6: modules/terraform.tf 作成**

`aws/alb/modules/terraform.tf`:

```hcl
# terraform.tf - Version constraints and provider configuration.

terraform {
  required_version = ">= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.43.0"
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

> AWS provider version は `aws/eks/modules/terraform.tf` と揃える（Step 8）。

- [ ] **Step 7: modules/variables.tf 作成**

`aws/alb/modules/variables.tf`:

```hcl
# variables.tf - Inputs for the alb module.

variable "environment" {
  description = "Environment name (e.g., production)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
}
```

- [ ] **Step 8: aws/eks との pattern 整合確認**

```bash
diff <(cat aws/eks/root.hcl) <(cat aws/alb/root.hcl) || true
diff <(grep -A 5 "remote_state" aws/eks/root.hcl) <(grep -A 5 "remote_state" aws/alb/root.hcl) || true
grep "source =" aws/eks/envs/production/terragrunt.hcl
grep "source =" aws/alb/envs/production/terragrunt.hcl
grep "version" aws/eks/modules/terraform.tf | head -3
grep "version" aws/alb/modules/terraform.tf | head -3
```

Expected: `remote_state` の bucket / dynamodb_table 名、`terraform.source` の go-getter 記法、AWS provider version pin が aws/eks と整合する。差異があれば aws/alb 側を aws/eks に合わせて修正。

- [ ] **Step 9: modules/lookups.tf 作成**

`aws/alb/modules/lookups.tf`:

```hcl
# lookups.tf - External stack lookups.

module "route53" {
  source = "../../route53/lookup"
}
```

- [ ] **Step 10: modules/main.tf 作成（ACM wildcard cert + DNS validation）**

`aws/alb/modules/main.tf`:

```hcl
# main.tf - ACM wildcard certificate for *.panicboat.net.

resource "aws_acm_certificate" "wildcard_panicboat_net" {
  domain_name               = "*.panicboat.net"
  subject_alternative_names = ["panicboat.net"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

# DNS validation records in the panicboat.net hosted zone.
resource "aws_route53_record" "wildcard_panicboat_net_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard_panicboat_net.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = module.route53.zones.panicboat_net.id
}

resource "aws_acm_certificate_validation" "wildcard_panicboat_net" {
  certificate_arn         = aws_acm_certificate.wildcard_panicboat_net.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_panicboat_net_validation : record.fqdn]
}
```

- [ ] **Step 11: modules/outputs.tf 作成**

`aws/alb/modules/outputs.tf`:

```hcl
# outputs.tf - Outputs for the alb module.

output "wildcard_panicboat_net_cert_arn" {
  description = "ARN of the validated *.panicboat.net wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard_panicboat_net.certificate_arn
}
```

- [ ] **Step 12: terragrunt init + validate**

```bash
cd aws/alb/envs/production
TG_TF_PATH=tofu terragrunt init 2>&1 | tail -5
TG_TF_PATH=tofu terragrunt validate
cd ../../../..
```

Expected: init で provider download → success、validate で `Success! The configuration is valid.`

`.terraform.lock.hcl` が生成されたことを確認（git add の対象）。

- [ ] **Step 13: terragrunt plan で差分確認**

```bash
cd aws/alb/envs/production
TG_TF_PATH=tofu terragrunt plan 2>&1 | grep -E "(will be created|Plan:)" | head -10
cd ../../../..
```

Expected:
- `aws_acm_certificate.wildcard_panicboat_net` will be created
- `aws_route53_record.wildcard_panicboat_net_validation["*.panicboat.net"]` will be created
- `aws_route53_record.wildcard_panicboat_net_validation["panicboat.net"]` will be created
- `aws_acm_certificate_validation.wildcard_panicboat_net` will be created
- `Plan: 4 to add, 0 to change, 0 to destroy.`

- [ ] **Step 14: Commit**

```bash
git add aws/alb/
git commit -s -m "$(cat <<'EOF'
feat(aws/alb): add new stack with wildcard ACM cert for panicboat.net

ALB 周辺の AWS リソースを収容する新 stack を新設する。本 commit では
*.panicboat.net + panicboat.net の wildcard ACM 証明書 + DNS validation
record を作成する。validation record は aws/route53/lookup module 経由で
panicboat.net hosted zone に書き込む。

将来の WAF / Shield / 共通 SG はこの stack に追加していく（spec の
Future Specs 参照）。stack 構造は aws/eks と同型。
EOF
)"
```

---

## Task 5: PR 1 push + Draft PR 作成

**Files:** （git 操作のみ）

- [ ] **Step 1: 全 commit を確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: 6 commits（spec 3 + Task 1-4 の 4 commit、ただし spec commit は brainstorming で作成済 ec330cc / be9e504 / 6dfadf2 を含むので合計 7 commits 程度）

```
<sha> feat(aws/alb): add new stack with wildcard ACM cert for panicboat.net
<sha> feat(aws/eks): add ALB Controller / ExternalDNS IRSA + outputs
<sha> feat(aws/vpc): add ALB Controller auto-discovery subnet tags
<sha> feat(aws/route53): add lookup module for hosted zones
6dfadf2 docs(eks): document ALB access control deferral in Plan 1c-β spec
be9e504 docs(eks): switch Plan 1c-β to Option B (IngressGroup sharing)
ec330cc docs(eks): add Plan 1c-β (foundation addons beta) design spec
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-foundation-addons-beta
```

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --base main \
  --title "feat(aws): Plan 1c-β PR 1 - foundation AWS infra (route53 lookup + VPC tags + EKS IRSA + alb stack)" \
  --body "$(cat <<'EOF'
## Summary

Plan 1c-β の **PR 1** （AWS infrastructure 部分）。kubernetes 側 (PR 2) は本 PR merge → CI が aws/* apply → terragrunt outputs 取得後の **follow-up PR** で扱う。

### Code 変更（本 PR）

- ``aws/route53/lookup/``: Route53 zone を data resource で参照する shared lookup module を新設（``aws/vpc/lookup/`` 同型）
- ``aws/vpc/modules/main.tf``: subnet tags に ``kubernetes.io/role/elb`` (public) / ``kubernetes.io/role/internal-elb`` (private) を追加
- ``aws/eks/modules/``: ALB Controller / ExternalDNS の IRSA roles + outputs (``alb_controller_role_arn`` / ``external_dns_role_arn`` / ``vpc_id``) を追加
- ``aws/alb/``: 新 stack。``*.panicboat.net`` wildcard ACM cert + DNS validation record を作成

### Documents

- Plan: ``docs/superpowers/plans/2026-05-03-eks-production-foundation-addons-beta.md``
- Spec: ``docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md``

### Out of scope（PR 2 で扱う）

- kubernetes/components/{aws-load-balancer-controller,external-dns}/production/
- kubernetes/helmfile.yaml.gotmpl の IRSA role ARN / vpc_id 転記
- kubernetes/manifests/production の hydrate 結果
- kubernetes/README.md 更新

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] ``aws/route53/lookup`` で ``terraform validate`` 成功
- [x] ``aws/vpc/envs/production`` で ``terragrunt plan`` が 6 件の subnet tag 変更を表示（add/change/destroy = 0/6/0）
- [x] ``aws/eks/envs/production`` で ``terragrunt plan`` が IRSA roles 作成を表示（~10 add）
- [x] ``aws/alb/envs/production`` で ``terragrunt plan`` が ACM cert + DNS validation 4 件作成を表示

### Cluster-level (CI / operator 実行、merge 後)

- [ ] CI が ``aws/vpc/envs/production`` apply 完了
- [ ] CI が ``aws/eks/envs/production`` apply 完了、IRSA roles 作成
- [ ] CI が ``aws/alb/envs/production`` apply 完了、ACM cert ``ISSUED``
- [ ] ``terragrunt output -json`` で ARN / vpc_id 取得可能（PR 2 で利用）
EOF
)" 2>&1 | tail -3
```

Expected: PR URL（`https://github.com/panicboat/platform/pull/<num>`）が表示。

---

## (USER) PR 1 review + merge

**Files:** （CI 自動 + cluster 状態変更）

PR 1 を review、ready 化、merge する。CI が aws/vpc → aws/alb / aws/eks の terragrunt apply を実行する。

- [ ] **Step 1: PR 1 を Ready for review に変更**

```bash
gh pr ready
```

- [ ] **Step 2: review approve + merge**

```bash
gh pr review --approve
gh pr merge --squash --delete-branch
```

- [ ] **Step 3: CI workflow watch**

```bash
gh run watch
```

Expected: `Deploy Terragrunt (vpc:production)` / `Deploy Terragrunt (eks:production)` / `Deploy Terragrunt (alb:production)` が success で完了。

- [ ] **Step 4: AWS リソース確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
aws iam get-role --role-name eks-production-alb-controller --query 'Role.Arn' --output text
aws iam get-role --role-name eks-production-external-dns --query 'Role.Arn' --output text
aws acm list-certificates --region ap-northeast-1 \
  --query "CertificateSummaryList[?DomainName=='*.panicboat.net'].{Arn:CertificateArn,Status:Status}" \
  --output table
```

Expected:
- 両 IRSA role の ARN が表示
- ACM cert の Status: `ISSUED`

PR 1 完了。次に PR 2 の作成へ進む。

---

# PR 2 implementation: Kubernetes layer

## Task 6: terragrunt outputs 取得（controller）

**Files:** （read only）

PR 1 merge + CI apply 後に terragrunt outputs から ARN / vpc_id を取得する。

- [ ] **Step 1: 新 worktree 作成（PR 1 worktree とは独立）**

```bash
git -C /Users/takanokenichi/GitHub/panicboat/platform fetch origin main --quiet
git -C /Users/takanokenichi/GitHub/panicboat/platform worktree add \
  -b feat/eks-production-foundation-addons-beta-pr2 \
  .claude/worktrees/feat/eks-production-foundation-addons-beta-pr2 \
  origin/main
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/feat/eks-production-foundation-addons-beta-pr2
```

- [ ] **Step 2: terragrunt outputs 取得**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt output -json > /tmp/eks-outputs.json
cd ../../../..
jq -r '.alb_controller_role_arn.value' /tmp/eks-outputs.json
jq -r '.external_dns_role_arn.value' /tmp/eks-outputs.json
jq -r '.vpc_id.value' /tmp/eks-outputs.json
```

Expected: 3 つの値が取得できる：
- ALB Controller IRSA ARN: `arn:aws:iam::559744160976:role/eks-production-alb-controller`
- ExternalDNS IRSA ARN: `arn:aws:iam::559744160976:role/eks-production-external-dns`
- vpc_id: `vpc-XXXXXXXXXXXX`

これら 3 値を **後の Task 9 で kubernetes/helmfile.yaml.gotmpl に転記**する。

---

## Task 7: ALB Controller production component を作成

**Files:**
- Create: `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`
- Create: `kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl`

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p kubernetes/components/aws-load-balancer-controller/production
```

- [ ] **Step 2: helmfile.yaml 作成**

`kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`:

```yaml
# =============================================================================
# AWS Load Balancer Controller Helmfile for production
# =============================================================================
# Provisions ALBs from Ingress resources. IngressGroup `panicboat-platform`
# is used to share one ALB across multiple Ingresses (see spec for the
# rationale on choosing Option B over TargetGroupBinding).
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # 値は kubernetes/helmfile.yaml.gotmpl の production env block と
    # 同期すること（vpcId / albControllerRoleArn）。
    values:
      - cluster:
          vpcId: REPLACE_FROM_TERRAGRUNT_OUTPUT
          albControllerRoleArn: REPLACE_FROM_TERRAGRUNT_OUTPUT
---
repositories:
  - name: eks
    url: https://aws.github.io/eks-charts

releases:
  - name: aws-load-balancer-controller
    namespace: kube-system
    chart: eks/aws-load-balancer-controller
    version: "3.2.2"
    values:
      - values.yaml.gotmpl
```

> Step 9 で実値に置換するため、ここでは `REPLACE_FROM_TERRAGRUNT_OUTPUT` プレースホルダのまま。

- [ ] **Step 3: values.yaml.gotmpl 作成**

`kubernetes/components/aws-load-balancer-controller/production/values.yaml.gotmpl`:

```yaml
# AWS Load Balancer Controller values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md

# =============================================================================
# Cluster identification
# =============================================================================
clusterName: eks-production
region: ap-northeast-1
vpcId: {{ .Values.cluster.vpcId }}

# =============================================================================
# ServiceAccount with IRSA
# =============================================================================
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.cluster.albControllerRoleArn }}

# =============================================================================
# Replicas / Resources
# =============================================================================
# chart デフォルト (replicaCount: 2) を採用。HA 化済み。
```

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/aws-load-balancer-controller/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/aws-load-balancer-controller): add production component

ALB Controller chart 3.2.2 を pin して production 用 helmfile / values
を追加する。clusterName / region / vpcId / IRSA role ARN を
.Values.cluster から差し込む。chart デフォルトで replicaCount: 2 (HA)。

helmfile v1.4 の parent → child env values 非継承への対応は cilium
component と同パターン（環境変数の重複定義 + 同期コメント）。
helmfile values の REPLACE_FROM_TERRAGRUNT_OUTPUT は次 commit で
実値に置換する。
EOF
)"
```

---

## Task 8: ExternalDNS production component を作成

**Files:**
- Create: `kubernetes/components/external-dns/production/helmfile.yaml`
- Create: `kubernetes/components/external-dns/production/values.yaml.gotmpl`
- Create: `kubernetes/components/external-dns/production/namespace.yaml`

- [ ] **Step 1: ディレクトリ作成**

```bash
mkdir -p kubernetes/components/external-dns/production
```

- [ ] **Step 2: namespace.yaml 作成**

`kubernetes/components/external-dns/production/namespace.yaml`:

```yaml
# =============================================================================
# ExternalDNS Namespace
# =============================================================================
# This namespace contains the ExternalDNS controller. Chart default name is
# also `external-dns`; we follow that convention.
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns
  labels:
    app.kubernetes.io/name: external-dns
```

- [ ] **Step 3: helmfile.yaml 作成**

`kubernetes/components/external-dns/production/helmfile.yaml`:

```yaml
# =============================================================================
# ExternalDNS Helmfile for production
# =============================================================================
# Synchronizes Route53 records from Kubernetes Service / Ingress hostname
# annotations. Restricted to the panicboat.net zone via domainFilters and
# IRSA hosted_zone_arns scope.
# =============================================================================
environments:
  production:
    # NOTE: helmfile v1.4 は親 helmfile.yaml.gotmpl の environments values を
    # 子 helmfile に auto-inherit しないため、ここで再定義する。
    # externalDnsRoleArn は kubernetes/helmfile.yaml.gotmpl の production env
    # block と同期すること。
    values:
      - cluster:
          externalDnsRoleArn: REPLACE_FROM_TERRAGRUNT_OUTPUT
---
repositories:
  - name: external-dns
    url: https://kubernetes-sigs.github.io/external-dns

releases:
  - name: external-dns
    namespace: external-dns
    chart: external-dns/external-dns
    version: "1.21.1"
    values:
      - values.yaml.gotmpl
```

- [ ] **Step 4: values.yaml.gotmpl 作成**

`kubernetes/components/external-dns/production/values.yaml.gotmpl`:

```yaml
# ExternalDNS values for production
# Reference: docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md

# =============================================================================
# Provider / Sources
# =============================================================================
provider:
  name: aws

sources:
  - service
  - ingress

# =============================================================================
# Domain filtering
# =============================================================================
# panicboat.net 以下のみ管理。dystopia.city は monorepo 移行 spec で扱う。
domainFilters:
  - panicboat.net

# =============================================================================
# Sync policy
# =============================================================================
# sync = Service/Ingress 削除で record も自動削除（spec ALB アクセス制御の方針
# セクション参照）。GitOps 経由の変更のみ運用ルールにより、誤削除リスクは
# README の GitOps 原則で緩和。
policy: sync

# =============================================================================
# Ownership marker
# =============================================================================
# 同 zone を複数 cluster で共有する場合の所有権マーカー。本 cluster のみで
# panicboat.net を管理する想定なので cluster name を採用。
txtOwnerId: eks-production

# =============================================================================
# ServiceAccount with IRSA
# =============================================================================
serviceAccount:
  create: true
  name: external-dns
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.cluster.externalDnsRoleArn }}

# =============================================================================
# Replicas / Resources
# =============================================================================
# chart デフォルト採用。
```

- [ ] **Step 5: Commit**

```bash
git add kubernetes/components/external-dns/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/components/external-dns): add production component

ExternalDNS chart 1.21.1 を pin して production 用 helmfile / values /
namespace を追加する。
- provider: aws
- sources: service + ingress
- domainFilters: panicboat.net (dystopia.city は monorepo 移行 spec で)
- policy: sync (誤削除リスクは GitOps 原則で緩和)
- txtOwnerId: eks-production
- IRSA role ARN を .Values.cluster.externalDnsRoleArn から差し込み

helmfile values の REPLACE_FROM_TERRAGRUNT_OUTPUT は次 commit で
実値に置換する。
EOF
)"
```

---

## Task 9: kubernetes/helmfile.yaml.gotmpl の production env values 更新（実値転記）

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`
- Modify: `kubernetes/components/external-dns/production/helmfile.yaml`

Task 6 で取得した terragrunt outputs を `kubernetes/helmfile.yaml.gotmpl` の production env block と各 child helmfile の env block に転記する。

- [ ] **Step 1: 現状の helmfile.yaml.gotmpl 確認**

```bash
grep -A 10 "^  production:" kubernetes/helmfile.yaml.gotmpl
```

Expected: 既存の production env block（Plan 1b で追加済の `cluster.eksApiEndpoint` を含む）が表示。

- [ ] **Step 2: kubernetes/helmfile.yaml.gotmpl の production env block 編集**

`kubernetes/helmfile.yaml.gotmpl` の `production:` block を以下に書き換える：

```yaml
  production:
    values:
      - cluster:
          name: eks-production
          isLocal: false
          # eks-production cluster の API server endpoint hostname（https:// は含まない）
          eksApiEndpoint: BD10E7689A05E46191305DDC7BE6CA67.gr7.ap-northeast-1.eks.amazonaws.com
          # VPC ID where the cluster lives. Used by AWS Load Balancer Controller.
          # Source: aws/eks/envs/production terragrunt output vpc_id
          vpcId: <REPLACE_WITH_TERRAGRUNT_OUTPUT_VPC_ID>
          # IRSA role ARNs for foundation addons. Source: aws/eks/envs/production
          # terragrunt output {alb_controller_role_arn, external_dns_role_arn}
          albControllerRoleArn: <REPLACE_WITH_TERRAGRUNT_OUTPUT_ALB_CONTROLLER_ROLE_ARN>
          externalDnsRoleArn: <REPLACE_WITH_TERRAGRUNT_OUTPUT_EXTERNAL_DNS_ROLE_ARN>
```

`<REPLACE_WITH_TERRAGRUNT_OUTPUT_*>` を Task 6 で取得した実値に置換する。例：

```yaml
          vpcId: vpc-02ea5d0ed3b7a3266
          albControllerRoleArn: arn:aws:iam::559744160976:role/eks-production-alb-controller
          externalDnsRoleArn: arn:aws:iam::559744160976:role/eks-production-external-dns
```

`eksApiEndpoint` は Plan 1b で設定済の既存値を維持。

- [ ] **Step 3: child helmfile (aws-load-balancer-controller) の placeholder を実値に置換**

`kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml` の `environments.production.values.cluster` block の `vpcId` / `albControllerRoleArn` を実値に置換：

```yaml
environments:
  production:
    values:
      - cluster:
          vpcId: vpc-02ea5d0ed3b7a3266
          albControllerRoleArn: arn:aws:iam::559744160976:role/eks-production-alb-controller
```

> Plan 1b の cilium production helmfile でも同パターン（child helmfile に値の重複定義）。

- [ ] **Step 4: child helmfile (external-dns) の placeholder を実値に置換**

`kubernetes/components/external-dns/production/helmfile.yaml` の `environments.production.values.cluster` block の `externalDnsRoleArn` を実値に置換：

```yaml
environments:
  production:
    values:
      - cluster:
          externalDnsRoleArn: arn:aws:iam::559744160976:role/eks-production-external-dns
```

- [ ] **Step 5: helmfile が production env を認識すること + values 解決を確認**

```bash
cd kubernetes
helmfile -e production list 2>&1 | head -10
cd ..
```

Expected: cilium / metrics-server / keda / aws-load-balancer-controller / external-dns の 5 release が listed され、`Error` が出ないこと。

```bash
cd kubernetes
helmfile -e production --selector name=aws-load-balancer-controller template --skip-tests 2>&1 | grep -E "(role-arn|vpcId|clusterName)" | head -10
helmfile -e production --selector name=external-dns template --skip-tests 2>&1 | grep -E "(role-arn|domain-filter)" | head -10
cd ..
```

Expected:
- ALB Controller の rendered output に IRSA role ARN annotation + vpcId + clusterName が表示
- ExternalDNS の rendered output に IRSA role ARN annotation + domain filter `panicboat.net` が表示

- [ ] **Step 6: Commit**

```bash
git add kubernetes/helmfile.yaml.gotmpl \
        kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml \
        kubernetes/components/external-dns/production/helmfile.yaml
git commit -s -m "$(cat <<'EOF'
feat(kubernetes): wire IRSA role ARNs and vpc_id from terragrunt outputs

PR 1 (#XXX) で aws/eks apply により作成された IRSA roles と vpc_id を
kubernetes/helmfile.yaml.gotmpl の production env values に転記する。
ALB Controller / ExternalDNS の child helmfile の environments env block
にも同値を重複定義（helmfile v1.4 の parent → child auto-inherit 非対応
への対処、cilium と同パターン）。

values の source は aws/eks/envs/production の terragrunt output
{alb_controller_role_arn, external_dns_role_arn, vpc_id}。
EOF
)"
```

---

## Task 10: `make hydrate ENV=production` 実行 + commit

**Files (auto-generated by hydrate):**
- Create: `kubernetes/manifests/production/aws-load-balancer-controller/manifest.yaml`
- Create: `kubernetes/manifests/production/aws-load-balancer-controller/kustomization.yaml`
- Create: `kubernetes/manifests/production/external-dns/manifest.yaml`
- Create: `kubernetes/manifests/production/external-dns/kustomization.yaml`
- Modify: `kubernetes/manifests/production/00-namespaces/namespaces.yaml`（external-dns namespace 追加）
- Modify: `kubernetes/manifests/production/kustomization.yaml`（5 component 参照に拡張）

- [ ] **Step 1: hydrate 実行**

```bash
cd kubernetes
make hydrate ENV=production
cd ..
```

Expected: `Hydrating aws-load-balancer-controller...` `Hydrating external-dns...` 等が標準出力に表示、`✅ Manifests hydrated`。

- [ ] **Step 2: 生成された structure 確認**

```bash
find kubernetes/manifests/production -maxdepth 2 -type d | sort
```

Expected: cilium / gateway-api / keda / metrics-server / aws-load-balancer-controller / external-dns / 00-namespaces の 7 つ。

- [ ] **Step 3: external-dns namespace が namespaces.yaml に追加されたこと確認**

```bash
grep -B 1 -A 5 "name: external-dns" kubernetes/manifests/production/00-namespaces/namespaces.yaml
```

Expected: `external-dns` namespace の YAML block が含まれる（既存の `keda` に加えて）。

- [ ] **Step 4: top-level kustomization.yaml が 5 component + 00-namespaces を参照すること確認**

```bash
cat kubernetes/manifests/production/kustomization.yaml
```

Expected:
```yaml
resources:
  - ./00-namespaces
  - ./aws-load-balancer-controller
  - ./cilium
  - ./external-dns
  - ./gateway-api
  - ./keda
  - ./metrics-server
```

- [ ] **Step 5: ALB Controller / ExternalDNS の主要設定を sanity check**

```bash
echo "=== ALB Controller ServiceAccount IRSA annotation ==="
grep -B 1 -A 3 "eks.amazonaws.com/role-arn" kubernetes/manifests/production/aws-load-balancer-controller/manifest.yaml | head -10
echo ""
echo "=== ALB Controller deployment args (--cluster-name) ==="
grep -A 2 "cluster-name" kubernetes/manifests/production/aws-load-balancer-controller/manifest.yaml | head -5
echo ""
echo "=== ExternalDNS ServiceAccount IRSA annotation ==="
grep -B 1 -A 3 "eks.amazonaws.com/role-arn" kubernetes/manifests/production/external-dns/manifest.yaml | head -10
echo ""
echo "=== ExternalDNS deployment args (--domain-filter) ==="
grep -A 2 "domain-filter" kubernetes/manifests/production/external-dns/manifest.yaml | head -5
```

Expected: 各 IRSA role ARN が rendered 出力に含まれる、ALB Controller の `--cluster-name=eks-production`、ExternalDNS の `--domain-filter=panicboat.net` が確認できる。

- [ ] **Step 6: kustomize build で全体 valid 確認**

```bash
kustomize build kubernetes/manifests/production 2>&1 | grep -c "^kind:"
```

Expected: 100+ resources（既存 85 + ALB Controller 約 10 + ExternalDNS 約 10）。エラーなし。

- [ ] **Step 7: Commit**

```bash
git add kubernetes/manifests/production/
git commit -s -m "$(cat <<'EOF'
feat(kubernetes/manifests/production): hydrate alb-controller + external-dns

make hydrate ENV=production の output を commit する。
- aws-load-balancer-controller/manifest.yaml: chart 3.2.2 の rendered
  output、IRSA annotation + vpcId + clusterName 込み
- external-dns/manifest.yaml: chart 1.21.1 の rendered output、
  IRSA annotation + domainFilters: panicboat.net + policy: sync 込み
- 00-namespaces/namespaces.yaml: external-dns namespace 追加
- kustomization.yaml: 7 component (cilium / gateway-api / keda /
  metrics-server / aws-load-balancer-controller / external-dns /
  00-namespaces) を resources として参照
EOF
)"
```

---

## Task 11: kubernetes/README.md 更新

**Files:**
- Modify: `kubernetes/README.md`

Plan 1c-β の 2 component を Production Operations セクションに反映。

- [ ] **Step 1: 現状の README 構成確認**

```bash
grep -n "^### " kubernetes/README.md | head -20
```

Expected: Production Operations 配下に Cluster overview / Initial Bootstrap / Daily Operations / Cilium-specific operations / Foundation addon operations / Troubleshooting / GitOps 原則 が見える（Plan 1c-α までで揃っている）。

- [ ] **Step 2: Cluster overview セクション更新**

`### Cluster overview (post Plan 1c-α)` を `### Cluster overview (post Plan 1c-β)` に変更。Plan 1c-α で追加した foundation addons 表の直後（次の `### Initial Bootstrap` の前）に以下を append（先頭に空行を挟んで）：

````markdown
さらに Plan 1c-β で以下を導入：

| Addon / Resource | 配置 | 役割 |
|---|---|---|
| AWS Load Balancer Controller | `kube-system` | Ingress リソースから ALB を自動 provisioning（IngressGroup `panicboat-platform` で 1 ALB を共有） |
| ExternalDNS | `external-dns` | Service / Ingress hostname annotation から Route53 record を自動生成（`panicboat.net` zone scope） |
| ACM wildcard cert | aws/alb stack | `*.panicboat.net` + `panicboat.net`、ALB Controller の cert auto-discovery で利用 |
| IRSA roles | aws/eks stack | ALB Controller / ExternalDNS が AWS API を IRSA 経由で叩くため |
| VPC subnet tags | aws/vpc | `kubernetes.io/role/elb` (public) / `kubernetes.io/role/internal-elb` (private) で ALB Controller subnet auto-discovery 有効化 |
````

- [ ] **Step 3: Foundation addon operations セクションを更新**

`### Foundation addon operations` の bash code block の末尾に append（既存の Gateway API / Metrics Server / KEDA の下に）：

````markdown

```bash
# AWS Load Balancer Controller
kubectl get deployment -n kube-system aws-load-balancer-controller   # READY 2/2
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20

# ExternalDNS
kubectl get deployment -n external-dns external-dns                  # READY 1/1
kubectl logs -n external-dns deploy/external-dns --tail=20

# ACM cert (terragrunt 管理、ALB Controller が auto-discovery)
aws acm list-certificates --region ap-northeast-1 \
  --query "CertificateSummaryList[?DomainName=='*.panicboat.net']"

# Ingress / ALB / Route53 record の確認 (Phase 5 nginx 投入後)
kubectl get ingress -A
kubectl describe ingress <name> -n <ns>                              # ALB DNS / cert ARN
aws route53 list-resource-record-sets --hosted-zone-id <zone-id>     # ExternalDNS が作った record
```
````

> 既存の bash code block の閉じ ``` の直前に上記内容を挿入する形（同一 code block 内に append）。

- [ ] **Step 4: Troubleshooting テーブルに行追加**

`### Troubleshooting` テーブルの末尾（既存の Plan 1c-α 学び 3 行の後）に以下の行を追加：

````markdown
| Ingress 作成しても `ADDRESS` が空のまま | aws-load-balancer-controller pod が unhealthy or IRSA 認証失敗。`kubectl logs -n kube-system deploy/aws-load-balancer-controller` で確認、`AccessDenied` 系なら IRSA role policy / trust policy を再確認 |
| ExternalDNS が Route53 record を作らない | domainFilters にマッチしない hostname、または ExternalDNS pod が unhealthy。`kubectl logs -n external-dns deploy/external-dns --tail=50` で `panicboat.net` 以外の record を skip しているか確認 |
| HTTPS Ingress で `ERR_CERT_AUTHORITY_INVALID` | ACM cert auto-discovery が走っていない（Ingress の `host` が ACM cert SAN にマッチしない）or ACM cert が `ISSUED` でない。`aws acm describe-certificate --certificate-arn ...` で status 確認 |
````

- [ ] **Step 5: README の整合性確認**

```bash
grep -c "^### " kubernetes/README.md
```

Expected: subsection count が Plan 1c-α 時点（24）から変わらず（既存セクションの内容追記のみで新規 subsection 追加なし）。

- [ ] **Step 6: Commit**

```bash
git add kubernetes/README.md
git commit -s -m "$(cat <<'EOF'
docs(kubernetes): reflect Plan 1c-β addons in README

Production Operations セクションに Plan 1c-β で導入する Foundation
addons (ALB Controller / ExternalDNS) と関連 AWS リソース (ACM cert /
IRSA roles / VPC subnet tags) を反映する。
- Cluster overview に Plan 1c-β 追加リソース表
- Foundation addon operations に ALB Controller / ExternalDNS / ACM /
  Ingress / Route53 の運用コマンド追加
- Troubleshooting に Ingress ADDRESS 空 / ExternalDNS record 未生成 /
  ACM cert mismatch のエントリ 3 件追加
EOF
)"
```

---

## Task 12: PR 2 push + Draft PR 作成

**Files:** （git 操作のみ）

- [ ] **Step 1: 全 commit 確認**

```bash
git log --oneline origin/main..HEAD
```

Expected: 6 commits（Task 7-11 の 5 commit + 場合によっては Task 9 が複数 file まとめなので 5 commit）

```
<sha> docs(kubernetes): reflect Plan 1c-β addons in README
<sha> feat(kubernetes/manifests/production): hydrate alb-controller + external-dns
<sha> feat(kubernetes): wire IRSA role ARNs and vpc_id from terragrunt outputs
<sha> feat(kubernetes/components/external-dns): add production component
<sha> feat(kubernetes/components/aws-load-balancer-controller): add production component
```

- [ ] **Step 2: ブランチを push**

```bash
git push -u origin feat/eks-production-foundation-addons-beta-pr2
```

- [ ] **Step 3: Draft PR 作成**

```bash
gh pr create --draft --base main \
  --title "feat(kubernetes): Plan 1c-β PR 2 - install ALB Controller + ExternalDNS via Flux" \
  --body "$(cat <<'EOF'
## Summary

Plan 1c-β の **PR 2** （kubernetes layer）。PR 1 (#XXX merged) で作成された IRSA roles + VPC subnet tags + ACM cert を前提に、AWS Load Balancer Controller (chart 3.2.2) + ExternalDNS (chart 1.21.1) を Flux GitOps 経由で install する。

### Code 変更（本 PR）

- ``kubernetes/components/aws-load-balancer-controller/production/``: helmfile + values。clusterName / region / vpcId / IRSA role ARN を gotmpl で差し込み
- ``kubernetes/components/external-dns/production/``: helmfile + values + namespace。provider: aws / sources: service+ingress / policy: sync / domainFilters: [panicboat.net] / txtOwnerId: eks-production
- ``kubernetes/helmfile.yaml.gotmpl``: production env values に ``cluster.vpcId`` / ``cluster.albControllerRoleArn`` / ``cluster.externalDnsRoleArn`` を追加（PR 1 の terragrunt output から実値を転記）
- ``kubernetes/manifests/production/``: hydrate output（2 component + 00-namespaces 更新）
- ``kubernetes/README.md``: Production Operations 更新（Cluster overview / Foundation addon operations / Troubleshooting）

### Documents

- Plan: ``docs/superpowers/plans/2026-05-03-eks-production-foundation-addons-beta.md``
- Spec: ``docs/superpowers/specs/2026-05-03-eks-production-foundation-addons-beta-design.md``
- 前段 PR (AWS infra): #XXX

## Migration sequence

PR 2 merge 後、Flux が自動 reconcile する。Plan 1b と異なり Flux suspend 不要（既存 service routing への破壊的変更なし）。

1. PR 2 を main へ merge
2. CI: ``Hydrate Kubernetes (production)`` workflow auto-run
3. Flux が main を pull → 差分（ALB Controller + ExternalDNS Helm releases + external-dns namespace）を apply
4. Verification battery を operator が手動実行（Plan の Task 13 参照）

## Test plan

### Code-level (PR 作成時点で完了済)

- [x] ``helmfile -e production list`` で 5 release が listed (cilium / metrics-server / keda / aws-load-balancer-controller / external-dns)
- [x] ``helmfile -e production --selector name=aws-load-balancer-controller template`` で IRSA annotation + vpcId + clusterName が rendered
- [x] ``helmfile -e production --selector name=external-dns template`` で IRSA annotation + domain-filter rendered
- [x] ``kustomize build kubernetes/manifests/production`` が valid (~100 resources)
- [x] ``kubernetes/manifests/production/00-namespaces/namespaces.yaml`` に keda + external-dns namespaces
- [x] ``kubernetes/manifests/production/kustomization.yaml`` が 7 component (cilium / gateway-api / keda / metrics-server / aws-load-balancer-controller / external-dns / 00-namespaces) を参照
- [x] ``kubernetes/README.md`` の Production Operations が Plan 1c-β 反映済

### Cluster-level (operator 実行、merge 後)

- [ ] ``kubectl get deployment -n kube-system aws-load-balancer-controller`` で READY 2/2
- [ ] ``kubectl get deployment -n external-dns external-dns`` で READY 1/1
- [ ] ``kubectl logs -n kube-system deploy/aws-load-balancer-controller`` で IRSA 認証成功 log
- [ ] ``kubectl logs -n external-dns deploy/external-dns`` で `panicboat.net` zone への接続成功 log
- [ ] Smoke test: minimal Ingress (smoke.panicboat.net + group.name=panicboat-platform) で ALB 起動 + Route53 record 自動生成 + HTTPS curl 200 OK
EOF
)" 2>&1 | tail -3
```

Expected: PR URL（`https://github.com/panicboat/platform/pull/<num>`）が表示。

---

## (USER) PR 2 review + merge → Verification

**Files:** （cluster 状態変更）

- [ ] **Step 1: PR 2 を Ready for review に変更 + merge**

```bash
gh pr ready
gh pr review --approve
gh pr merge --squash --delete-branch
gh run watch
```

Expected: Hydrate Kubernetes (production) workflow が success で完了。

- [ ] **Step 2: Flux reconcile 確認**

```bash
source ~/.zshrc
eks-login production >/dev/null 2>&1
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
flux get kustomizations -n flux-system flux-system
```

Expected: `READY: True`、`MESSAGE: Applied revision: main@<sha>`。

- [ ] **Step 3: ALB Controller / ExternalDNS deployment 確認**

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get deployment -n external-dns external-dns
```

Expected: ALB Controller 2/2、ExternalDNS 1/1（Available）。

---

## Task 13: (USER) Verification battery

**Files:** （read only / 一時 test resource）

各 component が期待通り動作することを確認する。

- [ ] **Step 1: ALB Controller logs（IRSA 認証成功確認）**

```bash
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=30 | grep -iE "(role|aws|error)" | head -10
```

Expected: `AccessDenied` 系のエラーなし。`assumed-role/eks-production-alb-controller` 等の log で IRSA assume 成功。

- [ ] **Step 2: ExternalDNS logs（zone 接続確認）**

```bash
kubectl logs -n external-dns deploy/external-dns --tail=30 | grep -iE "(zone|panicboat|error|level=error)" | head -10
```

Expected: `panicboat.net` zone への接続成功 log。`AccessDenied` / `level=error` なし。

- [ ] **Step 3: Smoke test - Ingress + ALB + Route53 record + HTTPS**

```bash
# nginx を deploy
kubectl run smoke-target --image=nginx:alpine --port=80 -n default
kubectl expose pod smoke-target --port=80 --target-port=80 -n default --name=smoke-svc

# Ingress 作成（IngressGroup でシェア、HTTPS、cert ARN annotation 不要）
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smoke-ing
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/group.name: panicboat-platform
    external-dns.alpha.kubernetes.io/hostname: smoke.panicboat.net
spec:
  ingressClassName: alb
  rules:
    - host: smoke.panicboat.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: smoke-svc
                port:
                  number: 80
EOF
```

90 秒待つ：

```bash
sleep 90
kubectl get ingress smoke-ing -n default
```

Expected: `ADDRESS` 列に `xxxxx-panicboat-platform-xxxxxxx.ap-northeast-1.elb.amazonaws.com` 形式の ALB DNS が表示。

```bash
ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='panicboat.net.'].Id" --output text | cut -d'/' -f3)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='smoke.panicboat.net.']" --output table
```

Expected: A / TXT (txtOwnerId=eks-production) record が表示。

```bash
sleep 30  # DNS 伝搬待ち
curl -I https://smoke.panicboat.net/
```

Expected: `HTTP/2 200`、SSL 証明書は ACM の `*.panicboat.net`（cert auto-discovery 動作確認）。`curl` の `Server certificate` 行で issuer が Amazon であることを確認。

- [ ] **Step 4: Cleanup（policy: sync で Route53 record 自動削除確認）**

```bash
kubectl delete ingress smoke-ing -n default
kubectl delete svc smoke-svc -n default
kubectl delete pod smoke-target -n default
sleep 30
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='smoke.panicboat.net.']" --output text
```

Expected: 結果が空（`policy: sync` の auto-delete 動作確認）。

- [ ] **Step 5: 全体 Flux 状態 + Pod 健康確認**

```bash
flux get all -n flux-system | head -10
kubectl get pods -A | grep -v Running | grep -v Completed | head
```

Expected: Flux 全 Ready、stuck pod なし。

すべて pass したら **Plan 1c-β 完了**。Phase 1 Foundation すべて完了、次は Plan 2（Karpenter）または Phase 3 観測スタックへ。

---

## Self-review checklist

このセクションは Plan 完成後に書き手（Claude）が自己 review する項目。実装者は Skip して構わない。

- [x] **Spec coverage**:
  - Spec の Goals 1-7 → Task 1-13 でカバー
  - Spec の Components 変更マトリクス → File Structure 表と Task 1-11 が 1 対 1 対応
  - Spec の Migration sequence → Task 5 (PR 1) + USER gate + Task 6-12 (PR 2) + Task 13 (verification) で実装
  - Spec の Verification checklist → Task 13 で全項目を smoke test 形式で網羅
  - Spec の ALB sharing strategy (Option B / IngressGroup) → Task 13 smoke test で `group.name: panicboat-platform` annotation 使用
  - Spec の ALB アクセス制御の方針 (default open) → Plan 内で specific access control を実装せず、spec の方針通り
- [x] **Placeholder scan**:
  - `<REPLACE_WITH_TERRAGRUNT_OUTPUT_*>` および `REPLACE_FROM_TERRAGRUNT_OUTPUT` は **Task 6 で取得した実値に置換する明示的指示あり**（Step 2-4）
  - `<sha>` / `<XXX>` は commit hash / PR number の placeholder（実装時に確定）
  - `TBD` / `implement later` 等の禁止文言なし
- [x] **Type / signature consistency**:
  - terragrunt output 名 (`alb_controller_role_arn` / `external_dns_role_arn` / `vpc_id`) は Task 3（aws/eks/modules/outputs.tf）と Task 6（取得）と Task 9（kubernetes/helmfile.yaml.gotmpl で参照）で一致
  - helmfile values key (`cluster.vpcId` / `cluster.albControllerRoleArn` / `cluster.externalDnsRoleArn`) は Task 7 / 8 / 9 で一致
  - Helm chart name + version: ALB Controller `eks/aws-load-balancer-controller` 3.2.2、ExternalDNS `external-dns/external-dns` 1.21.1 で全 task 一致
- [x] **CLAUDE.md 準拠**:
  - 出力言語日本語、コミット `-s`、`Co-Authored-By` 不付与、PR は `--draft`、`-u origin HEAD`、Conventional Commits
- [x] **README 更新を含めた**: Task 11 で kubernetes/README.md の Production Operations セクション 3 箇所修正
- [x] **Plan 1b / 1c-α の知見反映**:
  - helmfile v1.4 の parent → child env values 非継承への対応（child 重複定義 + 同期コメント）→ Task 7 / 8 で同パターン
  - hydrate-component の `-e $(ENV)` 不足は Plan 1b で fix 済（修正後の Makefile 前提）
  - 新 component の env-aware namespace 配置 → external-dns/production/namespace.yaml で対応
