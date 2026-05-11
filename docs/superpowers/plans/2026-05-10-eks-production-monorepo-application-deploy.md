# EKS Production: Phase 6-2 Monorepo Application Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** EKS production cluster (`eks-production`) に panicboat monorepo の **monolith + frontend + reverse-proxy** 3 services を actual deploy。AWS RDS PostgreSQL provision で K8s 内 PostgreSQL から切替、 OTel SDK init (= L1) + Instrumentation CR (= L2) で 3-layer observability foundation 整備、 Flux Image Update Automation (= digest reflection) で main merge → auto-deploy chain 確立。

**Architecture:** **2 PRs structure**: (1) 並行 monorepo PR で terragrunt RDS provision + application code OTel SDK init + K8s manifests 修正 + Flux Image Update Automation 設定 + README documentation update、 (2) Platform PR で Instrumentation CR deploy + monorepo Flux Kustomization resume (= suspend: true → false)。 並行 monorepo + platform PR は同日 merge。 注: 旧 plan 案で "Pre-merge fix forward PR for Makefile #22" を 3 PRs structure に含めていたが、 真因 re-diagnosis (= subagent aqua 未利用) で Makefile 修正不要と判断、 PR structure は 2 PRs に simplify。

**Tech Stack:** AWS RDS for PostgreSQL 17.x (= `db.t4g.micro` Single-AZ) / monorepo terragrunt scaffolding (= `template/terragrunt/` template) / Hanami 2.3 + `opentelemetry-sdk` + `opentelemetry-instrumentation-all` / Next.js 16 + `@opentelemetry/sdk-node` + `@opentelemetry/auto-instrumentations-node` / OTel Operator chart 0.112.1 (= 6-1 deploy 済) + Instrumentation CR / Flux v1.1.1 ImageUpdateAutomation + `digestReflectionPolicy: Always` (= latest tag の digest auto-track) / cert-manager `selfsigned-cluster-issuer` (= 既存) / **aqua-pinned tools** (= helm v3.17.3 / helmfile v0.169.2 / kustomize v5.6.0、 全 actor で deterministic hydrate ensure)

**Spec:** `docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md`

---

## File Structure

### platform 新規作成 / 修正 (= Platform PR)

```
kubernetes/components/opentelemetry/production/kustomization/   # 新規 directory
├── kustomization.yaml      # 新規 (= resources に instrumentation.yaml)
└── instrumentation.yaml    # 新規 (= Instrumentation CR、 namespace default)

kubernetes/components/opentelemetry/production/helmfile.yaml    # 修正なし (= 既 6-1 で作成)
kubernetes/components/opentelemetry/production/values.yaml.gotmpl   # 修正なし (= 既 6-1 で作成、 fix forward 反映済)

kubernetes/clusters/production/repositories/monorepo.yaml       # 修正 (= Kustomization spec.suspend: true → false)
```

### platform 自動生成 (= production hydrate output)

```
kubernetes/manifests/production/opentelemetry/manifest.yaml    # 修正 (= Instrumentation CR の hydrate 結果追加)
```

### monorepo 新規作成 / 修正 (= 並行 monorepo PR)

```
services/monolith/terragrunt/                  # 新規 directory
├── modules/
│   ├── main.tf            # 新規 (= aws_db_instance + aws_db_subnet_group + aws_security_group + aws_secretsmanager_secret)
│   ├── variables.tf       # 新規 (= aws_region, environment, common_tags 等)
│   ├── outputs.tf         # 新規 (= rds_endpoint, secret_arn 等)
│   └── terraform.tf       # 新規 (= provider 設定)
└── envs/develop/
    ├── env.hcl            # 新規 (= environment-specific 設定)
    └── terragrunt.hcl     # 新規 (= include root + env)

services/monolith/workspace/Gemfile                              # 修正 (= 3 OTel gem 追加)
services/monolith/workspace/Gemfile.lock                         # 修正 (= bundle install 結果、 自動)
services/monolith/workspace/config/initializers/opentelemetry.rb # 新規 (= OpenTelemetry::SDK.configure)

services/frontend/workspace/package.json                         # 修正 (= 3 OTel npm 追加)
services/frontend/workspace/pnpm-lock.yaml                       # 修正 (= pnpm install 結果、 自動)
services/frontend/workspace/instrumentation.ts                   # 新規 (= NodeSDK init)
services/frontend/workspace/next.config.ts                       # 修正 (= experimental.instrumentationHook 確認、 必要時)

services/monolith/kubernetes/base/deployment.yaml                # 修正 (= reloader annotation + envFrom secretRef + image marker comment + auto-injection annotation)
services/monolith/kubernetes/overlays/develop/configmap.yaml     # 修正 (= DATABASE_URL 削除)
services/monolith/kubernetes/overlays/develop/external-secret.yaml   # 新規 (= ExternalSecret monolith-database)
services/monolith/kubernetes/overlays/develop/kustomization.yaml # 修正 (= postgresql resource 削除 + external-secret.yaml 追加)
services/monolith/kubernetes/overlays/develop/postgresql/        # 削除 (= K8s 内 PostgreSQL Pod + Service)

services/frontend/kubernetes/base/deployment.yaml                # 修正 (= reloader annotation + image marker comment + auto-injection annotation)

clusters/develop/services/monolith/                              # 修正
├── kustomization.yaml      # 修正 (= resources に image-* 追加)
├── service.yaml            # 修正なし (= 既 Flux Kustomization)
├── image-repository.yaml   # 新規
├── image-policy.yaml       # 新規
└── image-automation.yaml   # 新規

clusters/develop/services/frontend/                              # 修正
├── kustomization.yaml      # 修正 (= 同上)
├── service.yaml            # 修正なし
├── image-repository.yaml   # 新規
├── image-policy.yaml       # 新規
└── image-automation.yaml   # 新規

README.md                   # 修正 (= getting-started + mermaid + service 説明 update)
README-ja.md                # 修正 (= 同上日本語版)
```

### 変更しないファイル

- `services/reverse-proxy/` (= 既 6-1 で deploy 済、 6-2 で touch なし)
- monorepo の他 service / config (= deploy-actions workflow / 他 services 等、 6-2 scope 外)

---

## Task 0: Pre-flight + branch state verify

**Files:** (確認のみ、変更なし)

