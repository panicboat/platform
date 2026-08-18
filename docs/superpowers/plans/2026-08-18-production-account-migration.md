# Production AWS Account Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `production` 環境を AWS Organizations 管理アカウント `559744160976` から専用メンバーアカウントへ分離し、Route53 hosted zone は管理アカウントに残したままクロスアカウント参照で運用する。

**Architecture:** 管理アカウントに残る横断資産を `master` env として新設し、`aws/route53` をそこへ re-home する。production アカウントからは `route53-zone-access` ロールを assume して zone を操作する。Terraform 側は `aws/alb` の provider alias 1 箇所、実行時は external-dns の `--aws-assume-role` で経路を張る。EKS 再構築自体は既存の `docs/runbooks/eks-production-recreate.md` を再利用する。

**Tech Stack:** Terragrunt v1.0.2 + OpenTofu 1.12.0（module 側 `required_version = "1.12.5"`）、AWS provider 6.60.0、Helmfile v1.4、external-dns chart 1.21.1（appVersion 0.21.0）、AWS CLI v2、Flux CD。

**Spec:** `docs/superpowers/specs/2026-08-18-production-account-migration-design.md`

## Global Constraints

- 管理アカウント ID: `559744160976`（Organization `o-es9qoj85gw`、Identity Center `ssoins-7758e2d4fb37f3a7`）
- production hosted zone: `panicboat.net` = `Z07598371GKBU0WMF89MD`、`dystopia.city` = `Z03420722KS9MTSCUSIQZ`
- クロスアカウントロール名: `route53-zone-access`（管理アカウント側、`arn:aws:iam::559744160976:role/route53-zone-access`）
- `<PROD_ACCOUNT_ID>` は Task 1.1 で確定する新アカウント ID。以降のタスクではこの実値に置換すること
- production region は `ap-northeast-1`、`master` env も `ap-northeast-1`、`develop` env は `us-east-1`
- Terragrunt の state バケット名は全 `root.hcl` で `terragrunt-state-${get_aws_account_id()}` として動的に組まれる。バケット名をコードに書かない
- コミットは `-s`（`--signoff`）付き。`Co-Authored-By` は付けない
- 新規ブランチの初回 push は `git push -u origin HEAD`。PR は `gh pr create --draft`

---

## File Structure

### 新規作成

- `aws/github-oidc-auth/envs/master/env.hcl` — `master` env の GitHub OIDC 設定
- `aws/github-oidc-auth/envs/master/terragrunt.hcl` — 同スタック定義
- `aws/route53/envs/master/env.hcl` — re-home 先の env 設定 + `production_account_id`
- `aws/route53/envs/master/terragrunt.hcl` — 同スタック定義
- `aws/route53/modules/zone_access.tf` — `route53-zone-access` ロールとポリシー

### 削除

- `aws/route53/envs/production/` — `master` へ re-home するため

### 変更

- `workflow-config.yaml` — `master` env 追加 + `production` の IAM ロール ARN 差し替え
- `aws/route53/modules/variables.tf` — `production_account_id` 追加
- `aws/github-oidc-auth/modules/variables.tf` — `assume_role_arns` 追加
- `aws/github-oidc-auth/modules/main.tf` — plan ロールへ `sts:AssumeRole` インラインポリシー
- `aws/github-oidc-auth/envs/production/env.hcl` — OIDC provider 自前作成へ反転 + `assume_role_arns`
- `aws/github-oidc-auth/envs/production/terragrunt.hcl` — `assume_role_arns` の受け渡し
- `aws/alb/modules/terraform.tf` — `aws.route53` alias provider
- `aws/alb/modules/lookups.tf` — `providers = { aws = aws.route53 }`
- `aws/alb/modules/main.tf` — validation レコード 2 resource に `provider = aws.route53`
- `aws/alb/modules/variables.tf` / `aws/alb/envs/production/env.hcl` / `aws/alb/envs/production/terragrunt.hcl` — `route53_zone_role_arn`
- `aws/eks/modules/lookups.tf` — `module "route53"` 削除
- `aws/eks/modules/addons.tf` — external-dns IAM を assume role 方式へ
- `kubernetes/helmfile.yaml.gotmpl` — アカウント ID 5 箇所
- `kubernetes/components/{aws-load-balancer-controller,external-dns,loki,mimir,tempo}/production/helmfile.yaml` — アカウント ID
- `kubernetes/components/external-dns/production/values.yaml.gotmpl` — `extraArgs`
- `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` — `STACKS` に `eks-holmesgpt`
- `README.md` / `README-ja.md` — 環境表に `master`

---

# Phase 0: 旧アカウントの事前整理

新アカウントを作る前に、管理アカウント側のドリフトと孤児リソースを解消する。ここでの作業は全て現行アカウント `559744160976` で完結する。

### Task 0.1: `eks-holmesgpt` を teardown 対象に追加して destroy

`scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS` 配列は 8 スタックだが `eks-holmesgpt` が抜けている（#795 でスタック分離した際の追加漏れ）。そのため `eks-production-holmesgpt` ロールが teardown 後も残存し、state 内の `data.aws_eks_cluster.this` が存在しないクラスタ `eks-production` を参照している。

**Files:**
- Modify: `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`

**Interfaces:**
- Produces: `platform/eks-holmesgpt/production` state が resources=0 になる。Task 9.1 の後片付け対象から外れる

- [ ] **Step 1: 現状のドリフトを確認**