**Context:** Phase 6-2 開始前に cluster 状態 + branch 状態 + monorepo の現状を確認。 Phase 6-1 全 4 PRs (= #323 / #590 / #327 / #329) merged 状態を baseline、 Phase 6-2 で application 投入する前提を verify。

- [ ] **Step 1: Branch state 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
git fetch origin main
git log --oneline origin/main..HEAD
```

Expected: spec commit 1 つ ahead

```
bc709c1 docs(eks): Phase 6-2 — monorepo application deploy spec
```

- [ ] **Step 2: Phase 1-6 完了状態 verify (= 6-1 component 健全性 + 過去 PRs merged)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- 6-1 deploy 済 component ---"
kubectl get gateway -n default cilium-gateway -o jsonpath="Accepted={.status.conditions[?(@.type==\"Accepted\")].status} Programmed={.status.conditions[?(@.type==\"Programmed\")].status}{\"\n\"}"
kubectl get gitrepository -n flux-system monorepo -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"
kubectl get kustomization -n flux-system monorepo-cluster -o jsonpath="Suspended={.spec.suspend}{\"\n\"}"
kubectl get deploy -n opentelemetry-operator-system opentelemetry-operator -o jsonpath="Available={.status.conditions[?(@.type==\"Available\")].status}{\"\n\"}"
echo ""
echo "--- ESO + cert-manager + Reloader ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"
kubectl get clusterissuer selfsigned-cluster-issuer -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"
kubectl get deploy -n reloader reloader-reloader -o jsonpath="Available={.status.conditions[?(@.type==\"Available\")].status}{\"\n\"}"
echo ""
echo "--- Beyla + Hubble + Mimir ---"
kubectl get ds -n monitoring beyla --no-headers
kubectl get pods -n kube-system -l k8s-app=hubble-relay --no-headers | head -1
kubectl get pods -n monitoring -l app.kubernetes.io/name=mimir --no-headers | head -1'
```

Expected:
- Gateway cilium-gateway Accepted=True Programmed=True
- GitRepository monorepo Ready=True
- Kustomization monorepo-cluster Suspended=true
- OTel Operator Available=True
- ESO + cert-manager + Reloader 全 Ready / Available
- Beyla DaemonSet 4/4 + Hubble Pod Running + Mimir Pod Running

- [ ] **Step 3: GHCR image tag pattern 確認 (= deploy-actions container-builder の actual tagging strategy)**

```bash
gh api -H "Accept: application/vnd.github+json" /users/panicboat/packages/container/monorepo%2Fmonolith/versions 2>&1 | jq '.[0:5] | .[] | {tags: .metadata.container.tags, created: .created_at}' 2>&1 | head -30
```

Expected: 各 version の tags array に以下 pattern が混在
- `sha-<7chars>` (= 例: `sha-abc1234`、 docker/metadata-action `type=sha` 結果)
- `latest` (= main branch のみ)
- `panicboat` (= actor name)
- `pr-<n>` (= PR 時のみ)

→ ImagePolicy filterTags は **`^latest$`** で track、 `digestReflectionPolicy: Always` で digest auto-pick (= sha tag は random、 alphabetical/numerical で 順序制御困難なため digest pin pattern 採用)

- [ ] **Step 4: ESO IAM policy 確認 (= secret access prefix)**

```bash
grep -A 10 "secretsmanager:GetSecretValue" /Users/takanokenichi/GitHub/panicboat/platform/aws/eks-secrets/modules/main.tf
```

Expected:

```
Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
```

→ wildcard `secret:*` access、 新 secret `panicboat/monolith/database` も自動 access 可、 platform `aws/eks-secrets/` 修正不要 (= spec Risk #2 mitigation 確定)

- [ ] **Step 5: 引き継ぎ #22 status 確認 (= re-diagnosis 後)**

引き継ぎ #22 は re-diagnosis 結果 "subagent aqua 未利用" が真因と判明、 Makefile 修正不要 (= Pre-merge fix forward PR #336 は close 済)。 解消は Step 7 (= aqua install) で対応。

```bash
gh pr view 336 --repo panicboat/platform --json state 2>&1 | head -3
```

Expected: PR #336 `state: CLOSED` (= Makefile 修正 approach は close、 root cause fix = aqua 利用)。

- [ ] **Step 6: monorepo PR 用 worktree 作成 (= 並行 monorepo PR の base)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo
git worktree list
git fetch origin main
git worktree add -b feat/phase-6-2-application-deploy .claude/worktrees/feat-phase-6-2-application-deploy origin/main
ls .claude/worktrees/feat-phase-6-2-application-deploy/services/
```

Expected:
- worktree 作成成功 (= branch `feat/phase-6-2-application-deploy`)
- services/ に 3 ディレクトリ (= frontend / monolith / reverse-proxy、 nginx は 6-1 削除済)

- [ ] **Step 7: aqua install (= 引き継ぎ #22 root cause fix)**

panicboat platform は aqua で tool version pin (= `helm v3.17.3` / `helmfile v0.169.2` / `kustomize v5.6.0`)、 全 actor で deterministic hydrate ensure。 subagent dispatch 時に aqua install を実施し、 aqua's helm / helmfile / kustomize で hydrate を行う。

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
which aqua || (curl -L https://raw.githubusercontent.com/aquaproj/aqua-installer/v3.0.1/aqua-installer | bash)
aqua install --config .github/aqua.yaml
helm version --short
helmfile version
kustomize version
```

Expected:
- aqua install 成功
- `helm version`: `v3.17.3` (= aqua-pinned)
- `helmfile version`: `v0.169.2`
- `kustomize version`: `v5.6.0`

注: 各 subsequent task で subagent dispatch 時に **aqua install + aqua-pinned tools 利用** を controller instruction で明示する (= 全 task の hydrate / template / build 動作を deterministic に保つ)。

---

## Task 1: 引き継ぎ #22 root cause fix (= subagent aqua 利用 confirm、 Makefile 修正不要)

**Files:** (修正なし、 Task 0 Step 7 で aqua install 実施済の確認のみ)

**Context:** 引き継ぎ #22 (= 旧 categorize "Makefile hydrate-component の kube-version 固定") の re-diagnosis。 真因は subagent が aqua-pinned helm (= v3.17.3) を利用していないこと (= helm version 差で chart の semverCompare 分岐結果が differ、 noise diff 発生)。 Makefile に `--kube-version` flag 追加は defensive measure に留まり root cause fix でない。

**Root cause fix**: subagent dispatch instruction で aqua install + aqua-pinned helm / helmfile / kustomize 利用を明示。 panicboat platform の standard tool version (= aqua で pin 済) を全 actor で利用 ensure。

- [ ] **Step 1: aqua install 確認 (= Task 0 Step 7 で実施済の re-verify)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
helm version --short
helmfile version
kustomize version
```

Expected:
- `helm version`: `v3.17.3` (= aqua-pinned)
- `helmfile version`: `v0.169.2`
- `kustomize version`: `v5.6.0`

aqua install されていない場合は Task 0 Step 7 を再実施。

- [ ] **Step 2: hydrate validation (= aqua-pinned tools で既 baseline と一致確認)**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy/kubernetes
make hydrate-component COMPONENT=opentelemetry ENV=production
git diff manifests/production/opentelemetry/manifest.yaml | head -10
```

Expected: diff 0 line (= aqua-pinned helm v3.17.3 で hydrate、 既 baseline と一致、 noise diff なし)

注: もし diff が出る場合、 既 baseline が異なる helm version で生成された可能性あり。 その場合は別 PR で全 component re-hydrate (= deterministic baseline 確立) を検討。

- [ ] **Step 3: subsequent task subagent dispatch instruction の note**

各 subsequent task (= Task 2-) の subagent dispatch 時に controller が以下を instruction に含める:

```
aqua install --config /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy/.github/aqua.yaml
helm version --short  # v3.17.3 確認
helmfile version      # v0.169.2 確認
kustomize version     # v5.6.0 確認
```

aqua install + version 確認 step を全 task の冒頭に組み込む (= Phase 6-1 で missing だった、 6-2 で systematic 化)。

注: 本 task は file 修正 commit なし、 確認のみで完了。 Task 2 (= monorepo terragrunt RDS provision) に進む。

---

## Task 2: monorepo terragrunt RDS provision

**Files (= monorepo worktree):**
- Create: `services/monolith/terragrunt/modules/{main,variables,outputs,terraform}.tf`
- Create: `services/monolith/terragrunt/envs/develop/{env.hcl, terragrunt.hcl}`

**Context:** AWS RDS PostgreSQL を monorepo 側で provision。 monorepo `template/terragrunt/` scaffolding を base として copy + adjust。 RDS instance + subnet group + security group + Secrets Manager secret + random password を 1 module で provision。

- [ ] **Step 1: monorepo worktree に移動 + terragrunt scaffolding copy**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
mkdir -p services/monolith/terragrunt/modules services/monolith/terragrunt/envs/develop
cp template/terragrunt/envs/develop/env.hcl services/monolith/terragrunt/envs/develop/
cp template/terragrunt/envs/develop/terragrunt.hcl services/monolith/terragrunt/envs/develop/
cp template/terragrunt/modules/terraform.tf services/monolith/terragrunt/modules/
ls services/monolith/terragrunt/
```

Expected:
- `envs/develop/{env.hcl, terragrunt.hcl}` 2 files
- `modules/terraform.tf` 1 file (= remaining 3 file は新規作成)

- [ ] **Step 2: modules/main.tf 作成 (= RDS + Secrets Manager + 関連 resource)**

`services/monolith/terragrunt/modules/main.tf` を新規作成:

```terraform
# =============================================================================
# AWS RDS PostgreSQL for monolith service
# =============================================================================
# Phase 6-2 (= application deploy) で provision。 db.t4g.micro Single-AZ、
# eks-production VPC private subnets で deploy、 monolith Pod のみから
# 5432 access 許可。 master credentials は AWS Secrets Manager で管理、
# ESO 経由で K8s Secret に注入。
# =============================================================================

# Get current AWS account information
data "aws_caller_identity" "current" {}

# eks-production VPC + private subnets (= platform aws/vpc/ で provision 済)
data "aws_vpc" "eks_production" {
  tags = {
    Name = "eks-production"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.eks_production.id]
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Random password for RDS master credentials
resource "random_password" "monolith_db_master" {
  length  = 32
  special = true
  # RDS PostgreSQL で許可される special chars
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# AWS Secrets Manager secret for RDS credentials (= ESO で取得)
resource "aws_secretsmanager_secret" "monolith_database" {
  name                    = "panicboat/monolith/database"
  description             = "PostgreSQL credentials for monolith service"
  recovery_window_in_days = 0  # immediate delete (= dev env)
  tags                    = var.common_tags
}

resource "aws_secretsmanager_secret_version" "monolith_database" {
  secret_id = aws_secretsmanager_secret.monolith_database.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.monolith_db_master.result
    host     = aws_db_instance.monolith.address
    port     = aws_db_instance.monolith.port
    database = "monolith"
    url      = "postgres://postgres:${random_password.monolith_db_master.result}@${aws_db_instance.monolith.address}:${aws_db_instance.monolith.port}/monolith"
  })
}

# Security group: monolith Pod からの 5432 access のみ許可
resource "aws_security_group" "monolith_db" {
  name        = "monolith-database-${var.environment}"
  description = "Security group for monolith RDS database (= ${var.environment})"
  vpc_id      = data.aws_vpc.eks_production.id
  tags        = var.common_tags
}

# Inbound: VPC CIDR 全体から 5432 (= monolith Pod が ClusterIP 経由で access)
resource "aws_security_group_rule" "monolith_db_ingress" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.eks_production.cidr_block]
  security_group_id = aws_security_group.monolith_db.id
  description       = "PostgreSQL access from VPC (= monolith Pod)"
}

# DB subnet group (= eks-production VPC private subnets)
resource "aws_db_subnet_group" "monolith" {
  name       = "monolith-${var.environment}"
  subnet_ids = data.aws_subnets.private.ids
  tags       = var.common_tags
}

# RDS instance: PostgreSQL 17.x、 db.t4g.micro、 Single-AZ、 gp3 20 GiB
resource "aws_db_instance" "monolith" {
  identifier     = "monolith-${var.environment}"
  engine         = "postgres"
  engine_version = "17.4"  # 最新 stable (= AWS RDS for PostgreSQL 17.x)
  instance_class = "db.t4g.micro"
  allocated_storage     = 20
  max_allocated_storage = 100  # auto-scale upper limit
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "monolith"
  username = "postgres"
  password = random_password.monolith_db_master.result

  db_subnet_group_name   = aws_db_subnet_group.monolith.name
  vpc_security_group_ids = [aws_security_group.monolith_db.id]
  publicly_accessible    = false
  multi_az               = false  # 個人 dev environment

  backup_retention_period = 7
  backup_window           = "16:00-17:00"  # JST 1-2 AM
  maintenance_window      = "sun:17:00-sun:18:00"  # JST Sunday 2-3 AM

  skip_final_snapshot = true  # dev env、 destroy 時 snapshot 不要
  deletion_protection = false  # dev env

  tags = var.common_tags
}
```

- [ ] **Step 3: modules/variables.tf 作成**

`services/monolith/terragrunt/modules/variables.tf`:

```terraform
variable "project_name" {
  type        = string
  description = "Project name (= services)"
}

variable "environment" {
  type        = string
  description = "Environment name (= develop / staging / production)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "ap-northeast-1"
}

variable "common_tags" {
  type        = map(string)
  description = "Common resource tags"
  default     = {}
}
```

- [ ] **Step 4: modules/outputs.tf 作成**

`services/monolith/terragrunt/modules/outputs.tf`:

```terraform
output "rds_endpoint" {
  value       = aws_db_instance.monolith.address
  description = "RDS instance endpoint hostname"
}

output "rds_port" {
  value       = aws_db_instance.monolith.port
  description = "RDS instance port"
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.monolith_database.arn
  description = "AWS Secrets Manager secret ARN for RDS credentials"
}

output "secret_name" {
  value       = aws_secretsmanager_secret.monolith_database.name
  description = "AWS Secrets Manager secret name (= ESO ExternalSecret で参照)"
}
```

- [ ] **Step 5: terraform.tf (= provider) 確認**

```bash
cat services/monolith/terragrunt/modules/terraform.tf
```

Expected: scaffolding copy 結果が aws + random provider 設定を含む。 含まない場合追加:

```terraform
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

- [ ] **Step 6: envs/develop/terragrunt.hcl の terragrunt-state path 修正**

scaffolding copy で `template/terragrunt/root.hcl` の参照は `find_in_parent_folders` で動作するが、 state path は `services/template/${environment}` になる (= template scaffolding の影響)。 monolith 用に override:

`services/monolith/terragrunt/envs/develop/terragrunt.hcl` を以下に修正 (= remote_state override 追加):

```hcl
# terragrunt.hcl - monolith development environment Terragrunt configuration

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules
terraform {
  source = "../../modules"
}

# Override remote_state for monolith service path (= template の "services/template/${env}" 上書き)
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "terragrunt-state-${get_aws_account_id()}"
    key            = "services/monolith/${include.env.locals.environment}/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terragrunt-state-locks"
    encrypt        = true
  }
}

# Environment-specific inputs
inputs = {
  aws_region = include.env.locals.aws_region
  common_tags = merge(
    {
      Environment = include.env.locals.environment
    },
    include.env.locals.additional_tags
  )
}
```

- [ ] **Step 7: envs/develop/env.hcl の Purpose 修正**

`services/monolith/terragrunt/envs/develop/env.hcl` の `Purpose` tag を `"template"` から `"monolith"` に修正:

```hcl
locals {
  environment = "develop"
  aws_region  = "ap-northeast-1"
  additional_tags = {
    CostCenter   = "develop"
    Owner        = "panicboat"
    Purpose      = "monolith"
    AutoShutdown = "enabled"
  }
}
```

- [ ] **Step 8: terragrunt validate (= local validation、 actual apply は monorepo deploy-actions trigger 後)**

```bash
cd services/monolith/terragrunt/envs/develop
terragrunt init -backend=false
terragrunt validate
```

Expected:
- `terragrunt init` 成功 (= modules + provider download)
- `terragrunt validate` で "Success! The configuration is valid." (= syntax error なし)

注: actual `terragrunt apply` は本 task では実施しない (= deploy-actions の monorepo PR merge 時 auto-trigger を期待、 PR description で manual approval guard あり)。 ただし、 dev cluster で先 deploy + validation したい場合は plan 段階で `terragrunt apply` を別 step として実施可能。

- [ ] **Step 9: commit terragrunt files**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
git add services/monolith/terragrunt/
git commit -s -m "feat(monolith): terragrunt RDS provision (= Phase 6-2)" -m "panicboat platform Phase 6-2 (= monorepo application deploy) の AWS RDS
PostgreSQL provision。 monorepo template/terragrunt scaffolding を base
として services/monolith/terragrunt/ に新規 deploy。" -m "Spec:
- engine: PostgreSQL 17.4 (= 最新 stable)
- instance class: db.t4g.micro (= ARM、 1 vCPU / 1 GiB RAM)
- Multi-AZ: false (= 個人 dev environment)
- storage: gp3 20 GiB (= max_allocated_storage 100 で auto-scale)
- backup retention: 7 days
- public access: false
- subnet group: eks-production VPC private subnets (= data source 参照)
- security group: VPC CIDR 内から 5432 access のみ
- master credentials: random password + Secrets Manager 管理
  (= panicboat/monolith/database)
月額 cost: ~\$15/month (= db.t4g.micro \$11.7 + gp3 \$2.3)" -m "ESO IAM (= Phase 4-2 で wildcard secret:* permission) で auto access、
platform aws/eks-secrets/ 修正不要。"
```

---

## Task 3: monorepo application code OTel SDK init (= L1)

**Files (= monorepo worktree):**
- Modify: `services/monolith/workspace/Gemfile`
- Create: `services/monolith/workspace/config/initializers/opentelemetry.rb`
- Modify: `services/frontend/workspace/package.json`
- Create: `services/frontend/workspace/instrumentation.ts`
- Modify: `services/frontend/workspace/next.config.ts`

**Context:** OTel SDK init (= L1) で application code から OpenTelemetry を initialize。 L2 (= Operator auto-injection) が env vars (= `OTEL_EXPORTER_OTLP_ENDPOINT` 等) を Pod に inject、 L1 がそれらを detect + use する pattern。 custom span は application code 内で `tracer.in_span(...)` 等で追加可能 (= business logic span)。

- [ ] **Step 1: Hanami Gemfile に OTel gem 追加**

`services/monolith/workspace/Gemfile` の `gem "puma"` 行の **直後** に以下 3 行を追加:

```ruby
# =============================================================================
# OpenTelemetry SDK + auto-instrumentation (= Phase 6-2)
# =============================================================================
gem "opentelemetry-sdk", "~> 1.4"
gem "opentelemetry-instrumentation-all", "~> 0.61"
gem "opentelemetry-exporter-otlp", "~> 0.27"
```

注: gem version pin は **5-1 L1 chart binary verify systematic step** 適用、 Gemfile.lock で具体 version 確定。

- [ ] **Step 2: bundle install で Gemfile.lock 更新**

```bash
cd services/monolith/workspace
bundle install
```

Expected:
- `Gemfile.lock` 更新 (= 3 OTel gem + 依存 gem 追加)
- exit code 0

- [ ] **Step 3: Hanami initializer 作成**

`services/monolith/workspace/config/initializers/opentelemetry.rb` を新規作成:

```ruby
# frozen_string_literal: true

# =============================================================================
# OpenTelemetry SDK initialization
# =============================================================================
# Phase 6-2 (= application deploy) で integrate。
#
# L2 (= OTel Operator auto-injection、 panicboat platform で deploy 済) が
# 以下の env vars を Pod に injection:
# - OTEL_EXPORTER_OTLP_ENDPOINT (= OTel Collector の OTLP receiver endpoint)
# - OTEL_RESOURCE_ATTRIBUTES (= service.name=monolith 等)
# - OTEL_TRACES_EXPORTER / OTEL_METRICS_EXPORTER / OTEL_LOGS_EXPORTER (= "otlp")
# - OTEL_PROPAGATORS (= "tracecontext,baggage")
#
# 本 initializer は OpenTelemetry::SDK.configure を trigger するだけで、
# env vars を auto-detect + auto-config。 custom span は app code 内で
# tracer.in_span(...) で追加可能。
# =============================================================================

require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "monolith"
  c.use_all # auto-instrument all installed instrumentation libraries