```bash
cd aws/eks-holmesgpt/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: `data.aws_eks_cluster.this` の解決に失敗する（`No cluster found for name: eks-production`）

- [ ] **Step 2: `STACKS` 配列に `eks-holmesgpt` を追加**

`scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS=(` ブロックを以下に置き換える。`eks-holmesgpt` は EKS クラスタの Pod Identity Association を持つため `eks` より前、他の eks-* スタックと同列に置く。

```bash
STACKS=(
  "eks-karpenter"
  "eks-holmesgpt"
  "eks-secrets"
  "eks-logs"
  "eks-metrics"
  "eks-traces"
  "eks"
  "alb"
  "vpc"
)
```

- [ ] **Step 3: ヘッダコメントの順序記述を更新**

同ファイル冒頭の以下のコメントを書き換える。

```bash
# 30-destroy-stacks.sh - Destroy 9 EKS-related stacks in fixed order.
#
# Order:
#   eks-karpenter -> eks-holmesgpt -> eks-secrets -> eks-logs -> eks-metrics
#   -> eks-traces -> eks -> alb -> vpc
```

同ファイル末尾の `ok "All 8 stacks destroyed"` と、`confirm "About to DESTROY 8 stacks for ENV=${ENV}. Continue?"` の `8` を `9` に変更する。

- [ ] **Step 4: state 内の存在しないリソースを state から外す**

クラスタが既に無いため Pod Identity Association は AWS 上に存在しない。destroy 前に state から除去する。

```bash
cd aws/eks-holmesgpt/envs/production
TG_TF_PATH=tofu terragrunt state rm aws_eks_pod_identity_association.this
```

Expected: `Successfully removed 1 resource instance(s).`

- [ ] **Step 5: 残りを destroy**

```bash
cd aws/eks-holmesgpt/envs/production && TG_TF_PATH=tofu terragrunt destroy -auto-approve
```

Expected: `aws_iam_role.pod_identity` と `aws_iam_role_policy.bedrock_invoke` が destroy される

- [ ] **Step 6: ロールが消えたことを確認**

```bash
aws iam get-role --role-name eks-production-holmesgpt
```

Expected: `NoSuchEntity` エラー

- [ ] **Step 7: コミット**

```bash
git add scripts/eks-lifecycle/lib/30-destroy-stacks.sh
git commit -s -m "fix(scripts/eks-lifecycle): include eks-holmesgpt in destroy order"
```

### Task 0.2: 孤児リソースの削除

Karpenter が生成した Terraform 管理外の IAM instance profile と、対応する state を持たないログ グループを削除する。

**Files:** なし（AWS API 操作のみ）

- [ ] **Step 1: 孤児 instance profile を確認**

```bash
aws iam list-instance-profiles \
  --query 'InstanceProfiles[].{Name:InstanceProfileName,Roles:Roles[].RoleName}' --output json
```

Expected: `eks-production_513473553642647435` が `Roles: []` で 1 件返る

- [ ] **Step 2: instance profile を削除**

```bash
aws iam delete-instance-profile --instance-profile-name eks-production_513473553642647435
```

- [ ] **Step 3: レガシーログ グループを削除**

state に対応の無い 3 本を削除する。`/github-repository/{ansible,deploy-actions,dotfiles,monorepo,panicboat-actions,platform}` は `platform/repository/develop` state が管理しているため残す。

```bash
aws logs delete-log-group --region ap-northeast-1 --log-group-name /github-repository/generated-manifests
aws logs delete-log-group --region ap-northeast-1 --log-group-name /github-repository/kubernetes-clusters
aws logs delete-log-group --region us-east-1   --log-group-name /github-actions/claude-code-action-monorepo
```

- [ ] **Step 4: 削除を確認**

```bash
aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text
aws logs describe-log-groups --region ap-northeast-1 --query 'logGroups[].logGroupName' --output text
aws logs describe-log-groups --region us-east-1 --query 'logGroups[].logGroupName' --output text
```

Expected: instance profile が空、`ap-northeast-1` のログ グループが 8 本（`/github-actions/github-oidc-auth-{develop,production}` + `/github-repository/*` 6 本）、`us-east-1` が空

### Task 0.3: `dystopia.city` の stale DNS レコード削除

削除済み ALB を指す ALIAS 4 件と external-dns 所有権 TXT 2 件が残っている。Phase 7 で external-dns がレコードを「作成」できることをもって疎通確認したいので、先に消しておく。

**Files:** なし（Route53 API 操作のみ）

- [ ] **Step 1: 対象レコードを確認**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query "ResourceRecordSets[?Type=='A'||Type=='AAAA'||(Type=='TXT'&&contains(Name,'auth'))]" --output json
```

Expected: 6 件（`dystopia.city.` A/AAAA、`auth.dystopia.city.` A/AAAA、`aaaa-auth.dystopia.city.` TXT、`cname-auth.dystopia.city.` TXT）。ALIAS の向き先が `k8s-application-92fded7941-*` であること

- [ ] **Step 2: 削除用 change batch を生成**

Step 1 の出力をそのまま `DELETE` に変換する。値を手で書き写すと ALIAS の `HostedZoneId` を取り違えるため、必ず API 出力から生成する。

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query "ResourceRecordSets[?Type=='A'||Type=='AAAA'||(Type=='TXT'&&contains(Name,'auth'))]" \
  --output json \
  | jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' \
  > /tmp/dystopia-stale-delete.json

cat /tmp/dystopia-stale-delete.json
```

Expected: `Changes` が 6 要素

- [ ] **Step 3: 削除を実行**

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --change-batch file:///tmp/dystopia-stale-delete.json
```

- [ ] **Step 4: zone に SOA / NS / MX / TXT だけが残ったことを確認**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query 'ResourceRecordSets[].{N:Name,T:Type}' --output text
```

Expected: 5 件（`dystopia.city.` の SOA / NS / MX / TXT、`google._domainkey.dystopia.city.` TXT）。A / AAAA が残っていないこと

### Task 0.4: Secrets Manager の値を退避

8 件の secret 値は Terraform 管理外（手動投入）で、旧アカウントを片付けると復旧できない。Phase 6 で新アカウントへ投入するため退避する。

**Files:** なし

- [ ] **Step 1: 全 secret 名を列挙**

```bash
aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text | tr '\t' '\n'
```

Expected: 8 件（`panicboat/oauth2-proxy/google`, `panicboat/grafana/admin`, `panicboat/github-app/panicboat`, `panicboat/keycloak/admin`, `panicboat/holmes/slack`, `panicboat/holmes/alertmanager`, `panicboat/holmes/github`, `panicboat/alertmanager/slack-notify`）

- [ ] **Step 2: 値を退避**

出力には認証情報が含まれるため、リポジトリ外かつパーミッション 0600 のファイルに書く。

```bash
UMASK_OLD=$(umask); umask 077
OUT="$HOME/.secrets-backup-559744160976.json"
: > "$OUT"
for name in $(aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text); do
  aws secretsmanager get-secret-value --region ap-northeast-1 --secret-id "$name" \
    --query '{name: Name, value: SecretString}' --output json >> "$OUT"
done
umask "$UMASK_OLD"
ls -l "$OUT"
```

Expected: 8 個の JSON オブジェクトが書かれ、パーミッションが `-rw-------`

- [ ] **Step 3: 退避内容の件数を確認**

```bash
grep -c '"name"' "$HOME/.secrets-backup-559744160976.json"
```

Expected: `8`

---

# Phase 1: 新アカウント作成

手動 AWS 操作のみ。コード変更もコミットも無い。

### Task 1.1: メンバーアカウント作成と Identity Center 割当

**Files:** なし

**Interfaces:**
- Produces: `<PROD_ACCOUNT_ID>`。以降の全タスクがこの値に依存する

- [ ] **Step 1: 既存アカウント一覧を確認**

```bash
aws organizations list-accounts --query 'Accounts[].{Id:Id,Name:Name,Email:Email,State:State}' --output table
```

Expected: `583677814390`（CLOSED）、`504150922582`（CLOSED）、`559744160976`（ACTIVE）

- [ ] **Step 2: 新しいルートメールアドレスを決める**

クローズ済みアカウントが `admin@panicboat.net` と `aws@dystopia.city` を保持しているため、これらは使えない。未使用のアドレスを 1 つ用意する（例: `panicboat+aws-production@gmail.com`）。

- [ ] **Step 3: アカウントを作成**

```bash
aws organizations create-account \
  --email '<NEW_ROOT_EMAIL>' \
  --account-name 'production' \
  --iam-user-access-to-billing DENY
```

Expected: `CreateAccountStatus.State` が `IN_PROGRESS`。`EMAIL_ALREADY_EXISTS` で失敗した場合は Step 2 に戻ってアドレスを変える

- [ ] **Step 4: 作成完了とアカウント ID を確認**

```bash
aws organizations list-create-account-status --states SUCCEEDED \
  --query 'CreateAccountStatuses[?AccountName==`production`].{Id:AccountId,At:CompletedTimestamp}' --output table
```

Expected: `SUCCEEDED` になり `AccountId` が返る。この値を `<PROD_ACCOUNT_ID>` として記録する

- [ ] **Step 5: `OrganizationAccountAccessRole` で assume できることを確認**

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<PROD_ACCOUNT_ID>:role/OrganizationAccountAccessRole \
  --role-session-name bootstrap-check \
  --query 'AssumedRoleUser.Arn' --output text
```

Expected: `arn:aws:sts::<PROD_ACCOUNT_ID>:assumed-role/OrganizationAccountAccessRole/bootstrap-check`

- [ ] **Step 6: Identity Center の AdministratorAccess を新アカウントに割当**

```bash
aws sso-admin create-account-assignment \
  --instance-arn arn:aws:sso:::instance/ssoins-7758e2d4fb37f3a7 \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-7758e2d4fb37f3a7/ps-77583734ef962d6b \
  --principal-type USER \
  --principal-id e7146ab8-20b1-70eb-a63d-b9887df5d7a6 \
  --target-id <PROD_ACCOUNT_ID> \
  --target-type AWS_ACCOUNT \
  --region ap-northeast-1
```

- [ ] **Step 7: 割当を確認**

```bash
aws sso-admin list-account-assignments \
  --instance-arn arn:aws:sso:::instance/ssoins-7758e2d4fb37f3a7 \
  --account-id <PROD_ACCOUNT_ID> \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-7758e2d4fb37f3a7/ps-77583734ef962d6b \
  --region ap-northeast-1
```

Expected: `AccountAssignments` に 1 件

### Task 1.2: Service Quota 増枠申請と Bedrock 有効化

増枠の承認待ちが本移行で最長のクリティカルパスになるため、アカウント作成直後に投げる。

**Files:** なし

- [ ] **Step 1: 新アカウントの現在値を確認**

`OrganizationAccountAccessRole` を assume した状態で実行する。

```bash
for qc in L-1216C47A L-34B43A08; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code $qc \
    --region ap-northeast-1 --query 'Quota.{Name:QuotaName,Value:Value}' --output json
done
```

Expected: On-Demand Standard vCPU / Standard Spot がいずれも `5.0`（AWS デフォルト）

- [ ] **Step 2: 増枠を申請**

管理アカウントの適用値（On-Demand 64 / Spot 256）に合わせる。

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A --desired-value 64 --region ap-northeast-1
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-34B43A08 --desired-value 256 --region ap-northeast-1
```

- [ ] **Step 3: 申請が受理されたことを確認**

```bash
aws service-quotas list-requested-service-quota-change-history --region ap-northeast-1 \
  --query 'RequestedQuotas[].{Q:QuotaName,V:DesiredValue,S:Status}' --output table
```

Expected: 2 件が `PENDING` または `CASE_OPENED`

- [ ] **Step 4: Bedrock のモデルアクセスを有効化**

`us-east-1` の Bedrock コンソールで、HolmesGPT が使う Anthropic Claude モデル（`anthropic.claude-sonnet-4-6` / `anthropic.claude-opus-4-6`）へのアクセスをリクエストする。CLI では完結しないためコンソール操作。

- [ ] **Step 5: モデルが見えることを確認**

```bash
aws bedrock list-foundation-models --region us-east-1 \
  --query 'modelSummaries[?contains(modelId, `claude-sonnet-4-6`)].modelId' --output text
```

Expected: `anthropic.claude-sonnet-4-6` が返る

---

# Phase 2: State Backend Bootstrap

### Task 2.1: 新アカウントに state バケットとロックテーブルを作る

全 `root.hcl` が `bucket = "terragrunt-state-${get_aws_account_id()}"` で組むため、コード変更は不要。新アカウントの認証情報で bootstrap するだけでよい。

**Files:** なし

**Interfaces:**
- Consumes: Task 1.1 の `<PROD_ACCOUNT_ID>`
- Produces: `terragrunt-state-<PROD_ACCOUNT_ID>` バケットと `terragrunt-state-locks` テーブル。Phase 3 以降の全 terragrunt 実行の前提

- [ ] **Step 1: 新アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::<PROD_ACCOUNT_ID>:role/OrganizationAccountAccessRole \
  --role-session-name terragrunt-bootstrap --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `<PROD_ACCOUNT_ID>` が返る

- [ ] **Step 2: backend を bootstrap**

任意の production スタックのディレクトリから実行すればよい。`vpc` は依存が無く最も軽い。

```bash
cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt backend bootstrap
```

Expected: S3 バケットと DynamoDB テーブルが作成される旨のログ

- [ ] **Step 3: バケットとテーブルを確認**

```bash
aws s3api head-bucket --bucket terragrunt-state-<PROD_ACCOUNT_ID>
aws s3api get-bucket-versioning --bucket terragrunt-state-<PROD_ACCOUNT_ID>
aws dynamodb describe-table --table-name terragrunt-state-locks --region ap-northeast-1 \
  --query 'Table.{Keys:KeySchema,Billing:BillingModeSummary.BillingMode}' --output json
```

Expected: バケットが存在し versioning が `Enabled`、テーブルの HASH キーが `LockID`

---

# Phase 3: `master` Env 新設

管理アカウントに残る横断資産の受け皿を作り、`aws/route53` を移し、クロスアカウントロールを立てる。ここからは管理アカウントの認証情報（`panicboat` IAM ユーザー）で作業する。

### Task 3.1: `master` env の GitHub OIDC ロールを作る

**Files:**
- Create: `aws/github-oidc-auth/envs/master/env.hcl`
- Create: `aws/github-oidc-auth/envs/master/terragrunt.hcl`

**Interfaces:**
- Produces: `github-oidc-auth-master-github-actions-{plan,apply}-role`。Task 3.2 の `workflow-config.yaml` が参照する

- [ ] **Step 1: `env.hcl` を作成**

OIDC provider は `develop` env が管理する既存のものを再利用するため `create_oidc_provider = false`。

```hcl
# env.hcl - Master environment configuration
#
# master = 管理アカウント (= 559744160976) に残る横断資産の env。
# production を別アカウントへ分離したあとも Route53 hosted zone のように
# アカウントを跨いで共有するリソースはここに置く。
locals {
  # Environment metadata
  environment = "master"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org   = "panicboat"
  github_repos = ["monorepo", "platform"]

  github_environments = [
    "master"
  ]

  additional_iam_policies = []

  # OIDC provider は develop env が管理する既存 provider を再利用する
  # (= 同一アカウント内で provider は 1 つしか作れない)。
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"

  # Session duration (4 hours, production と同水準)
  max_session_duration = 14400

  additional_tags = {
    Component = "github-oidc-auth"
    Owner     = "panicboat"
  }
}
```

- [ ] **Step 2: `terragrunt.hcl` を作成**

```hcl
# terragrunt.hcl - Master environment Terragrunt configuration

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

# Environment-specific inputs
inputs = {
  # Core configuration from env.hcl
  aws_region              = include.env.locals.aws_region
  github_org              = include.env.locals.github_org
  github_repos            = include.env.locals.github_repos
  github_environments     = include.env.locals.github_environments
  additional_iam_policies = include.env.locals.additional_iam_policies
  create_oidc_provider    = include.env.locals.create_oidc_provider
  oidc_provider_arn       = include.env.locals.oidc_provider_arn
  max_session_duration    = include.env.locals.max_session_duration

  # Merge environment-specific tags with common tags
  common_tags = merge(
    {
      Environment = include.env.locals.environment
      ManagedBy   = "terraform"
      Project     = "github-oidc-auth"
      Repository  = "panicboat/platform"
    },
    include.env.locals.additional_tags
  )
}
```

- [ ] **Step 3: 管理アカウントの認証情報であることを確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text
```

Expected: `arn:aws:iam::559744160976:user/panicboat`

- [ ] **Step 4: plan で差分を確認**

```bash
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt plan
```

Expected: 追加のみ（plan role / apply role / policy / policy attachment 3 / log group）。既存 develop / production のリソースに `destroy` や `replace` が出ないこと

- [ ] **Step 5: apply**

```bash
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 6: ロールの存在を確認**

```bash
aws iam get-role --role-name github-oidc-auth-master-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-master-github-actions-apply-role --query 'Role.Arn' --output text
```

Expected: 両方の ARN が返る

- [ ] **Step 7: コミット**

```bash
git add aws/github-oidc-auth/envs/master/
git commit -s -m "feat(aws/github-oidc-auth): add master environment for management-account stacks"
```

### Task 3.2: `workflow-config.yaml` に `master` env を追加

`panicboat/deploy-actions/label-resolver` は `workflow-config.yaml` の `environments:` を読んで `aws/{service}/envs/{environment}/` を解決する（`docs/superpowers/specs/2026-04-26-environment-naming-design.md` 参照）。`master` を宣言しないと Task 3.3 で移した `aws/route53/envs/master` が CI から見えない。

**Files:**
- Modify: `workflow-config.yaml`

- [ ] **Step 1: `master` env を `environments:` の先頭に追加**

`workflow-config.yaml` の `environments:` 直下、`develop` の前に挿入する。

```yaml
  - environment: master
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-plan-role
        iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-apply-role
```

- [ ] **Step 2: YAML として妥当か確認**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('workflow-config.yaml')); print([e['environment'] for e in d['environments']])"
```

Expected: `['master', 'develop', 'production']`

- [ ] **Step 3: コミット**

```bash
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): declare master environment"
```

### Task 3.3: `aws/route53` を `master` env へ re-home

hosted zone は管理アカウントの資産なので、スタックの env 帰属を `production` から `master` へ移す。state key が `platform/route53/production/` から `platform/route53/master/` に変わるため state 移行を伴う（resources=8 の実 state あり）。

**Files:**
- Create: `aws/route53/envs/master/env.hcl`
- Create: `aws/route53/envs/master/terragrunt.hcl`
- Delete: `aws/route53/envs/production/`

**Interfaces:**
- Consumes: Task 3.2 の `master` env 宣言
- Produces: `platform/route53/master/terraform.tfstate`。Task 3.4 が同スタックに追記する

- [ ] **Step 1: 移行前の state を確認**

```bash
cd aws/route53/envs/production && TG_TF_PATH=tofu terragrunt state list
```

Expected: 6 個の `aws_route53_record` と 2 個の `module.route53.data.aws_route53_zone`

- [ ] **Step 2: `env.hcl` を作成**

```hcl
# env.hcl - Environment-specific configuration for master

locals {
  # Environment-specific settings
  environment = "master"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # production アカウント (= route53-zone-access を assume する側)。
  # Task 1.1 で確定した値に置き換えること。
  production_account_id = "<PROD_ACCOUNT_ID>"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "route53"
    Owner       = "panicboat"
  }
}
```

- [ ] **Step 3: `terragrunt.hcl` を作成**

`aws/route53/envs/production/terragrunt.hcl` をベースに `production_account_id` の受け渡しを追加する。

```hcl
# terragrunt.hcl - Terragrunt configuration for master environment

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "route53"` in modules/lookups.tf
# resolve `../lookup` from within the cache.
terraform {
  source = "../../..//route53/modules"
}

# Input variables for the module
inputs = {
  environment           = include.env.locals.environment
  aws_region            = include.env.locals.aws_region
  production_account_id = include.env.locals.production_account_id

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "route53"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
```

- [ ] **Step 4: state を新しいキーへコピー**

`terragrunt backend migrate` は移行元と移行先の設定を両方解決する。

```bash
terragrunt backend migrate aws/route53/envs/production aws/route53/envs/master
```

- [ ] **Step 5: 移行先 state の中身を確認**

```bash
aws s3 ls s3://terragrunt-state-559744160976/platform/route53/master/
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt state list
```

Expected: `terraform.tfstate` が存在し、Step 1 と同じ 8 エントリが返る

- [ ] **Step 6: 差分ゼロを確認**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `No changes.`（`production_account_id` はまだ使われていないため差分は出ない）

- [ ] **Step 7: 旧 env ディレクトリと旧 state を削除**

```bash
git rm -r aws/route53/envs/production
aws s3 rm s3://terragrunt-state-559744160976/platform/route53/production/terraform.tfstate
```

- [ ] **Step 8: コミット**

```bash
git add aws/route53/envs/master/
git commit -s -m "refactor(aws/route53): re-home stack from production to master environment"
```

### Task 3.4: `route53-zone-access` ロールを作る

production アカウントから管理アカウントの hosted zone を操作するためのロール。信頼先は production アカウント root 1 つで、実際に誰が assume できるかは production 側の IAM で制御する（設計 §4 参照）。

**Files:**
- Create: `aws/route53/modules/zone_access.tf`
- Modify: `aws/route53/modules/variables.tf`

**Interfaces:**
- Consumes: Task 3.3 の `production_account_id` input
- Produces: `arn:aws:iam::559744160976:role/route53-zone-access`。Task 5.1 の provider alias、Task 5.2 の external-dns IAM、Task 5.3 の helm 値がこの ARN を参照する

- [ ] **Step 1: `variables.tf` に `production_account_id` を追加**

`aws/route53/modules/variables.tf` の末尾に追記する。

```hcl
variable "production_account_id" {
  description = "AWS account ID of the production account allowed to assume route53-zone-access"
  type        = string
}
```

- [ ] **Step 2: `zone_access.tf` を作成**

```hcl
# zone_access.tf - Cross-account role that lets the production account manage
# records in the hosted zones owned by this (= management) account.
#
# Why root principal instead of listing individual role ARNs: IAM rejects a
# trust policy naming a role ARN that does not exist yet
# (= MalformedPolicyDocument). `eks-production-external-dns` is not created
# until the EKS stack applies, so enumerating ARNs would pin this role's
# creation to the very end of the migration. Delegating to the production
# account's own IAM is the standard cross-account pattern.
#
# Why read and write live in one role: Terraform provider aliases are static
# configuration and there is no way to point plan and apply at different
# assume-role targets under the current setup (= terragrunt inputs are fixed
# per env, and the CI executor lives in an external repository). The plan
# role therefore gains assume access to a write-capable role, scoped to these
# two zones. `terragrunt plan` never calls ChangeResourceRecordSets.

data "aws_iam_policy_document" "zone_access_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.production_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "zone_access" {
  name               = "route53-zone-access"
  assume_role_policy = data.aws_iam_policy_document.zone_access_assume.json

  tags = merge(var.common_tags, {
    Name = "route53-zone-access"
  })
}

resource "aws_iam_role_policy" "zone_access" {
  name = "route53-zone-access"
  role = aws_iam_role.zone_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone",
        ]
        Resource = [
          module.route53.zones.panicboat_net.arn,
          module.route53.zones.dystopia_city.arn,
        ]
      },
      {
        # zone 名引き (= data.aws_route53_zone) と変更伝播待ち (= GetChange) は
        # zone 単位に絞れない API のため Resource = "*"。
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:GetChange",
        ]
        Resource = "*"
      },
    ]
  })
}
```

- [ ] **Step 3: fmt と validate**

```bash
tofu fmt -recursive aws/route53/
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt validate
```

Expected: fmt が差分を出さず、validate が成功

- [ ] **Step 4: plan で追加内容を確認**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `aws_iam_role.zone_access` と `aws_iam_role_policy.zone_access` の 2 追加のみ。既存レコード 6 件に変更が出ないこと

- [ ] **Step 5: apply**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 6: ロールとポリシーを確認**

```bash
aws iam get-role --role-name route53-zone-access --query 'Role.AssumeRolePolicyDocument' --output json
aws iam get-role-policy --role-name route53-zone-access --policy-name route53-zone-access --output json
```

Expected: trust の Principal が `arn:aws:iam::<PROD_ACCOUNT_ID>:root`、ポリシーの 1 つ目の statement の Resource が 2 zone ARN

- [ ] **Step 7: コミット**

```bash
git add aws/route53/modules/
git commit -s -m "feat(aws/route53): add cross-account zone access role for production"
```

---

# Phase 4: Production の OIDC ロールと CI 切替

新アカウントに OIDC provider と plan / apply ロールを作り、CI の向き先を切り替える。**順序が重要**で、ロールの存在を確認してから `workflow-config.yaml` をマージする。

### Task 4.1: plan ロールに `sts:AssumeRole` を付与できるようにする

`ReadOnlyAccess` 管理ポリシーには `sts:AssumeRole` が含まれないため、plan ロールが `route53-zone-access` を assume できない。module 側に任意の assume 先を渡せる変数を足す。

**Files:**
- Modify: `aws/github-oidc-auth/modules/variables.tf`
- Modify: `aws/github-oidc-auth/modules/main.tf`

**Interfaces:**
- Produces: `assume_role_arns` input。Task 4.2 の production env.hcl が値を渡す

- [ ] **Step 1: `variables.tf` に変数を追加**

`aws/github-oidc-auth/modules/variables.tf` の末尾に追記する。

```hcl
variable "assume_role_arns" {
  description = "Cross-account role ARNs the plan role is allowed to assume (apply role already has AdministratorAccess)"
  type        = list(string)
  default     = []
}
```

- [ ] **Step 2: `main.tf` にインラインポリシーを追加**

`aws_iam_role_policy_attachment.plan_state_lock` リソースの直後に追記する。

```hcl
# Plan role cross-account assume grant.
#
# ReadOnlyAccess (= plan role の主権限) には sts:AssumeRole が含まれないため、
# クロスアカウントの data source 解決に必要な assume を明示付与する。
# apply role は AdministratorAccess で既に assume 可能なので対象外。
resource "aws_iam_role_policy" "plan_assume_role" {
  count = length(var.assume_role_arns) > 0 ? 1 : 0

  name = "cross-account-assume"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.assume_role_arns
      }
    ]
  })
}
```

- [ ] **Step 3: fmt と validate**

```bash
tofu fmt -recursive aws/github-oidc-auth/
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功

- [ ] **Step 4: 既存 env に差分が出ないことを確認**

`assume_role_arns` はデフォルト空リストなので `count = 0` となり、develop / master には影響しないはず。

```bash
cd aws/github-oidc-auth/envs/develop && TG_TF_PATH=tofu terragrunt plan
cd aws/github-oidc-auth/envs/master  && TG_TF_PATH=tofu terragrunt plan
```

Expected: 両方 `No changes.`

- [ ] **Step 5: コミット**

```bash
git add aws/github-oidc-auth/modules/
git commit -s -m "feat(aws/github-oidc-auth): allow granting cross-account assume to the plan role"
```

### Task 4.2: production の OIDC provider とロールを新アカウントに作る

**Files:**
- Modify: `aws/github-oidc-auth/envs/production/env.hcl`
- Modify: `aws/github-oidc-auth/envs/production/terragrunt.hcl`

**Interfaces:**
- Consumes: Task 3.4 の `route53-zone-access` ARN、Task 4.1 の `assume_role_arns`
- Produces: 新アカウントの `github-oidc-auth-production-github-actions-{plan,apply}-role`。Task 4.3 が `workflow-config.yaml` で参照する

- [ ] **Step 1: `env.hcl` の OIDC provider 設定を反転**

`aws/github-oidc-auth/envs/production/env.hcl` の以下 2 行を置き換える。

置換前:

```hcl
  # OIDC provider settings (reuse existing provider if created in develop)
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"
```

置換後:

```hcl
  # OIDC provider settings
  # production は専用アカウントに分離済で、そのアカウントには provider が
  # 存在しないため自前で作成する (= develop / master は管理アカウントの
  # 既存 provider を共有)。
  create_oidc_provider = true
  oidc_provider_arn    = ""
```

- [ ] **Step 2: `env.hcl` に `assume_role_arns` を追加**

同ファイルの `additional_tags` ブロックの直前に追記する。

```hcl
  # Route53 hosted zone は管理アカウント (= 559744160976) に残しているため、
  # plan 時の data.aws_route53_zone 解決に cross-account assume が要る。
  assume_role_arns = [
    "arn:aws:iam::559744160976:role/route53-zone-access",
  ]
```

- [ ] **Step 3: `terragrunt.hcl` で input を渡す**

`aws/github-oidc-auth/envs/production/terragrunt.hcl` の `inputs` ブロックに追記する。

```hcl
  assume_role_arns = include.env.locals.assume_role_arns
```

- [ ] **Step 4: 新アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::<PROD_ACCOUNT_ID>:role/OrganizationAccountAccessRole \
  --role-session-name oidc-bootstrap --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `<PROD_ACCOUNT_ID>`

- [ ] **Step 5: plan**

```bash
cd aws/github-oidc-auth/envs/production && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt plan
```

Expected: 全て新規追加（OIDC provider / plan role / apply role / state lock policy / cross-account assume policy / attachment 3 / log group）

- [ ] **Step 6: apply**

```bash
cd aws/github-oidc-auth/envs/production && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 7: ロールと provider を確認**

```bash
aws iam list-open-id-connect-providers
aws iam get-role --role-name github-oidc-auth-production-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role --query 'Role.Arn' --output text
aws iam get-role-policy --role-name github-oidc-auth-production-github-actions-plan-role \
  --policy-name cross-account-assume --output json
```

Expected: provider が 1 件、両ロールの ARN が新アカウント、assume ポリシーの Resource が `route53-zone-access` ARN

- [ ] **Step 8: クロスアカウント assume の疎通を確認**

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::559744160976:role/route53-zone-access \
  --role-session-name migration-check \
  --query 'AssumedRoleUser.Arn' --output text
```

Expected: `arn:aws:sts::559744160976:assumed-role/route53-zone-access/migration-check`

- [ ] **Step 9: コミット**

```bash
git add aws/github-oidc-auth/envs/production/
git commit -s -m "feat(aws/github-oidc-auth): provision production OIDC in its dedicated account"
```

### Task 4.3: `workflow-config.yaml` の production ロール ARN を差し替える

**Files:**
- Modify: `workflow-config.yaml`

- [ ] **Step 1: Task 4.2 のロールが存在することを再確認**

差し替え前の必須ゲート。ここを飛ばして先にマージすると CI の production plan / apply が存在しないロールを assume して壊れる。

```bash
aws iam get-role --role-name github-oidc-auth-production-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role --query 'Role.Arn' --output text
```

Expected: 両方が `arn:aws:iam::<PROD_ACCOUNT_ID>:role/...` を返す

- [ ] **Step 2: `production` ブロックの ARN を差し替え**

`workflow-config.yaml` の `production` 環境の 2 行を置き換える。

```yaml
        iam_role_plan: arn:aws:iam::<PROD_ACCOUNT_ID>:role/github-oidc-auth-production-github-actions-plan-role
        iam_role_apply: arn:aws:iam::<PROD_ACCOUNT_ID>:role/github-oidc-auth-production-github-actions-apply-role
```

- [ ] **Step 3: 管理アカウント ID が production ブロックから消えたことを確認**

```bash
python3 - <<'EOF'
import yaml
d = yaml.safe_load(open('workflow-config.yaml'))
for e in d['environments']:
    tg = e.get('stacks', {}).get('terragrunt', {})
    print(e['environment'], tg.get('aws_region'), tg.get('iam_role_apply'))
EOF
```

Expected: `master` と `develop` が `559744160976`、`production` が `<PROD_ACCOUNT_ID>`

- [ ] **Step 4: コミット**

```bash
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): point production stacks at the dedicated account"
```

---

# Phase 5: クロスアカウント配線

`aws/alb` の provider alias、`aws/eks` の external-dns IAM、helmfile の実行時設定を揃える。コード変更のみで apply は Phase 7 に回す。

### Task 5.1: `aws/alb` にクロスアカウント provider を通す

`aws/route53/lookup` は provider を宣言せず呼び出し側の default provider を継承する作りなので、`providers = { aws = aws.route53 }` で差し替えるだけでよい（lookup module 自体は無変更）。

**Files:**
- Modify: `aws/alb/modules/terraform.tf`
- Modify: `aws/alb/modules/lookups.tf`
- Modify: `aws/alb/modules/main.tf`
- Modify: `aws/alb/modules/variables.tf`
- Modify: `aws/alb/envs/production/env.hcl`
- Modify: `aws/alb/envs/production/terragrunt.hcl`

**Interfaces:**
- Consumes: Task 3.4 の `route53-zone-access` ARN
- Produces: `var.route53_zone_role_arn`（`aws/alb` 内のみ。`aws/eks` は Task 5.2 で lookup ごと削除するため不要）

- [ ] **Step 1: `variables.tf` に変数を追加**

`aws/alb/modules/variables.tf` の末尾に追記する。

```hcl
variable "route53_zone_role_arn" {
  description = "Role in the management account assumed to read/write the hosted zones"
  type        = string
}
```

- [ ] **Step 2: `terraform.tf` に alias provider を追加**

`aws/alb/modules/terraform.tf` の既存 `provider "aws"` ブロックの直後に追記する。

```hcl
# Hosted zone は管理アカウント (= 559744160976) に残しているため、
# zone の読み取りと ACM DNS validation レコードの書き込みはこの alias 経由で行う。
provider "aws" {
  alias  = "route53"
  region = var.aws_region

  assume_role {
    role_arn = var.route53_zone_role_arn
  }

  default_tags {
    tags = var.common_tags
  }
}
```

- [ ] **Step 3: `lookups.tf` で provider を差し替え**

`aws/alb/modules/lookups.tf` を以下に置き換える。

```hcl
# lookups.tf - External stack lookups.
#
# route53/lookup は provider を宣言せず呼び出し側の default provider を継承する
# ため、ここで aws.route53 (= 管理アカウントへの assume role) を default として
# 渡すことで zone を別アカウントから解決する。

module "route53" {
  source = "../../route53/lookup"

  providers = {
    aws = aws.route53
  }
}
```

- [ ] **Step 4: validation レコードに provider を指定**

`aws/alb/modules/main.tf` の `aws_route53_record.wildcard_panicboat_net_validation` と `aws_route53_record.wildcard_dystopia_city_validation` の両方に、`for_each` ブロックの直前へ 1 行追加する。

```hcl
  provider = aws.route53
```

ACM 証明書（`aws_acm_certificate`）と検証待ち（`aws_acm_certificate_validation`）は production アカウント側のリソースなので default provider のまま。

- [ ] **Step 5: `env.hcl` に ARN を追加**

`aws/alb/envs/production/env.hcl` の `environment_tags` ブロックの直前に追記する。

```hcl
  # 管理アカウント (= 559744160976) の hosted zone を操作するための assume 先。
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
```

- [ ] **Step 6: `terragrunt.hcl` で input を渡す**

`aws/alb/envs/production/terragrunt.hcl` の `inputs` ブロック、`aws_region` の次の行に追記する。

```hcl
  route53_zone_role_arn = include.env.locals.route53_zone_role_arn
```

- [ ] **Step 7: fmt と validate**

```bash
tofu fmt -recursive aws/alb/
cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功

- [ ] **Step 8: plan で zone が解決できることを確認**

新アカウントの認証情報で実行する。

```bash
cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: `data.aws_route53_zone` の解決に成功し、ACM 証明書 2 枚と validation レコードの新規作成が計画される。`Invalid provider configuration` や `no matching Route53Zone found` が出ないこと

- [ ] **Step 9: コミット**

```bash
git add aws/alb/
git commit -s -m "feat(aws/alb): resolve hosted zones through a cross-account provider"
```

### Task 5.2: `aws/eks` の external-dns IAM を assume role 方式へ

`module.route53` の参照は `addons.tf` の `external_dns_hosted_zone_arns` 1 箇所のみ。assume role 方式にすると zone ARN が不要になり、lookup ごと削除できる。

**Files:**
- Modify: `aws/eks/modules/addons.tf`
- Modify: `aws/eks/modules/lookups.tf`
- Modify: `aws/eks/modules/variables.tf`
- Modify: `aws/eks/envs/production/env.hcl`
- Modify: `aws/eks/envs/production/terragrunt.hcl`

**Interfaces:**
- Consumes: Task 3.4 の `route53-zone-access` ARN
- Produces: `eks-production-external-dns` ロールが Route53 権限ではなく `sts:AssumeRole` を持つ。Task 5.3 の helm 値と対になる

- [ ] **Step 1: `module.route53` の参照箇所が 1 つだけであることを再確認**

```bash
grep -rn "module\.route53" aws/eks/modules/
```

Expected: `addons.tf` の 2 行（`panicboat_net.arn` / `dystopia_city.arn`）のみ

- [ ] **Step 2: `variables.tf` に変数を追加**

`aws/eks/modules/variables.tf` の末尾に追記する。

```hcl
variable "route53_zone_role_arn" {
  description = "Role in the management account that external-dns assumes to manage hosted zone records"
  type        = string
}
```

- [ ] **Step 3: `addons.tf` の external-dns IRSA を差し替え**

`module "external_dns_irsa"` ブロック全体を以下に置き換える。`terraform-aws-modules/iam//modules/iam-role-for-service-accounts` v6 は `source_policy_documents` が非空なら `create_policy` が真になりインラインポリシーを生成する。

```hcl
# external-dns IAM role.
#
# Hosted zone は管理アカウント (= 559744160976) に残っているため、Pod は
# 直接 Route53 を叩かず route53-zone-access を assume する
# (= external-dns の --aws-assume-role フラグ、
#   kubernetes/components/external-dns/production/values.yaml.gotmpl)。
# そのため attach_external_dns_policy (= 同一アカウントの zone を前提とする
# Route53 権限) ではなく sts:AssumeRole のみを付与する。
data "aws_iam_policy_document" "external_dns_assume_zone_access" {
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [var.route53_zone_role_arn]
  }
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "eks-${var.environment}-external-dns"
  use_name_prefix = false

  source_policy_documents = [data.aws_iam_policy_document.external_dns_assume_zone_access.json]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = var.common_tags
}
```

- [ ] **Step 4: `lookups.tf` から route53 lookup を削除**

`aws/eks/modules/lookups.tf` を以下に置き換える。

```hcl
# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
```

- [ ] **Step 5: `env.hcl` に ARN を追加**

`aws/eks/envs/production/env.hcl` の `environment_tags` ブロックの直前に追記する。

```hcl
  # external-dns が管理アカウント (= 559744160976) の hosted zone を操作するための assume 先。
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
```

- [ ] **Step 6: `terragrunt.hcl` で input を渡す**

`aws/eks/envs/production/terragrunt.hcl` の `inputs` ブロックに追記する。

```hcl
  route53_zone_role_arn = include.env.locals.route53_zone_role_arn
```

- [ ] **Step 7: fmt と validate**

```bash
tofu fmt -recursive aws/eks/
cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功。`module.route53` への未解決参照が残っていればここで落ちる

- [ ] **Step 8: コミット**

```bash
git add aws/eks/
git commit -s -m "feat(aws/eks): grant external-dns cross-account assume instead of zone-scoped Route53"
```

### Task 5.3: external-dns に `--aws-assume-role` を設定

**Files:**
- Modify: `kubernetes/components/external-dns/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: Task 5.2 の IRSA ロール（`sts:AssumeRole` のみを持つ）、Task 3.4 の `route53-zone-access`

- [ ] **Step 1: `extraArgs` セクションを追加**

`kubernetes/components/external-dns/production/values.yaml.gotmpl` の `txtOwnerId` ブロックと `serviceAccount` ブロックの間に挿入する。

```yaml
# =============================================================================
# Cross-account Route53 access
# =============================================================================
# hosted zone は管理アカウント (= 559744160976) に残しているため、Pod の IRSA
# ロールでは直接 Route53 を叩けない。route53-zone-access を assume して操作する。
# IRSA ロール側の権限は sts:AssumeRole のみ (= aws/eks/modules/addons.tf)。
extraArgs:
  - --aws-assume-role=arn:aws:iam::559744160976:role/route53-zone-access
```

- [ ] **Step 2: helmfile が template できることを確認**

```bash
helmfile -e production -f kubernetes/components/external-dns/production/helmfile.yaml template \
  | grep -A3 -- "--aws-assume-role"
```

Expected: Deployment の args に `--aws-assume-role=arn:aws:iam::559744160976:role/route53-zone-access` が含まれる

- [ ] **Step 3: コミット**

```bash
git add kubernetes/components/external-dns/production/values.yaml.gotmpl
git commit -s -m "feat(external-dns): assume the management-account role for Route53"
```

---

# Phase 6: 共有リソースの再作成

### Task 6.1: service-linked role と Secrets Manager を新アカウントに作る

**Files:** なし（既存スタックの apply と手動投入）

**Interfaces:**
- Consumes: Task 0.4 の退避ファイル `$HOME/.secrets-backup-559744160976.json`

- [ ] **Step 1: 新アカウントの認証情報で `iam-service-linked-roles` を apply**

```bash
cd aws/iam-service-linked-roles/envs/production && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 2: service-linked role を確認**

```bash
aws iam get-role --role-name AWSServiceRoleForEC2Spot --query 'Role.Arn' --output text
```

Expected: `arn:aws:iam::<PROD_ACCOUNT_ID>:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot`

- [ ] **Step 3: monorepo 側の Secrets Manager スタックを apply**

`panicboat/holmes/slack` と `panicboat/holmes/alertmanager` は monorepo が管理する。Task 8.1 で扱うため、ここでは platform 管理外の残り 6 件を手動作成する。

```bash
for name in \
  panicboat/oauth2-proxy/google \
  panicboat/grafana/admin \
  panicboat/github-app/panicboat \
  panicboat/keycloak/admin \
  panicboat/holmes/github \
  panicboat/alertmanager/slack-notify
do
  aws secretsmanager create-secret --region ap-northeast-1 --name "$name"
done
```

- [ ] **Step 4: 退避した値を投入**

```bash
jq -c 'select(.name | test("holmes/(slack|alertmanager)$") | not)' \
  "$HOME/.secrets-backup-559744160976.json" \
| while read -r row; do
    name=$(echo "$row" | jq -r .name)
    value=$(echo "$row" | jq -r .value)
    aws secretsmanager put-secret-value --region ap-northeast-1 \
      --secret-id "$name" --secret-string "$value" >/dev/null
    echo "restored: $name"
  done
```

Expected: 6 件の `restored:` 行

- [ ] **Step 5: 投入結果を確認**

```bash
aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text | tr '\t' '\n' | sort
```

Expected: 6 件（holmes の 2 件は Task 8.1 で追加される）

---

# Phase 7: helmfile 更新と EKS 再構築

### Task 7.1: helmfile のアカウント ID を差し替える

helmfile v1.4 は親 `helmfile.yaml.gotmpl` の environments values を子 helmfile に継承しないため、同じ値が両方に定義されている。片方だけ直すと不整合になる。

**Files:**
- Modify: `kubernetes/helmfile.yaml.gotmpl`
- Modify: `kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml`
- Modify: `kubernetes/components/external-dns/production/helmfile.yaml`
- Modify: `kubernetes/components/loki/production/helmfile.yaml`
- Modify: `kubernetes/components/mimir/production/helmfile.yaml`
- Modify: `kubernetes/components/tempo/production/helmfile.yaml`

- [ ] **Step 1: 差し替え対象を列挙**

```bash
grep -rn "559744160976" kubernetes/helmfile.yaml.gotmpl kubernetes/components/
```

Expected: 11 行（親 5 + 子 6）

- [ ] **Step 2: 一括置換**

`kubernetes/components/external-dns/production/values.yaml.gotmpl` の `--aws-assume-role` は **管理アカウント ID のまま残す**必要があるため、置換対象から除外する。

```bash
grep -rl "559744160976" kubernetes/helmfile.yaml.gotmpl kubernetes/components/ \
  | grep -v 'external-dns/production/values.yaml.gotmpl' \
  | xargs sed -i '' 's/559744160976/<PROD_ACCOUNT_ID>/g'
```

- [ ] **Step 3: 置換結果を検証**

```bash
grep -rn "559744160976" kubernetes/
grep -rn "<PROD_ACCOUNT_ID>" kubernetes/ | wc -l
```

Expected: 1 つ目は `kubernetes/components/external-dns/production/values.yaml.gotmpl` の `--aws-assume-role` 行と `kubernetes/manifests/` 配下の rendered 出力のみ。2 つ目は 11

- [ ] **Step 4: helmfile が template できることを確認**

```bash
helmfile -e production template > /dev/null && echo OK
```

Expected: `OK`

- [ ] **Step 5: コミット**

```bash
git add kubernetes/helmfile.yaml.gotmpl kubernetes/components/
git commit -s -m "feat(kubernetes): point production values at the dedicated AWS account"
```

### Task 7.2: EKS を新アカウントで再構築する

既存の recreate runbook をそのまま実行する。本タスクは runbook を呼び出す薄いラッパで、runbook 内の手順を複製しない。

**Files:**
- Modify: `docs/runbooks/eks-production-recreate.md`（Phase 0 の期待値をアカウント非依存に直す）

- [ ] **Step 1: Service Quota の増枠が承認済みか確認**

未承認なら Karpenter がノードを 1 台も出せずに詰むため、ここが本 Phase のゲート。

```bash
for qc in L-1216C47A L-34B43A08; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code $qc \
    --region ap-northeast-1 --query 'Quota.{Name:QuotaName,Value:Value}' --output json
done
```

Expected: On-Demand が 64 以上、Spot が 256 以上

- [ ] **Step 2: runbook の Phase 0 の期待値を更新**

`docs/runbooks/eks-production-recreate.md` の 2.2 節と Phase 0 に `arn:aws:iam::559744160976:user/panicboat` がハードコードされている。production はアカウントが変わったため、以下の記述に置き換える。

```
- production アカウント (= `<PROD_ACCOUNT_ID>`) の AdministratorAccess 相当の principal
  (= IAM Identity Center の AdministratorAccess、または管理アカウントから
  `OrganizationAccountAccessRole` を assume した session)
```

Phase 0 の期待値コメント `# → arn:aws:iam::559744160976:user/panicboat` は、返るアカウント ID が `<PROD_ACCOUNT_ID>` であることを確認する記述に変える。

- [ ] **Step 3: runbook の Phase 1-10 を実行**

`docs/runbooks/eks-production-recreate.md` に従う。Phase 7 の残りスタック apply には `eks-holmesgpt` が含まれていないため、`eks-secrets eks-logs eks-metrics eks-traces` の後に追加で apply する。

```bash
cd aws/eks-holmesgpt/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 4: クラスタと証明書を確認**

```bash
aws eks list-clusters --region ap-northeast-1
aws acm list-certificates --region ap-northeast-1 --certificate-statuses ISSUED \
  --query 'CertificateSummaryList[].DomainName' --output text
```

Expected: `eks-production` が返り、`*.panicboat.net` と `*.dystopia.city` が `ISSUED`

- [ ] **Step 5: external-dns のクロスアカウント書き込みを確認**

Task 0.3 で zone を掃除してあるため、レコードが「増える」ことで疎通を確認できる。

```bash
kubectl -n external-dns logs deploy/external-dns --tail=50 | grep -i "assume\|error\|record"
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query 'ResourceRecordSets[].{N:Name,T:Type}' --output text
```

Expected: ログに assume role エラーが無く、Ingress の hostname に対応する A / TXT レコードが zone に作成されている

- [ ] **Step 6: コミット**

```bash
git add docs/runbooks/eks-production-recreate.md
git commit -s -m "docs(runbooks): decouple the recreate runbook from the management account"
```

---

# Phase 8: monorepo リポジトリの移行

### Task 8.1: monorepo の production スタックを新アカウントへ

`panicboat/monorepo` の `system-components/holmes/terragrunt`（Secrets Manager 2 件）と `services/monolith/terragrunt`（resources=0）が、同じ `terragrunt-state-${get_aws_account_id()}` 規約で state を持つ。

**Files（monorepo リポジトリ）:**
- Modify: `workflow-config.yaml`

**Interfaces:**
- Consumes: Task 2.1 の state バケット、Task 4.2 の production ロール、Task 0.4 の退避ファイル

- [ ] **Step 1: 現状の state を確認**

```bash
aws s3 ls s3://terragrunt-state-559744160976/services/ --recursive
aws s3 ls s3://terragrunt-state-559744160976/system-components/ --recursive
```

Expected: `services/monolith/production`、`services/nginx-app/develop`、`system-components/holmes/production` の 3 件

- [ ] **Step 2: 新アカウントの認証情報で holmes スタックを apply**

```bash
cd ../monorepo/system-components/holmes/terragrunt/envs/production
TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

Expected: `aws_secretsmanager_secret` 2 件が新規作成される

- [ ] **Step 3: holmes の secret 値を投入**

```bash
jq -c 'select(.name | test("holmes/(slack|alertmanager)$"))' \
  "$HOME/.secrets-backup-559744160976.json" \
| while read -r row; do
    name=$(echo "$row" | jq -r .name)
    value=$(echo "$row" | jq -r .value)
    aws secretsmanager put-secret-value --region ap-northeast-1 \
      --secret-id "$name" --secret-string "$value" >/dev/null
    echo "restored: $name"
  done
```

Expected: 2 件の `restored:` 行

- [ ] **Step 4: monolith スタックを apply**

resources=0 のため state を新規に作るだけ。

```bash
cd ../monorepo/services/monolith/terragrunt/envs/production
TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [ ] **Step 5: monorepo の `workflow-config.yaml` に production env を追加**

現状 `develop` のみ宣言されており、production スタックは手動 apply 運用になっている。CI に載せるため追加する。

```yaml
  - environment: production
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::<PROD_ACCOUNT_ID>:role/github-oidc-auth-production-github-actions-plan-role
        iam_role_apply: arn:aws:iam::<PROD_ACCOUNT_ID>:role/github-oidc-auth-production-github-actions-apply-role
```

- [ ] **Step 6: 新アカウントの state を確認**

```bash
aws s3 ls s3://terragrunt-state-<PROD_ACCOUNT_ID>/ --recursive
```

Expected: `services/monolith/production` と `system-components/holmes/production` が存在する

- [ ] **Step 7: コミット（monorepo リポジトリ）**

```bash
cd ../monorepo
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): declare production environment on the dedicated account"
```

---

# Phase 9: 旧アカウントの後片付け

### Task 9.1: 管理アカウントから production 資産を除去

**Files:**
- Modify: `README.md`
- Modify: `README-ja.md`

- [ ] **Step 1: 管理アカウントの認証情報に戻す**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text
```

Expected: `arn:aws:iam::559744160976:user/panicboat`

- [ ] **Step 2: 旧 production の IAM 資産を削除**

Task 4.2 で `aws/github-oidc-auth/envs/production` は新アカウントを向くよう変更済のため、`terragrunt destroy` を打つと**新アカウント側**が消える。旧アカウント側は AWS API で直接削除する。

削除前に、対象が旧アカウントのロールであることを確認する。

```bash
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role --query 'Role.Arn' --output text
```

Expected: `arn:aws:iam::559744160976:role/github-oidc-auth-production-github-actions-apply-role`（管理アカウント ID であること）

確認できたら削除する。旧 state は Step 4 でまとめて消す。

```bash
aws iam detach-role-policy --role-name github-oidc-auth-production-github-actions-apply-role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam detach-role-policy --role-name github-oidc-auth-production-github-actions-plan-role \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam detach-role-policy --role-name github-oidc-auth-production-github-actions-plan-role \
  --policy-arn arn:aws:iam::559744160976:policy/github-oidc-auth-production-terragrunt-state-lock
aws iam delete-role --role-name github-oidc-auth-production-github-actions-apply-role
aws iam delete-role --role-name github-oidc-auth-production-github-actions-plan-role
aws iam delete-policy --policy-arn arn:aws:iam::559744160976:policy/github-oidc-auth-production-terragrunt-state-lock
aws logs delete-log-group --region ap-northeast-1 --log-group-name /github-actions/github-oidc-auth-production
```

- [ ] **Step 3: 残存ロールを確認**

```bash
aws iam list-roles --query 'Roles[?!contains(Path, `aws-service-role`)].RoleName' --output text | tr '\t' '\n'
```

Expected: `AWSReservedSSO_AdministratorAccess_*`、`github-oidc-auth-develop-github-actions-{plan,apply}-role`、`route53-zone-access` の 4 つ

- [ ] **Step 4: 旧 production state を削除**

`platform/route53/production` は Task 3.3 で削除済。残りの production state を消す。

```bash
for key in alb eks eks-holmesgpt eks-logs eks-metrics eks-secrets eks-traces github-oidc-auth iam-service-linked-roles karpenter vpc; do
  aws s3 rm "s3://terragrunt-state-559744160976/platform/${key}/production/terraform.tfstate"
done
aws s3 rm s3://terragrunt-state-559744160976/services/monolith/production/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/system-components/holmes/production/terraform.tfstate
```

- [ ] **Step 5: 旧 production secret を削除**

新アカウントへの投入完了（Task 6.1 Step 5 と Task 8.1 Step 3）を確認してから実行する。

```bash
for name in $(aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text); do
  aws secretsmanager delete-secret --region ap-northeast-1 --secret-id "$name" --force-delete-without-recovery
done
```

- [ ] **Step 6: 管理アカウントに残った state を確認**

```bash
aws s3 ls s3://terragrunt-state-559744160976/ --recursive
```

Expected: `platform/{branch,cost-management,github-oidc-auth,github-repository,repository,route53}/...` と `services/nginx-app/develop` のみ。`*/production/` が `platform/route53/master` を除いて残っていないこと

- [ ] **Step 7: README の環境表に `master` を追加**

`README.md` の「Environments and authentication」節と `README-ja.md` の対応箇所に、`master` env が管理アカウントの横断資産（Route53 hosted zone）を持つこと、`production` が専用アカウントであることを追記する。

- [ ] **Step 8: コミット**

```bash
git add README.md README-ja.md
git commit -s -m "docs: describe the master environment and the dedicated production account"
```

- [ ] **Step 9: Draft PR を作成**

```bash
git push -u origin HEAD
gh pr create --draft \
  --title "Migrate production to a dedicated AWS account" \
  --body "See docs/superpowers/specs/2026-08-18-production-account-migration-design.md"
```

---

## Verification Checklist

- [ ] `aws organizations list-accounts` に ACTIVE な production アカウントが 1 件ある
- [ ] `aws s3api head-bucket --bucket terragrunt-state-<PROD_ACCOUNT_ID>` が成功する
- [ ] 新アカウントの `github-oidc-auth-production-github-actions-{plan,apply}-role` が存在する
- [ ] 新アカウントから `route53-zone-access` を assume できる
- [ ] `aws eks list-clusters --region ap-northeast-1` が新アカウントで `eks-production` を返す
- [ ] `*.panicboat.net` / `*.dystopia.city` の ACM 証明書が新アカウントで `ISSUED`
- [ ] external-dns が管理アカウントの zone にレコードを作成できている
- [ ] `git grep -n 559744160976 -- kubernetes/ workflow-config.yaml` の結果が、`master` / `develop` env の ARN と external-dns の `--aws-assume-role` だけになっている
- [ ] 管理アカウントの state バケットに `*/production/` の state が残っていない（`platform/route53/master` は移行済のため対象外）
- [ ] 管理アカウントの Secrets Manager が空
- [ ] `aws iam list-instance-profiles` が空