end
```

- [ ] **Step 4: Next.js package.json に OTel npm 追加**

`services/frontend/workspace/package.json` の `dependencies` section (= 既 deps list) に以下 3 packages を追加 (= alphabetical order で挿入):

```json
{
  "dependencies": {
    "@bufbuild/buf": "1.69.0",
    "@bufbuild/protobuf": "^2.12.0",
    "@connectrpc/connect": "^2.1.1",
    "@connectrpc/connect-node": "^2.1.1",
    "@opentelemetry/auto-instrumentations-node": "^0.62.0",
    "@opentelemetry/exporter-trace-otlp-grpc": "^0.59.0",
    "@opentelemetry/sdk-node": "^0.59.0",
    "@radix-ui/react-avatar": "^1.1.11",
    ...
  }
}
```

注: 既 deps を維持、 `@opentelemetry/*` 3 packages を alphabetical 位置 (= `@connectrpc/*` の直後、 `@radix-ui/*` の直前) に挿入。

- [ ] **Step 5: pnpm install で pnpm-lock.yaml 更新**

```bash
cd services/frontend/workspace
pnpm install
```

Expected:
- `pnpm-lock.yaml` 更新 (= 3 OTel packages + 依存 packages 追加)
- exit code 0

- [ ] **Step 6: Next.js instrumentation.ts 作成**

`services/frontend/workspace/instrumentation.ts` を新規作成:

```typescript
// =============================================================================
// OpenTelemetry SDK initialization for Next.js
// =============================================================================
// Phase 6-2 (= application deploy) で integrate。
//
// L2 (= OTel Operator auto-injection、 panicboat platform で deploy 済) が
// 以下の env vars を Pod に injection:
// - OTEL_EXPORTER_OTLP_ENDPOINT (= OTel Collector の OTLP receiver endpoint)
// - OTEL_RESOURCE_ATTRIBUTES (= service.name=frontend 等)
// - OTEL_PROPAGATORS (= "tracecontext,baggage")
//
// Next.js 16+ の instrumentation hook (= register function) で SDK を
// process startup 時に initialize。 NEXT_RUNTIME=nodejs ガードで edge
// runtime (= middleware) を除外。
// =============================================================================

import { NodeSDK } from "@opentelemetry/sdk-node";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-grpc";

export function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const sdk = new NodeSDK({
      traceExporter: new OTLPTraceExporter(),
      instrumentations: [getNodeAutoInstrumentations()],
    });
    sdk.start();
  }
}
```

- [ ] **Step 7: next.config.ts で instrumentation hook 確認**

`services/frontend/workspace/next.config.ts` を read + 必要に応じて修正:

```bash
cat services/frontend/workspace/next.config.ts
```

Next.js 16+ では `experimental.instrumentationHook` は default true (= 削除済 config option)、 既 default で動作。 ただし next.config.ts に明示記載があれば確認。

(= 確認のみ、 通常修正不要)

- [ ] **Step 8: commit application code OTel SDK init**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
git add services/monolith/workspace/Gemfile services/monolith/workspace/Gemfile.lock services/monolith/workspace/config/initializers/opentelemetry.rb
git add services/frontend/workspace/package.json services/frontend/workspace/pnpm-lock.yaml services/frontend/workspace/instrumentation.ts
git commit -s -m "feat(observability): OTel SDK init (= L1) for monolith + frontend" -m "Phase 6-2 application deploy で OTel SDK init を application code 側に追加。
L2 (= OTel Operator auto-injection、 panicboat platform で deploy 済)
が env vars (= OTEL_EXPORTER_OTLP_ENDPOINT 等) を Pod に injection、
L1 (= 本 commit) がそれらを detect + use する pattern。" -m "monolith (= Hanami):
- Gemfile に opentelemetry-sdk + opentelemetry-instrumentation-all
  + opentelemetry-exporter-otlp 追加
- config/initializers/opentelemetry.rb で OpenTelemetry::SDK.configure" -m "frontend (= Next.js):
- package.json に @opentelemetry/sdk-node + auto-instrumentations-node
  + exporter-trace-otlp-grpc 追加
- instrumentation.ts (= Next.js 16+ register hook) で NodeSDK init
  with NEXT_RUNTIME=nodejs guard"
```

---

## Task 4: monorepo K8s manifests 修正 (= ExternalSecret + Reloader + auto-injection)

**Files (= monorepo worktree):**
- Modify: `services/monolith/kubernetes/base/deployment.yaml`
- Modify: `services/monolith/kubernetes/overlays/develop/configmap.yaml`
- Create: `services/monolith/kubernetes/overlays/develop/external-secret.yaml`
- Modify: `services/monolith/kubernetes/overlays/develop/kustomization.yaml`
- Delete: `services/monolith/kubernetes/overlays/develop/postgresql/` (= directory 全体)
- Modify: `services/frontend/kubernetes/base/deployment.yaml`

**Context:** K8s 内 PostgreSQL から AWS RDS 切替 + Reloader annotation で secret rotation auto-rollout + OTel auto-injection annotation。 ImageUpdateAutomation marker comment は Task 5 で別途追加。

- [ ] **Step 1: monolith deployment.yaml 修正 (= base)**

`services/monolith/kubernetes/base/deployment.yaml` を以下に修正:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monolith
  annotations:
    reloader.stakater.com/auto: "true"  # ConfigMap / Secret 変更時 auto-rollout
spec:
  replicas: 1
  revisionHistoryLimit: 1
  selector:
    matchLabels:
      app: monolith
  template:
    metadata:
      labels:
        app: monolith
      annotations:
        instrumentation.opentelemetry.io/inject-ruby: "default/panicboat-application"  # L2 OTel Operator auto-injection
    spec:
      containers:
        - name: monolith
          image: ghcr.io/panicboat/monorepo/monolith:latest # {"$imagepolicy": "flux-system:monolith"}
          imagePullPolicy: IfNotPresent
          command: ["./bin/start"]
          ports:
            - containerPort: 9001
          envFrom:
            - configMapRef:
                name: monolith
            - secretRef:
                name: monolith-database  # ExternalSecret で生成 (= develop overlay)
```

注: 既 base から **4 箇所** 追加:
1. `metadata.annotations.reloader.stakater.com/auto: "true"` (= Reloader annotation)
2. `template.metadata.annotations.instrumentation.opentelemetry.io/inject-ruby: "default/panicboat-application"` (= OTel auto-injection、 platform 側で deploy する Instrumentation CR を参照)
3. `template.spec.containers[0].envFrom` に `secretRef` 追加 (= configMapRef + secretRef の 2 source)
4. image 行に `# {"$imagepolicy": "flux-system:monolith"}` marker comment (= Task 5 Flux Image Update Automation の Setters strategy 用)

- [ ] **Step 2: monolith develop overlay configmap.yaml 修正**

`services/monolith/kubernetes/overlays/develop/configmap.yaml` を以下に修正 (= DATABASE_URL 削除、 HANAMI_ENV 維持):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: monolith
data:
  HANAMI_ENV: development
```

注: `DATABASE_URL` を削除 (= ExternalSecret に migrate)、 残り `HANAMI_ENV` のみ ConfigMap 管理。

- [ ] **Step 3: monolith develop overlay external-secret.yaml 新規作成**

`services/monolith/kubernetes/overlays/develop/external-secret.yaml` を新規作成:

```yaml
# =============================================================================
# ExternalSecret for monolith database credentials
# =============================================================================
# Phase 6-2 (= application deploy) で AWS RDS への credentials を ESO 経由
# で K8s Secret に inject。 panicboat/monolith/database secret は monorepo
# terragrunt provision (= services/monolith/terragrunt/) で自動生成。
#
# Reloader annotation (= base deployment.yaml) で secret 変更時に Pod
# auto-rollout、 RDS password rotation で application が新 credential を
# pickup する chain。
# =============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: monolith-database
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager  # Phase 4-2 で deploy 済
  target:
    name: monolith-database
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: panicboat/monolith/database
        property: url  # JSON object の "url" property = postgres://...
```

- [ ] **Step 4: monolith develop overlay kustomization.yaml 修正**

`services/monolith/kubernetes/overlays/develop/kustomization.yaml` を以下に修正 (= postgresql resource 削除、 external-secret.yaml 追加):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
patches:
  - path: configmap.yaml
  - path: deployment.yaml
```

注: 既存から **2 箇所** 修正:
1. `resources` から `postgresql` 削除 (= K8s 内 PostgreSQL 廃止)
2. `resources` に `external-secret.yaml` 追加

- [ ] **Step 5: monolith develop overlay postgresql directory 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
rm -rf services/monolith/kubernetes/overlays/develop/postgresql/
ls services/monolith/kubernetes/overlays/develop/
```

Expected: directory 削除完了、 残り `configmap.yaml / deployment.yaml / external-secret.yaml / kustomization.yaml` 4 files

- [ ] **Step 6: monolith develop overlay deployment.yaml patch 確認**

`services/monolith/kubernetes/overlays/develop/deployment.yaml` (= 既 patch file) を read:

```bash
cat services/monolith/kubernetes/overlays/develop/deployment.yaml
```

既 patch content (= image tag override 等) を確認、 通常 6-2 で修正不要。

- [ ] **Step 7: frontend deployment.yaml 修正 (= base)**

`services/frontend/kubernetes/base/deployment.yaml` を以下に修正:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  annotations:
    reloader.stakater.com/auto: "true"  # ConfigMap 変更時 auto-rollout
spec:
  replicas: 1
  revisionHistoryLimit: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
      annotations:
        instrumentation.opentelemetry.io/inject-nodejs: "default/panicboat-application"  # L2 OTel Operator auto-injection
    spec:
      containers:
        - name: frontend
          image: ghcr.io/panicboat/monorepo/frontend:latest # {"$imagepolicy": "flux-system:frontend"}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          envFrom:
            - configMapRef:
                name: frontend
```

注: 既 base から **3 箇所** 追加:
1. `metadata.annotations.reloader.stakater.com/auto: "true"` (= Reloader annotation)
2. `template.metadata.annotations.instrumentation.opentelemetry.io/inject-nodejs: "default/panicboat-application"` (= OTel auto-injection)
3. image 行に `# {"$imagepolicy": "flux-system:frontend"}` marker comment (= Task 5 Flux Image Update Automation の Setters strategy 用)

- [ ] **Step 8: kustomize build で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
kustomize build services/monolith/kubernetes/overlays/develop/ 2>&1 | grep -E "kind:|name:" | head -20
kustomize build services/frontend/kubernetes/overlays/develop/ 2>&1 | grep -E "kind:|name:" | head -10
```

Expected:
- monolith overlay: Deployment + Service + ConfigMap + ExternalSecret 出力 (= postgresql Pod / Service 不在)
- frontend overlay: Deployment + Service + ConfigMap 出力

- [ ] **Step 9: commit K8s manifests 修正**

```bash
git add -A services/monolith/kubernetes/ services/frontend/kubernetes/
git status
git commit -s -m "feat(k8s): RDS 切替 + Reloader + OTel auto-injection (= Phase 6-2)" -m "Phase 6-2 application deploy で K8s manifests を修正。" -m "monolith:
- base/deployment.yaml: Reloader annotation + OTel ruby auto-injection
  annotation + envFrom に secretRef 追加 (= configMap + secret の 2 source)
- overlays/develop/configmap.yaml: DATABASE_URL 削除 (= ExternalSecret 移行)
- overlays/develop/external-secret.yaml: AWS Secrets Manager
  panicboat/monolith/database から K8s Secret monolith-database 生成
- overlays/develop/kustomization.yaml: postgresql resource 削除
  + external-secret.yaml 追加
- overlays/develop/postgresql/ 削除 (= K8s 内 PostgreSQL Pod + Service)" -m "frontend:
- base/deployment.yaml: Reloader annotation + OTel nodejs auto-injection
  annotation"
```

---

## Task 5: monorepo Flux Image Update Automation (= digest reflection)

**Files (= monorepo worktree):**
- Create: `clusters/develop/services/monolith/{image-repository.yaml, image-policy.yaml, image-automation.yaml}`
- Create: `clusters/develop/services/frontend/{image-repository.yaml, image-policy.yaml, image-automation.yaml}`
- Modify: `clusters/develop/services/monolith/kustomization.yaml`
- Modify: `clusters/develop/services/frontend/kustomization.yaml`
- Modify: `services/monolith/kubernetes/base/deployment.yaml` (= image marker comment 追加)
- Modify: `services/frontend/kubernetes/base/deployment.yaml` (= 同)

**Context:** Flux v1.1.1 の `digestReflectionPolicy: Always` で `latest` tag の digest を auto-track + ImageUpdateAutomation で deployment.yaml の image を `image:latest@sha256:<digest>` 形式に update。 main merge → container-builder GHCR push → 5m polling で digest detect → deployment.yaml update commit + push → Flux Reconcile (= 10m) → Pod rolling update の chain 確立。

- [ ] **Step 1: monolith image-repository.yaml 新規作成**

`clusters/develop/services/monolith/image-repository.yaml`:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: monolith
  namespace: flux-system
spec:
  image: ghcr.io/panicboat/monorepo/monolith
  interval: 5m
```

- [ ] **Step 2: monolith image-policy.yaml 新規作成**

`clusters/develop/services/monolith/image-policy.yaml`:

```yaml
# =============================================================================
# ImagePolicy for monolith (= digest reflection pattern)
# =============================================================================
# Flux v1.1.1 の digestReflectionPolicy: Always で latest tag の digest を
# auto-track。 sha tag (= deploy-actions container-builder の type=sha
# default short 7chars) は random で alphabetical / numerical order で
# 最新 pick 不可のため、 latest tag pin + digest reflection を採用。
# =============================================================================
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: monolith
  namespace: flux-system
  labels:
    service: monolith
spec:
  imageRepositoryRef:
    name: monolith
  digestReflectionPolicy: Always
  filterTags:
    pattern: '^latest$'
  policy:
    alphabetical:
      order: asc
```

- [ ] **Step 3: monolith image-automation.yaml 新規作成**

`clusters/develop/services/monolith/image-automation.yaml`:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: monolith
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: monorepo
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: panicboat@gmail.com
        name: panicboat
      messageTemplate: |
        chore(monolith): bump image to {{range .Updated.Images}}{{println .}}{{end}}
    push:
      branch: main
  update:
    path: ./services/monolith/kubernetes
    strategy: Setters
```

- [ ] **Step 4: monolith clusters/develop/services/monolith/kustomization.yaml 修正**

既 file (= service.yaml のみ resources) に Image Update Automation 3 file 追加:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - image-repository.yaml
  - image-policy.yaml
  - image-automation.yaml
```

- [ ] **Step 5: monolith image marker comment は Task 4 Step 1 で既追加済**

monolith deployment.yaml の image 行 marker comment (`# {"$imagepolicy": "flux-system:monolith"}`) は Task 4 Step 1 で deployment.yaml 修正と同時に追加済。 本 Task 5 では Flux image-* yaml の 3 file (= ImageRepository / ImagePolicy / ImageUpdateAutomation) の作成のみ。

注: marker comment の効果 = Flux ImageUpdateAutomation の Setters strategy が image 行を update。 ImagePolicy `monolith` の picked image + digest を反映、 結果として image は `ghcr.io/panicboat/monorepo/monolith:latest@sha256:<digest>` 形式に update される (= digestReflectionPolicy: Always の effect)。

- [ ] **Step 6: frontend Image Update Automation 同 pattern**

`clusters/develop/services/frontend/image-repository.yaml`:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: frontend
  namespace: flux-system
spec:
  image: ghcr.io/panicboat/monorepo/frontend
  interval: 5m
```

`clusters/develop/services/frontend/image-policy.yaml`:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: frontend
  namespace: flux-system
  labels:
    service: frontend
spec:
  imageRepositoryRef:
    name: frontend
  digestReflectionPolicy: Always
  filterTags:
    pattern: '^latest$'
  policy:
    alphabetical:
      order: asc
```

`clusters/develop/services/frontend/image-automation.yaml`:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: frontend
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: monorepo
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: panicboat@gmail.com
        name: panicboat
      messageTemplate: |
        chore(frontend): bump image to {{range .Updated.Images}}{{println .}}{{end}}
    push:
      branch: main
  update:
    path: ./services/frontend/kubernetes
    strategy: Setters
```

- [ ] **Step 7: frontend kustomization.yaml**

`clusters/develop/services/frontend/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - image-repository.yaml
  - image-policy.yaml
  - image-automation.yaml
```

注: frontend deployment.yaml の image marker comment は Task 4 Step 7 で base deployment.yaml 修正と同時に追加済。

- [ ] **Step 8: kustomize build で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
kustomize build clusters/develop/services/monolith/ 2>&1 | grep -E "kind:|name:" | head -20
kustomize build clusters/develop/services/frontend/ 2>&1 | grep -E "kind:|name:" | head -20
```

Expected:
- monolith: Flux Kustomization + ImageRepository + ImagePolicy + ImageUpdateAutomation 4 resources
- frontend: 同 4 resources

- [ ] **Step 9: commit Flux Image Update Automation**

```bash
git add clusters/develop/services/monolith/ clusters/develop/services/frontend/
git status
git commit -s -m "feat(flux): Image Update Automation for monolith + frontend" -m "Phase 6-2 application deploy で Flux Image Update Automation を monolith
+ frontend に追加。 削除済 nginx pattern を template として再 introduce、
ただし actual implementation は digest reflection (= sha tag は random で
alphabetical / numerical order で track 困難なため latest tag pin
+ digestReflectionPolicy: Always)。" -m "Chain:
main merge → container-builder GHCR push (= sha-<7chars> + latest +
panicboat 3 tag) → Flux ImageRepository が 5m polling で digest detect
→ ImagePolicy が latest tag の digest pick → ImageUpdateAutomation が
deployment.yaml の image を image:latest@sha256:<digest> 形式に update
+ commit + push to main → Flux Reconcile (= 10m) → Pod rolling update" -m "deployment.yaml の image 行 marker comment は Task 4 で既追加済。"
```

---

## Task 6: monorepo README documentation update (= 引き継ぎ #23 解消)

**Files (= monorepo worktree):**
- Modify: `README.md`
- Modify: `README-ja.md`

**Context:** Phase 6-1 monorepo PR (= #590 nginx 削除) で残っていた documentation drift の解消。 Phase 6-2 で application 投入と同期 update。

- [ ] **Step 1: README.md 修正**

`README.md` を以下の方針で修正:

1. **getting-started section** (= `127.0.0.1` の hosts entry 部分): `nginx.local` 削除、 `frontend.local` 維持、 monolith は internal gRPC で hosts entry 不要
2. **mermaid architecture diagram**: nginx node + edge 削除、 RDS node 追加 (= monolith → RDS 5432)、 service 数 3 (= monolith / frontend / reverse-proxy)
3. **deploy / GitOps section**: `nginx additionally uses ImageRepository...` を `monolith and frontend use Flux Image Update Automation (= digest reflection) for auto-deploy on main merge` に置換

具体修正 (= 元 README.md content を base に修正)、 file 全体は monorepo の現 README を read 確認後に sed / Edit で部分修正:

```bash
cat /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy/README.md
```

修正箇所 (= 各箇所 別 sed / Edit operation):

**修正 1**: `127.0.0.1 nginx.local` 削除

```bash
sed -i '' '/127.0.0.1 nginx.local/d' README.md
```

**修正 2**: mermaid diagram の nginx node 削除 (= 該当 line range を Edit で修正、 元 content:
```
CiliumGw -- "4. HTTPRoute<br>Host: nginx.local" --> AppPod[App Pod<br>services/nginx]
```
を削除、 RDS line 追加:
```
MonolithPod -- "6. PostgreSQL<br>5432" --> RDS[(AWS RDS<br>monolith-develop)]
```
)

**修正 3**: `nginx additionally uses...` line を 置換 (= sed -i):

```bash
sed -i '' 's/nginx additionally uses ImageRepository.*$/monolith and frontend use Flux Image Update Automation (= digest reflection) for auto-deploy on main merge./' README.md
```

注: 修正 2 (= mermaid) は line range で Edit tool 利用が確実、 sed では multi-line 操作困難。

- [ ] **Step 2: README-ja.md 修正 (= 同 修正の日本語版)**

`README-ja.md` を以下の方針で修正 (= 同 3 箇所):

1. getting-started: `nginx.local` 削除
2. mermaid diagram: nginx node 削除 + RDS 追加
3. deploy 説明: nginx auto-bump 説明を monolith/frontend digest reflection に変更

```bash
cat /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy/README-ja.md
```

修正は README.md と同 pattern (= sed + Edit)。

- [ ] **Step 3: validation (= rendered preview 確認)**

```bash
grep -i "nginx" /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy/README.md /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy/README-ja.md
```

Expected: `nginx` への reference が delete 完了 (= application service として nginx は除外、 reverse-proxy 内の nginx upstream proxy 利用 等の reference は OK)

- [ ] **Step 4: commit README update**

```bash
git add README.md README-ja.md
git commit -s -m "docs: update README for Phase 6-2 (= 引き継ぎ #23 解消)" -m "Phase 6-1 monorepo PR (= #590 nginx 削除) で残っていた documentation drift
の解消。 Phase 6-2 application 投入と同期 update。" -m "Changes:
- getting-started: nginx.local 削除 (= 既削除済 nginx service)
- mermaid architecture diagram: nginx node 削除 + RDS node 追加
- deploy 説明: nginx auto-bump (= 削除済 ImageRepository pattern) を
  monolith / frontend digest reflection (= Flux v1.1.1
  digestReflectionPolicy) 説明に置換" -m "両言語版 (= README.md + README-ja.md) 同期 update。"
```

---

## Task 7: monorepo PR 作成 + push + draft PR

**Files:** (PR description preparation)

**Context:** Task 2-6 で作成した全 commits を origin に push + draft PR 作成。

- [ ] **Step 1: monorepo branch 全 commits 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/monorepo/.claude/worktrees/feat-phase-6-2-application-deploy
git log --oneline origin/main..HEAD
```

Expected: 5 commits ahead

```
<hash> docs: update README for Phase 6-2 (= 引き継ぎ #23 解消)
<hash> feat(flux): Image Update Automation for monolith + frontend
<hash> feat(k8s): RDS 切替 + Reloader + OTel auto-injection (= Phase 6-2)
<hash> feat(observability): OTel SDK init (= L1) for monolith + frontend
<hash> feat(monolith): terragrunt RDS provision (= Phase 6-2)
```

- [ ] **Step 2: push monorepo branch**

```bash
git push -u origin HEAD
```

Expected: branch tracking 設定 + push 成功

- [ ] **Step 3: monorepo draft PR 作成**

```bash
gh pr create --draft --title "feat: Phase 6-2 application deploy (= RDS + OTel SDK + auto-bump)" --body "$(cat <<'EOF'
## Summary

panicboat platform Phase 6-2 (= application deploy) と並行で実施。 monolith + frontend application を panicboat platform (= eks-production cluster) に actual deploy する monorepo 側の修正。

## Context

- panicboat platform で Phase 6-2 spec / plan が決定 (= [platform PR (= TBD、 本 PR と同期 merge)](https://github.com/panicboat/platform/pulls))
- 本 PR は platform 側 spec の Component A (= AWS RDS provision) + Component B (= K8s manifests 修正) + Component C (= application code OTel SDK init) + Component E (= Flux Image Update Automation) に対応

詳細: [platform Phase 6-2 spec](https://github.com/panicboat/platform/blob/main/docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md)

## Changes

### terragrunt RDS provision (= Component A)

- `services/monolith/terragrunt/{modules/, envs/develop/}` 新規 directory
- AWS RDS PostgreSQL 17.4、 db.t4g.micro Single-AZ、 gp3 20 GiB、 ~$15/month
- Master credentials は random password + AWS Secrets Manager (= `panicboat/monolith/database`)
- Subnet group: eks-production VPC private subnets (= data source 参照)
- Security group: VPC CIDR 内から 5432 access のみ

### application code OTel SDK init (= Component C / L1)

- monolith Gemfile: `opentelemetry-sdk` + `opentelemetry-instrumentation-all` + `opentelemetry-exporter-otlp` 追加
- monolith `config/initializers/opentelemetry.rb`: `OpenTelemetry::SDK.configure`
- frontend package.json: `@opentelemetry/sdk-node` + `@opentelemetry/auto-instrumentations-node` + `@opentelemetry/exporter-trace-otlp-grpc` 追加
- frontend `instrumentation.ts`: Next.js 16+ register hook で `NodeSDK` init

L2 (= OTel Operator auto-injection) が env vars (= `OTEL_EXPORTER_OTLP_ENDPOINT` 等) を Pod に injection、 L1 (= 本 PR 内 application code) がそれらを detect + use する pattern。

### K8s manifests 修正 (= Component B)

- monolith `base/deployment.yaml`: Reloader annotation + OTel ruby auto-injection annotation + envFrom secretRef 追加
- monolith `overlays/develop/configmap.yaml`: `DATABASE_URL` 削除
- monolith `overlays/develop/external-secret.yaml` 新規 (= ESO で `panicboat/monolith/database` から K8s Secret `monolith-database` 生成)
- monolith `overlays/develop/postgresql/` 削除 (= K8s 内 PostgreSQL Pod + Service 廃止、 AWS RDS 切替)
- frontend `base/deployment.yaml`: Reloader annotation + OTel nodejs auto-injection annotation

### Flux Image Update Automation (= Component E)

- monolith / frontend それぞれに `clusters/develop/services/{service}/{image-repository, image-policy, image-automation}.yaml` 3 resources
- digest reflection pattern (= sha tag は random で order 制御困難、 latest tag pin + Flux v1.1.1 `digestReflectionPolicy: Always` で digest auto-track)
- main merge → container-builder GHCR push → 5m polling で digest detect → ImageUpdateAutomation で deployment.yaml を `image:latest@sha256:<digest>` に update + commit + push to main → Flux Reconcile (= 10m) → Pod rolling update

### README documentation update (= 引き継ぎ #23 解消)

- README.md / README-ja.md 同期 update
- nginx.local 削除 (= 既 #590 で削除済 service)、 mermaid に RDS node 追加、 deploy 説明を digest reflection に変更

## Merge synchronization

platform PR と **同日 merge** (= order constraint なし、 両方 main に取り込みで Phase 6-2 完了)。
EOF
)"
```

Expected: monorepo PR url 取得 (= 例: https://github.com/panicboat/monorepo/pull/<n>)

- [ ] **Step 4: monorepo PR url 記録**

monorepo PR url を **platform PR description に記載** するため記録。 例: `https://github.com/panicboat/monorepo/pull/<n>`。

---

## Task 8: Platform — Instrumentation CR + hydrate

**Files:**
- Create: `kubernetes/components/opentelemetry/production/kustomization/` (= 新規 directory)
- Create: `kubernetes/components/opentelemetry/production/kustomization/kustomization.yaml`
- Create: `kubernetes/components/opentelemetry/production/kustomization/instrumentation.yaml`
- Modify: `kubernetes/manifests/production/opentelemetry/manifest.yaml` (= hydrate 自動生成)

**Context:** OTel Operator (= 6-1 deploy 済) の Instrumentation CR を namespace `default` に deploy。 application Pod が `instrumentation.opentelemetry.io/inject-{ruby,nodejs}: "default/panicboat-application"` annotation で auto-injection 受ける。

worktree は **6-2 main worktree** (= `eks-monorepo-application-deploy`) に戻って作業。

- [ ] **Step 1: kustomization directory + files 作成**

`kubernetes/components/opentelemetry/production/kustomization/kustomization.yaml`:

```yaml
# =============================================================================
# OpenTelemetry production kustomization (= Instrumentation CR)
# =============================================================================
# Phase 6-2 で追加。 OTel Operator (= 6-1 deploy 済) の Instrumentation CR
# を namespace default に deploy、 application Pod が auto-injection 受ける。
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - instrumentation.yaml
```

`kubernetes/components/opentelemetry/production/kustomization/instrumentation.yaml`:

```yaml
# =============================================================================
# OpenTelemetry Instrumentation CR (= L2 auto-injection)
# =============================================================================
# Phase 6-2 (= application deploy) で deploy。 namespace default に 1 つ
# deploy で全 application Pod (= monolith / frontend) が
# instrumentation.opentelemetry.io/inject-{ruby,nodejs} annotation で
# auto-injection を受ける。
#
# Operator が Pod の init container で OTel SDK auto-instrumentation library
# を inject、 application container の env vars (= OTEL_EXPORTER_OTLP_ENDPOINT
# 等) を設定。 L1 (= application code 側 OpenTelemetry::SDK.configure /
# NodeSDK) がそれらを detect + use する pattern。
#
# auto-instrumentation image version は 5-1 L1 chart binary verify 適用、
# specific version (= ruby 0.59.0 / nodejs 0.62.0) を pin (= :latest 不採用)。
# =============================================================================
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: panicboat-application
  namespace: default
spec:
  exporter:
    endpoint: http://opentelemetry-collector.monitoring.svc.cluster.local:4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"  # 全 trace 採取 (= 個人 dev、 production 投入時に絞る)
  ruby:
    image: ghcr.io/open-telemetry/opentelemetry-ruby-instrumentation:0.59.0
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.62.0
```

注: ruby / nodejs auto-instrumentation image の specific version は plan 実行段階で latest stable を確認 (= `gh api /repos/open-telemetry/opentelemetry-ruby/releases/latest` 等) + sha256 verify。 上記は spec 想定値、 plan 実行時の actual latest stable に adjust 可能。

- [ ] **Step 2: helmfile.yaml.gotmpl 既存確認 (= kustomization directory 認識)**

```bash
cat kubernetes/components/opentelemetry/production/helmfile.yaml
```

Expected: 既 6-1 deploy の helmfile (= chart pin、 values reference)。 修正不要 (= helmfile が `kustomization/` directory も hydrate するため、 Makefile の `hydrate-component` target が both helmfile + kustomization を出力)。

- [ ] **Step 3: hydrate opentelemetry component**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy/kubernetes
make hydrate-component COMPONENT=opentelemetry ENV=production
```

Expected: `manifests/production/opentelemetry/manifest.yaml` 更新 (= 既 OTel Operator chart hydrate 結果 + kustomization output の Instrumentation CR 追加)

注: Task 1 で merged 済 Makefile fix forward (= `--kube-version v1.32.0`) により hydrate output が clean (= helm template の noise diff なし)。

- [ ] **Step 4: hydrate diff 確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
git diff kubernetes/manifests/production/opentelemetry/manifest.yaml | head -80
```

Expected: Instrumentation CR (= name: panicboat-application, namespace: default, exporter / propagators / sampler / ruby image / nodejs image) 追加分の diff。 既 OTel Operator chart hydrate 結果は変更なし (= Makefile fix で clean baseline)。

- [ ] **Step 5: commit**

```bash
git add kubernetes/components/opentelemetry/production/kustomization/
git add kubernetes/manifests/production/opentelemetry/manifest.yaml
git commit -s -m "feat(eks): Phase 6-2 — OTel Instrumentation CR (= L2)" -m "OTel Operator (= 6-1 deploy 済 chart 0.112.1) の Instrumentation CR を
namespace default に deploy。 application Pod (= monolith / frontend) が
instrumentation.opentelemetry.io/inject-{ruby,nodejs} annotation で
auto-injection 受ける。" -m "Pattern:
- Operator が Pod init container で OTel SDK auto-instrumentation library
  を inject、 application container の env vars (=
  OTEL_EXPORTER_OTLP_ENDPOINT 等) を設定
- L1 (= 並行 monorepo PR の application code) がそれらを detect + use
  する pattern (= L1 + L2 共存)
- exporter: opentelemetry-collector.monitoring.svc.cluster.local:4317
  (= Phase 3 で deploy 済 OTel Collector OTLP receiver)
- propagators: tracecontext + baggage (= W3C standard)
- sampler: parentbased_traceidratio 1.0 (= 全 trace 採取、 production
  投入時に絞る)
- auto-instrumentation image: ruby 0.59.0 / nodejs 0.62.0 specific
  version pin (= 5-1 L1 chart binary verify 適用、 :latest 不採用)" -m "新規 directory: kubernetes/components/opentelemetry/production/kustomization/"
```

---

## Task 9: Platform — monorepo Flux Kustomization resume

**Files:**
- Modify: `kubernetes/clusters/production/repositories/monorepo.yaml`

**Context:** Phase 6-1 で `Kustomization monorepo-cluster` を `spec.suspend: true` で deploy。 6-2 で `suspend: true → false` に変更し、 monorepo の `clusters/develop/services/{monolith,frontend,reverse-proxy}/service.yaml` (= 内蔵 Flux Kustomization) が cascading で reconcile 開始。

- [ ] **Step 1: monorepo.yaml 修正**

`kubernetes/clusters/production/repositories/monorepo.yaml` の `Kustomization` 部分を修正 (= `spec.suspend` 値変更):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: monorepo
  namespace: flux-system
spec:
  interval: 5m
  url: https://github.com/panicboat/monorepo.git
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monorepo-cluster
  namespace: flux-system
spec:
  interval: 5m0s
  path: "./clusters/develop"
  prune: true
  sourceRef:
    kind: GitRepository
    name: monorepo
  suspend: false  # Phase 6-2 で resume (= 6-1 で suspend deploy 済)
```

注: 修正箇所は **1 line** のみ (= `suspend: true` → `suspend: false`)、 ヘッダコメント update 不要 (= 既 comment が 6-1 / 6-2 phase を 言及済)。

- [ ] **Step 2: kustomize build で local validation**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy/kubernetes
kustomize build clusters/production 2>&1 | grep -B 1 "name: monorepo-cluster" -A 8 | head -15
```

Expected: Kustomization monorepo-cluster の `spec.suspend: false`

- [ ] **Step 3: commit**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
git add kubernetes/clusters/production/repositories/monorepo.yaml
git commit -s -m "feat(eks): Phase 6-2 — resume monorepo Kustomization" -m "Phase 6-1 で suspend: true で deploy した monorepo-cluster Kustomization
を suspend: false に変更。 monorepo の clusters/develop/services/
{monolith,frontend,reverse-proxy}/service.yaml (= 内蔵 Flux Kustomization)
が cascading で reconcile 開始、 application services の actual deploy が
trigger される。" -m "並行 monorepo PR (= application code OTel SDK init + K8s manifests +
terragrunt RDS + Flux Image Update Automation + README update) と
**同日 merge** することで application deploy chain 確立。"
```

---

## Task 10: Platform PR 作成 + push + draft PR

**Files:** (PR description preparation)

**Context:** Task 8-9 で作成した platform commits を push + draft PR 作成。 並行 monorepo PR (= Task 7 で作成) と同期 merge。

- [ ] **Step 1: platform commit 状態確認**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform/.claude/worktrees/eks-monorepo-application-deploy
git log --oneline origin/main..HEAD
```

Expected: spec commit + Task 8 + Task 9 = 計 3 commits ahead

```
<hash> feat(eks): Phase 6-2 — resume monorepo Kustomization
<hash> feat(eks): Phase 6-2 — OTel Instrumentation CR (= L2)
bc709c1 docs(eks): Phase 6-2 — monorepo application deploy spec
```

- [ ] **Step 2: push platform branch**

```bash
git push -u origin HEAD
```

Expected: push 成功 (= 既 Task 0 で push 済の場合は incremental push)

- [ ] **Step 3: platform draft PR 作成 (= monorepo PR url を埋め込む)**

monorepo PR url は Task 7 Step 4 で記録した実 number (= 例 `<n>`) を使用:

```bash
gh pr create --draft --title "feat(eks): Phase 6-2 — monorepo application deploy" --body "$(cat <<EOF
## Summary

EKS production cluster (\`eks-production\`) に panicboat monorepo の **monolith + frontend + reverse-proxy** 3 services を actual deploy。 AWS RDS PostgreSQL provision で K8s 内 PostgreSQL から切替、 OTel SDK init (= L1) + Instrumentation CR (= L2) で 3-layer observability foundation 整備、 Flux Image Update Automation (= digest reflection) で main merge → auto-deploy chain 確立。

## Spec

[docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md](https://github.com/panicboat/platform/blob/claude/eks-monorepo-application-deploy/docs/superpowers/specs/2026-05-10-eks-production-monorepo-application-deploy-design.md)

## Plan

[docs/superpowers/plans/2026-05-10-eks-production-monorepo-application-deploy.md](https://github.com/panicboat/platform/blob/claude/eks-monorepo-application-deploy/docs/superpowers/plans/2026-05-10-eks-production-monorepo-application-deploy.md)

## Pre-merge fix forward PR (= 6-2 開始前 merged)

引き継ぎ #22 (= Makefile hydrate-component の \`--kube-version\` flag 固定) を別 PR で先 merge 済。 6-2 PR の hydrate output が clean (= Instrumentation CR 追加分の diff のみ)。

## Changes (= platform 側)

### Component D: Instrumentation CR (= L2 auto-injection)

- \`kubernetes/components/opentelemetry/production/kustomization/instrumentation.yaml\` 新規 (= namespace default に \`panicboat-application\`)
- exporter: \`opentelemetry-collector.monitoring.svc.cluster.local:4317\`
- propagators: tracecontext + baggage
- sampler: parentbased_traceidratio 1.0 (= 全 trace 採取、 production 投入時に絞る)
- auto-instrumentation image: ruby 0.59.0 / nodejs 0.62.0 specific version pin (= 5-1 L1 chart binary verify 適用)

### Component F-1: monorepo Flux Kustomization resume

- \`kubernetes/clusters/production/repositories/monorepo.yaml\` の Kustomization \`monorepo-cluster\` を \`spec.suspend: true → false\`
- monorepo の \`clusters/develop/services/{monolith,frontend,reverse-proxy}/service.yaml\` が cascading で reconcile 開始 → application services actual deploy 開始

## Phase 5 + 6-1 lessons applied

- 5-1 L1 (= chart binary verify): auto-instrumentation image specific version pin (= ruby 0.59.0 / nodejs 0.62.0)
- 5-1 L2 / 5-2 L1 (= post-flight regression check): Component F-2 で 5 連続 validate 機会
- 5-2 L4 (= kustomization-only pattern): Instrumentation CR を既 OTel Operator kustomization directory に追加
- 6-1 L1 (= chart actual structure verify): \`kubectl explain instrumentation.spec\` 等で OTel CRD structure 確認済
- 6-1 L3 (= post-flight issue category 整理): post-flight check で issue category 別記録
- 6-1 L4 (= parallel PR scope に documentation 同期): monorepo PR scope で README update (= 引き継ぎ #23 解消)

## 引き継ぎ事項解消

- **#4** OTel Operator + Instrumentation CR + SDK 完全採用: **完全解消** (= 6-1 で Operator deploy + 6-2 で Instrumentation CR + L1 SDK init in 並行 monorepo PR)
- **#22** Makefile hydrate-component の kube-version 固定: **Pre-merge fix forward PR で解消**
- **#23** monorepo README documentation drift: **並行 monorepo PR scope で解消**
- **#21** Mimir max-label-names-per-series 30 → 35: **post-flight reactive fix forward** (= 検出時)

## Parallel monorepo PR (= 並行 merge)

- [feat: Phase 6-2 application deploy (= RDS + OTel SDK + auto-bump)](https://github.com/panicboat/monorepo/pull/<n>)
- platform PR と **同日 merge** (= order constraint なし、 両方 main に取り込みで Phase 6-2 完了)

## Out of scope

以下は 6-3 で対応:

- DNS / ACM の application domain 公開 (= reverse-proxy 用 domain)
- 3-layer observability validation (= Beyla + Hubble + OTel 同 trace_id 結合)
- Phase 5-2 nginx 13 checklist の application 化
- KEDA ScaledObject (= application 投入後の actual load 様子見)

## Validation checklist (= deploy 後実施)

- [ ] AWS RDS instance Available + Secrets Manager secret 登録
- [ ] monolith Pod Ready + RDS 接続成功
- [ ] frontend Pod Ready + monolith ConnectRPC 接続成功
- [ ] reverse-proxy Pod 継続動作 (= 既 6-1 deploy)
- [ ] Instrumentation CR \`panicboat-application\` exists (= namespace default)
- [ ] application Pod auto-injection (= init container 完了 + OTel env vars injected)
- [ ] ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready (= monolith / frontend)
- [ ] monorepo Flux Kustomization \`monorepo-cluster\` resume + 各 service Kustomization Ready
- [ ] Phase 1-5 + 6-1 既存 component regression なし
- [ ] post-flight 5 連続 validate 確認
- [ ] latent issue 検出時 fix forward PR で resolve (= #21 Mimir reject 等)
- [ ] post-execution learnings doc 作成 (= 別 PR、 plan に section 追加)
EOF
)"
```

注: PR body 内の `<n>` placeholder は実 monorepo PR number に置換。 上記は `<n>` 残るので Step 3 実行時に substitute。

Expected: platform PR url 取得 (= 例 #<n>)

---

## Task 11: Post-execution observation + post-flight regression check

**Files:** (status check + 必要時 fix forward PR)

**Context:** platform PR + monorepo PR + Pre-merge fix forward PR が all merged 後、 cluster 上の actual deploy 動作を観察。 Component F-2 (= post-flight regression check) を実施し、 latent issue 検出時は fix forward PR で resolve。 5-1 L2 / 5-2 L1 pattern 5 連続 validate 機会。

- [ ] **Step 1: 全 PR merge 完了確認**

```bash
gh pr view <platform-pr> --repo panicboat/platform --json state,mergedAt
gh pr view <monorepo-pr> --repo panicboat/monorepo --json state,mergedAt
gh pr list --repo panicboat/platform --state merged --search "Makefile hydrate-component" --json number,mergedAt | head -10
```

Expected: 全 3 PR `state: MERGED, mergedAt: <timestamp>`

- [ ] **Step 2: Flux reconcile + 6-2 component health 確認 (= post-flight Section 3)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
flux reconcile source git flux-system
flux reconcile kustomization flux-system

echo "--- monorepo Flux Kustomization (= resume 確認) ---"
kubectl get kustomization -n flux-system monorepo-cluster -o jsonpath="Suspended={.spec.suspend} Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"

echo "--- monorepo cascading Kustomization (= 各 service) ---"
flux get kustomizations -A 2>&1 | grep -E "monolith|frontend|reverse-proxy"

echo "--- Instrumentation CR ---"
kubectl get instrumentation -n default panicboat-application -o jsonpath="{.metadata.name} created={.metadata.creationTimestamp}{\"\n\"}"

echo "--- AWS RDS instance ---"
aws rds describe-db-instances --db-instance-identifier monolith-develop --query "DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}" --region ap-northeast-1 2>&1 | head -10

echo "--- application Pods ---"
kubectl get pods -n default --no-headers | grep -E "monolith|frontend|reverse-proxy"

echo "--- application Pod auto-injection (= init container 確認) ---"
kubectl get pod -n default -l app=monolith -o jsonpath="{.items[0].spec.initContainers[*].name}{\"\n\"}"
kubectl get pod -n default -l app=frontend -o jsonpath="{.items[0].spec.initContainers[*].name}{\"\n\"}"

echo "--- monolith RDS 接続確認 (= application log の SQL execution) ---"
kubectl logs -n default -l app=monolith --tail=10 2>&1 | grep -iE "postgres|connect|migration" | head -3

echo "--- ImageRepository / ImagePolicy / ImageUpdateAutomation ---"
flux get image repository -A 2>&1 | grep -E "monolith|frontend"
flux get image policy -A 2>&1 | grep -E "monolith|frontend"
flux get image update -A 2>&1 | grep -E "monolith|frontend"'
```

Expected:
- monorepo-cluster Kustomization Suspended=false Ready=True
- monolith / frontend / reverse-proxy Flux Kustomization Ready=True
- Instrumentation CR `panicboat-application` exists
- AWS RDS instance Status=available + Endpoint hostname 取得
- application Pods Running (= monolith + frontend + reverse-proxy)
- application Pod の init containers に `opentelemetry-auto-instrumentation` 含まれる (= L2 auto-injection 動作)
- monolith log で RDS への SQL connection success
- ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready

- [ ] **Step 3: Phase 1-5 + 6-1 既存 component regression 確認 (= post-flight Section 1)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Cilium / Hubble / Monitoring ---"
kubectl get ds -n kube-system cilium --no-headers
kubectl get pods -n kube-system -l k8s-app=hubble-relay --no-headers | head -1
kubectl get pods -n monitoring --no-headers | wc -l

echo "--- 4 OAuth UI ---"
for host in grafana hubble prometheus alertmanager; do
  curl -s -o /dev/null -w "$host.panicboat.net=%{http_code}\n" -L --max-redirs 0 https://$host.panicboat.net/
done

echo "--- 6-1 Cilium 共有 Gateway ---"
kubectl get gateway -n default cilium-gateway -o jsonpath="Accepted={.status.conditions[?(@.type==\"Accepted\")].status}{\"\n\"}"

echo "--- ESO + cert-manager + Reloader + OTel Operator ---"
kubectl get clustersecretstore aws-secrets-manager -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"
kubectl get clusterissuer selfsigned-cluster-issuer -o jsonpath="Ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}"
kubectl get deploy -n reloader reloader-reloader --no-headers
kubectl get deploy -n opentelemetry-operator-system opentelemetry-operator --no-headers'
```

Expected:
- Cilium DaemonSet 6/6 + Hubble Pod Running
- Monitoring stack 28+ Pod Running
- 4 OAuth UI 全 302
- 6-1 共有 Gateway Accepted=True
- ESO / cert-manager / Reloader / OTel Operator 全 Ready / Available

- [ ] **Step 4: 既 deploy 済 application 継続動作 (= post-flight Section 2)**

```bash
echo "--- demo nginx (Phase 5-2) ---"
curl -s -o /dev/null -w "nginx.panicboat.net=%{http_code}\n" https://nginx.panicboat.net/
zsh -ic 'eks-login production >/dev/null 2>&1
kubectl exec -n default deploy/nginx -- printenv DEMO_MESSAGE 2>&1 | head -1'
```

Expected:
- nginx.panicboat.net=200
- DEMO_MESSAGE env value 維持

- [ ] **Step 5: latent issue 検出 (= post-flight Section 4、 5 連続 validate 機会)**

```bash
zsh -ic 'eks-login production >/dev/null 2>&1
echo "--- Mimir distributor reject rate (= 引き継ぎ #21 max-label-names-per-series) ---"
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -- curl -s "http://prometheus.monitoring.svc:9090/api/v1/query?query=rate(cortex_distributor_samples_in_total{}[5m])-rate(cortex_distributor_received_samples_total{}[5m])" 2>/dev/null | head -100 | grep -oE "value\":\\[.{0,30}" | head -3

echo ""
echo "--- Mimir log で max-label-names-per-series error 確認 ---"
kubectl logs -n monitoring -l app.kubernetes.io/name=mimir,app.kubernetes.io/component=distributor --tail=50 2>&1 | grep -iE "max-label-names-per-series|err-mimir-max-series" | head -3

echo ""
echo "--- application Pod restart 数 (= deploy 後 baseline) ---"
kubectl get pods -n default -l app=monolith -o jsonpath="{range .items[*]}{.metadata.name} restarts={.status.containerStatuses[0].restartCount}{\"\n\"}{end}"
kubectl get pods -n default -l app=frontend -o jsonpath="{range .items[*]}{.metadata.name} restarts={.status.containerStatuses[0].restartCount}{\"\n\"}{end}"

echo ""
echo "--- application log で error 確認 (= recent 30 lines) ---"
kubectl logs -n default -l app=monolith --tail=30 2>&1 | grep -iE "error|fatal" | head -5
kubectl logs -n default -l app=frontend --tail=30 2>&1 | grep -iE "error|fatal" | head -5

echo ""
echo "--- OTel Operator Pod log (= auto-injection error 確認) ---"
kubectl logs -n opentelemetry-operator-system -l app.kubernetes.io/name=opentelemetry-operator --tail=30 2>&1 | grep -iE "error|fatal" | head -5

echo ""
echo "--- Flux Kustomization reconcile errors ---"
flux get kustomizations -A 2>&1 | grep -E "False|reconciliation failed" | head -5'
```

Expected:
- Mimir distributor reject rate 0 (= 検出時は #21 fix forward PR)
- Mimir log で `max-label-names-per-series` error 0 (= 検出時は同上)
- application Pod restart 数 0
- application / OTel Operator log の error 0
- Flux Kustomization reconcile failure 0 (= 既 monorepo-cluster は resume 後の Ready 想定)

検出時は fix forward PR で resolve (= 5-1 L2 / 5-2 L1 pattern)。 #21 Mimir reject の場合は `kubernetes/components/mimir/production/values.yaml.gotmpl` の `validation.max-label-names-per-series: 35` 設定追加 + hydrate + 別 PR。

- [ ] **Step 6: ready PR 移行 (= 既 PR merged 済の場合は skip)**

本 task は post-execution observation で **PR は既 Step 1 で merged 確認済**、 PR ready 化操作は不要。 latent issue 検出時の fix forward PR の draft → ready は別途 (= reactive)。

- [ ] **Step 7: 6-2 完了 + post-execution learnings doc 作成 (= 別 PR、 別 worktree)**

merge 完了 + post-flight check pass 後、 post-execution learnings doc を別 PR で作成 (= Phase 5-1 / 5-2 / 6-1 同 pattern):

```
docs/superpowers/plans/2026-05-10-eks-production-monorepo-application-deploy.md
```

の末尾に "## Post-execution learnings" section 追加、 別 PR (= "docs(eks): Phase 6-2 — post-execution learnings") で merge。

learnings 候補:
- **AWS RDS provision の monorepo terragrunt pattern** establishment 結果
- **OTel SDK L1 + L2 共存 pattern** の actual 動作 (= env vars 受渡し / 重複処理 / 順序)
- **Flux digest reflection pattern** の actual auto-deploy chain 観察
- **post-flight 5 連続 validate** 結果 (= 4-3 / 5-1 / 5-2 / 6-1 / 6-2 pattern 完全機能 confirmation)
- 検出 latent issue (= #21 Mimir reject 等の category 別整理)

---

## 完了条件 (= spec Section 8 Validation checklist 再掲)

### Platform PR + 並行 monorepo PR (= 同日 merge)
- [ ] AWS RDS instance Available + Secrets Manager secret 登録
- [ ] monolith Pod Ready + RDS 接続成功 (= application log で SQL execution 確認)
- [ ] frontend Pod Ready + monolith ConnectRPC 接続成功
- [ ] reverse-proxy Pod 継続動作 (= 既 6-1 deploy)
- [ ] OTel Instrumentation CR `panicboat-application` exists (= namespace default)
- [ ] application Pod auto-injection (= init container 完了 + OTel env vars injected)
- [ ] ImageRepository / ImagePolicy / ImageUpdateAutomation 全 Ready (= monolith / frontend)
- [ ] monorepo Flux Kustomization `monorepo-cluster` resume + 各 service Kustomization Ready
- [ ] Phase 1-5 + 6-1 既存 component regression なし
- [ ] post-flight 5 連続 validate 確認 (= 5-1 L2 / 5-2 L1 pattern)
- [ ] latent issue 検出時 fix forward PR で resolve (= #21 Mimir reject / その他)
- [ ] post-execution learnings doc 作成 (= 別 PR、 plan に section 追加)

---

## Post-execution learnings (= Phase 6-2 完了後、 別 PR で記録)

### 完了 summary

| 項目 | 内容 |
|---|---|
| platform PR (= main) | [#343](https://github.com/panicboat/platform/pull/343) (= spec / plan / Instrumentation CR / Kustomization resume) |
| 並行 monorepo PR (= main) | [#600](https://github.com/panicboat/monorepo/pull/600) (= terragrunt RDS + application code OTel SDK + K8s manifests + Flux Image Update Automation + README) |
| Fix forward PR (= platform) | [#344](https://github.com/panicboat/platform/pull/344) (= Instrumentation CR `spec.ruby` block 削除) |
| Fix forward PR (= monorepo) | [#601](https://github.com/panicboat/monorepo/pull/601) (= monolith OTel env hardcode + terragrunt secret_version 削除) + [#602](https://github.com/panicboat/monorepo/pull/602) (= ImagePolicy `interval` 追加) |
| user manual operation | `terragrunt state rm aws_secretsmanager_secret_version.monolith_database` |
| Phase 1-5 + 6-1 既 deploy 済 zero regression | achieved |
| post-flight 6 連続 validate (= 5-1 L2 / 5-2 L1 pattern) | achieved |

### 累計 fix forward PR (= Phase 4-6 で 9 件)

| PR # | repo | 起因 | Resolution |
|---|---|---|---|
| #305 | platform | 4b regression | observability DaemonSets PriorityClass |
| #311 | platform | 4-3 設計起因 | oauth2-proxy 4 instances per backend |
| #312 | platform | 3 Sub-project 2 latent | Mimir RF=1 for single-replica |
| #314 | platform | 3 Sub-project 2 latent | Mimir cardinality limit |
| #316 | platform | 4-1 latent | Cilium Hubble CA-based ClusterIssuer |
| #327 | platform | 6-1 chart default 起因 | OTel Operator metrics auth disable |
| **#344** | platform | 6-2 chart schema 起因 | Instrumentation CR `spec.ruby` 削除 |
| **#601 (3rd commit) / #602** | monorepo | 6-2 設計起因 | monolith OTel env + secret_version + ImagePolicy interval |

= **9 件中 4 件 past sub-project latent**、 **5 件 現 sub-project 設計起因** (= chart default / schema / Flux validation rule 等)。

---

### L1 (= 6-2 L1): chart actual structure を helmfile + values / Instrumentation CR 設計時に systematic verify (= 6-1 L1 extension)

**Title**: chart upstream の CRD schema / values structure を **plan 段階で `helm show values` / `kubectl explain CRD`** で verify

**Context**: 6-2 spec / plan で OTel Operator chart 0.112.1 の Instrumentation CR は `spec.ruby` で Ruby auto-injection 可能と前提。 actual chart 0.112.1 の CRD schema には `ruby` field 不在 (= upstream 0.155.0+ で追加された可能性)、 deploy 時 schema validation error で flux-system Kustomization 全体 reconcile failure、 6-2 application stack 全 deploy block。

**Lesson**:

- chart の概念名 (= "Ruby auto-injection") が **chart version 依存**、 plan 記述前に `kubectl explain instrumentation.spec --recursive` で actual schema 確認必須
- 6-1 L1 (= `helm show values` で chart values structure 確認) の延長: **CRD schema** も verify 対象

**Apply going forward**:

- application chart / CRD 利用時に **`kubectl explain` + `helm show values`** を systematic step として subagent dispatch instruction に含める
- chart version pin (= 5-1 L1 binary verify) と schema verify (= 6-1 L1 + 6-2 L1) の 2 段階確認

---

### L2 (= 6-2 L2): multi-actor tool version 統一の重要性 (= 引き継ぎ #24 root cause)

**Title**: panicboat 全 repo (= monorepo + platform) で tool version 管理の single source of truth 確立、 multi-actor (= local human / subagent / CI runner) で deterministic な tool 利用

**Context**: 6-2 で OpenTofu version mismatch が deploy chain で複数顕在化:

- monorepo CI runner = mise install (= OpenTofu 1.11.6 + terragrunt 1.0.2、 `.tool-versions` 不在で mise-action input 経由)
- platform CI = aqua install (= helm 3.17.3 + helmfile 0.169.2 + kustomize 5.6.0、 `.github/aqua.yaml` で pin)
- local human / subagent = tfenv / mise / aqua / local default 混在 (= deterministic でない)

monorepo PR #600 で template terraform.tf `required_version = "1.15.1"` (= Hashicorp Terraform pin) が CI OpenTofu 1.11.6 と不整合、 CI fail → fix forward `">= 1.11.0"` で resolve。

**Lesson**:

- tool version 管理は **single source of truth** で multi-actor 整合必須
- panicboat monorepo は mise (= CI で使用)、 platform は aqua、 2 manager 並立 = 統一推奨

**Apply going forward**:

- 引き継ぎ #24 (= panicboat 全 repo tool version 管理統一) で systematic 対応、 別 phase
- 全 actor (= local / subagent / CI) で同 manager (= 例 aqua) 経由 install + version pin

---

### L3 (= 6-2 L3): terragrunt state refresh と plan role design philosophy の整合

**Title**: `aws_secretsmanager_secret_version` の state refresh で `GetSecretValue` 必要、 panicboat plan role (= read-only) 思想と conflict。 secret value を IaC scope 外で manage する pattern 確立

**Context**: 6-2 で `aws_secretsmanager_secret_version.monolith_database` を terragrunt provision (= IaC で secret value 管理)。 panicboat の plan role は read-only 思想で `secretsmanager:GetSecretValue` 権限を意図的に除外 (= secret value 漏洩防止)。 state refresh で plan fail。

`lifecycle.ignore_changes` は **diff 計算 skip するが state refresh skip しない** = ineffective。 真の解決: secret_version resource を terragrunt scope から除外、 secret value は IaC 外で manage (= AWS Console / CLI / Lambda)、 ESO は引き続き secret value を read。

**Lesson**:

- terragrunt の `lifecycle.ignore_changes` は state refresh phase に影響しない
- secret value provision を IaC scope に含めると plan role design (= read-only) と conflict
- 解決 pattern: **secret container (= `aws_secretsmanager_secret`) のみ terragrunt manage、 secret value は IaC 外**

**Apply going forward**:

- panicboat の secret management 設計 standard として記録 (= 引き継ぎ #12 = AWS Secrets Manager Automatic Rotation の design と整合、 rotation も IaC 外)
- future application で secret value provision するなら、 ESO + AWS Secrets Manager + IaC 外 manual / Lambda の pattern を踏襲

---

### L4 (= 6-2 L4): Flux ImagePolicy `digestReflectionPolicy: Always` で `interval` required (= controller validation rule)

**Title**: image-reflector-controller v1.1.x で `digestReflectionPolicy: Always` 利用時に `spec.interval` 必須化 (= CEL validation rule)、 chart / controller version-specific validation rule の事前確認

**Context**: 6-2 で monolith / frontend に新規追加した ImagePolicy で `digestReflectionPolicy: Always` 設定、 `spec.interval` 省略。 image-reflector-controller v1.1.x の CEL validation で reject、 monorepo-cluster Kustomization 全体 dry-run fail → application stack deploy block。 既 nginx pattern (= 既削除済、 6-1 で nginx 削除) には interval 設定済、 6-2 新規追加で漏れ。

**Lesson**:

- Flux controller version-specific validation rule (= CEL) の chart / CRD level 確認必須
- 既存 reference pattern (= 既 nginx) があっても、 controller version upgrade で validation 強化される可能性

**Apply going forward**:

- chart / Flux CRD 利用時に **`kubectl get crd <name> -o yaml` で CEL rule + required fields 確認**
- 6-2 L1 / 6-1 L1 と同 systematic step (= `helm show values` + `kubectl explain` + `kubectl get crd`)

---

### L5 (= 6-2 L5): 5-1 L2 / 5-2 L1 pattern 6 連続 validate established

**Title**: post-flight regression check pattern の 6 連続 validate (= 4-3 / 5-1 / 5-2 / 6-1 / 6-2 + 本 fix forward chain)、 issue category 分布の確認

**Context**: Phase 4-6 累計 9 件 fix forward PR の category 分布:

- **past sub-project latent issue 表面化** (= 4 件): #305 / #312 / #314 / #316 (= 3 / 4-1 / 4b 設計の latent issue が 4-3 / 5-1 / 5-2 で表面化)
- **現 sub-project 設計起因** (= 5 件): #311 / #327 / #344 / #601 commits / #602 (= 4-3 / 6-1 / 6-2 の chart default / schema / Flux validation 起因)

**Lesson**:

- post-flight regression check は **両 category** で機能、 deploy 後の latent issue を確実に検出
- 6 連続 validate で pattern **完全機能** confirmation
- category 比率は **時期に依存** (= 早期 phase は past latent 比率高、 後期 phase は現設計起因比率上昇)

**Apply going forward**:

- 6-3 以降の sub-project でも post-flight check pattern 継続、 latent issue category 別 record
- 引き継ぎ事項 update を learnings doc に systematic 記録

---

### 引き継ぎ事項 final list (= Phase 6-2 完了時点 28 項目)

Phase 1-6 累計引き継ぎ事項を **8 categories** に整理 (= Phase 5 closure doc 6 categories + 6-1 で +2 + 6-2 で +5):

#### Category G (= 6-2 で追加): Multi-repo Tooling + Documentation

| # | 項目 | Status |
|---|---|---|
| #24 | panicboat 全 repo で tool version 管理の仕組みを統一 (= mise / aqua / 他 single source of truth) | Phase 6+ で別 PR / 別 phase 対応 |
| #25 | OTel Operator chart upgrade for Ruby auto-injection support (= chart 0.155.0+ で `spec.ruby` field 取得、 monolith env hardcode 撤去 + `inject-ruby` annotation 復活) | chart upgrade timing で対応 |
| #26 | 既 commit comments の "when" / "future" 記述 cleanup (= CLAUDE.md Documentation rule 遵守) | systematic 別 PR で対応 |

#### Category H (= 6-2 で追加): Application stack issues

| # | 項目 | Status |
|---|---|---|
| #27 | ImageUpdateAutomation commitTemplate `.Updated` field deprecation (= Flux 新版で `.Changed` migrate) | 別 fix forward PR (= scope 小) |
| #28 | monolith Hanami migration failure investigation (= Sequel migrator fallback で起動継続、 DB schema 未 initialize 可能性) | 6-3 application traffic validation で再現確認 + fix forward |

#### Category B 継続 (= 5 closure doc から)

- #21 Mimir max-label-names-per-series 30 → 35 (= application 投入で増えず、 nginx 由来のみ、 6-3 traffic 投入で再 observation 推奨)

#### 他 categories (= Phase 5 closure doc + 6-1 learnings reference)

Phase 5 closure doc Section 4 + Phase 6-1 learnings に既記録、 詳細省略。

---

### Phase 6-3 + 後続 phase への handoff

- **Phase 6-3** (= application traffic validation + DNS / ACM domain 公開 + 3-layer observability validation): 6-2 で deploy 完了の application stack を utilize、 actual traffic + observability chain (= Beyla + Hubble + OTel) 確認
- **別 fix forward PR**: #27 ImageUpdateAutomation `.Updated` → `.Changed` migration
- **別 phase**: #24 tool version 統一、 #25 OTel chart upgrade、 #26 comments cleanup、 #28 migration investigation

panicboat 個人運用 cluster の Phase 1-6 maturity:

- foundation (= Phase 1-4) + observability (= Phase 3-4) + secrets / auth (= Phase 4) + monitoring stack (= Phase 3-4) + demo validation (= Phase 5) + monorepo migration foundation (= Phase 6-1) + application deploy (= Phase 6-2) = **production-grade cluster on individual scale** 達成。
