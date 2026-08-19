# Multi-account Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `production` と `develop` をそれぞれ専用 AWS アカウントへ分離し、`559744160976` は横断資産だけを持つ `master` 環境として残す。Route53 hosted zone は管理アカウントに残したままクロスアカウント参照で運用する。

**Architecture:** 管理アカウントに残る横断資産（Route53 / cost-management / GitHub 設定）を `master` env に集約し、`develop` と `production` は新規メンバーアカウントで作り直す。production からは `route53-zone-access` ロールを assume して zone を操作する。Terraform 側は `aws/alb` の provider alias 1 箇所、実行時は external-dns の `--aws-assume-role` で経路を張る。EKS 再構築自体は既存の `docs/runbooks/eks-production-recreate.md` を再利用する。

**Tech Stack:** Terragrunt v1.0.2 + OpenTofu 1.12.0（module 側 `required_version = "1.12.5"`）、AWS provider 6.60.0、GitHub provider ~> 6.13、Helmfile v1.4、external-dns chart 1.21.1（appVersion 0.21.0）、AWS CLI v2、Flux CD。

**Spec:** `docs/superpowers/specs/2026-08-18-production-account-migration-design.md`

## Global Constraints

- 管理アカウント ID: `559744160976`（Organization `o-es9qoj85gw`、Identity Center `ssoins-7758e2d4fb37f3a7`、permission set `ps-77583734ef962d6b`、ユーザー `e7146ab8-20b1-70eb-a63d-b9887df5d7a6`）
- 新アカウントのルートメール: production = `aws+production@panicboat.net`、develop = `aws+develop@panicboat.net`
- `337169763788` / `270242382571` は Task 1.1 で確定する。以降のタスクではこの実値に置換すること
- hosted zone: `panicboat.net` = `Z07598371GKBU0WMF89MD`、`dystopia.city` = `Z03420722KS9MTSCUSIQZ`
- クロスアカウントロール: `arn:aws:iam::559744160976:role/route53-zone-access`
- region: `master` = `ap-northeast-1`、`develop` = `us-east-1`、`production` = `ap-northeast-1`
- Terragrunt の state バケット名は全 `root.hcl` で `terragrunt-state-${get_aws_account_id()}` として動的に組まれる。バケット名をコードに書かない
- コミットは `-s`（`--signoff`）付き。`Co-Authored-By` は付けない
- PR は `gh pr create --draft`

---

## File Structure

### 新規作成

- `aws/github-oidc-auth/envs/master/{env.hcl,terragrunt.hcl}` — `master` env の OIDC provider とロール
- `aws/route53/envs/master/{env.hcl,terragrunt.hcl}` — `production` からの re-home 先
- `aws/route53/modules/zone_access.tf` — `route53-zone-access` ロールとポリシー
- `aws/cost-management/envs/master/{env.hcl,terragrunt.hcl}` — `develop` からの re-home 先

### 移動（`git mv`）

- `github/repository/envs/develop/` → `github/repository/envs/master/`
- `github/branch/envs/develop/` → `github/branch/envs/master/`

### 削除

- `aws/route53/envs/production/`
- `aws/cost-management/envs/develop/`

### 変更

- `workflow-config.yaml` — `master` 追加 + `develop` / `production` の ARN 差し替え
- `aws/github-oidc-auth/modules/{main,variables}.tf` — plan ロールへの `sts:AssumeRole` 付与
- `aws/github-oidc-auth/envs/production/{env.hcl,terragrunt.hcl}` — provider 自前作成 + `assume_role_arns`
- `aws/route53/modules/variables.tf` — `production_account_id`
- `aws/alb/modules/{terraform,lookups,main,variables}.tf` — クロスアカウント provider alias
- `aws/alb/envs/production/{env.hcl,terragrunt.hcl}` — `route53_zone_role_arn`
- `aws/eks/modules/{lookups,addons,variables}.tf` — route53 lookup 削除 + external-dns assume role 化
- `aws/eks/envs/production/{env.hcl,terragrunt.hcl}` — `route53_zone_role_arn`
- `kubernetes/components/external-dns/production/values.yaml.gotmpl` — `extraArgs`
- `kubernetes/helmfile.yaml.gotmpl` + 子 helmfile 5 本 — アカウント ID
- `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` — `STACKS` に `eks-holmesgpt`
- `README.md` / `README-ja.md` — 3 アカウント構成

---

# Phase 0: 旧アカウントの事前整理

新アカウントを作る前に、管理アカウント側のドリフトと孤児を解消し、失うと復旧できない値を退避する。全て `559744160976` で完結する。

> **実行記録（2026-08-19 完了）**
>
> 記載順（0.1 → 0.5）ではなく、**失うと復旧できない退避を先に**した（0.4 → 0.5 → 0.1 → 0.2 → 0.3）。
>
> - Task 0.1: Step 5 の destroy が `-refresh=false` 無しでは通らなかった。手順を修正済。スクリプト側の修正は #802
> - Task 0.5: `panicboat` は Organization ではなく User アカウントだった（`gh api users/panicboat` が `"type":"User"`）。org レベルの secret / variable は存在し得ないことが確定し、未確認項目が 1 つ解消
> - Task 0.3 の後に `aws/route53/envs/production` で `terragrunt plan` を実行し `No changes.` を確認（stale レコード削除が Terraform 管理レコードに影響していないこと）

### Task 0.1: `eks-holmesgpt` を teardown 対象に追加して destroy

`scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS` 配列は 8 スタックだが `eks-holmesgpt` が抜けている（#795 の追加漏れ）。そのため `eks-production-holmesgpt` ロールが残存し、state 内の `data.aws_eks_cluster.this` が存在しないクラスタ `eks-production` を参照している。

**Files:**
- Modify: `scripts/eks-lifecycle/lib/30-destroy-stacks.sh`

**Interfaces:**
- Produces: `platform/eks-holmesgpt/production` state が resources=0 になる。Task 9.2 の削除対象に含められる

- [x] **Step 1: 現状のドリフトを確認**

```bash
cd aws/eks-holmesgpt/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: `data.aws_eks_cluster.this` の解決に失敗する（`No cluster found for name: eks-production`）

- [x] **Step 2: `STACKS` 配列に `eks-holmesgpt` を追加**

`scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS=(` ブロックを以下に置き換える。`eks-holmesgpt` は EKS クラスタの Pod Identity Association を持つため `eks` より前に置く。

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

- [x] **Step 3: 件数の記述を更新**

同ファイル冒頭のコメントを以下に置き換える。

```bash
# 30-destroy-stacks.sh - Destroy 9 EKS-related stacks in fixed order.
#
# Order:
#   eks-karpenter -> eks-holmesgpt -> eks-secrets -> eks-logs -> eks-metrics
#   -> eks-traces -> eks -> alb -> vpc
```

さらに `confirm "About to DESTROY 8 stacks for ENV=${ENV}. Continue?"` と `ok "All 8 stacks destroyed"` の `8` を `9` に変更する。

- [x] **Step 4: 存在しないリソースを state から外す**

クラスタが無いため Pod Identity Association は AWS 上に存在しない。

```bash
cd aws/eks-holmesgpt/envs/production
TG_TF_PATH=tofu terragrunt state rm aws_eks_pod_identity_association.this
```

Expected: `Successfully removed 1 resource instance(s).`

- [x] **Step 5: 残りを destroy**

`-refresh=false` が必須。クラスタが既に無いため、通常の destroy は plan 生成時に `module.eks.data.aws_eks_cluster.this` の解決で落ちる（Step 4 で `state rm` してもこの data source は config 上に残るため結果は同じ）。

```bash
cd aws/eks-holmesgpt/envs/production && TG_TF_PATH=tofu terragrunt destroy -auto-approve -refresh=false
```

Expected: `Plan: 0 to add, 0 to change, 2 to destroy.` に続いて `aws_iam_role_policy.bedrock_invoke` と `aws_iam_role.pod_identity` が destroy される

- [x] **Step 6: ロールが消えたことを確認**

```bash
aws iam get-role --role-name eks-production-holmesgpt
```

Expected: `NoSuchEntity` エラー

- [x] **Step 7: コミット**

```bash
git add scripts/eks-lifecycle/lib/30-destroy-stacks.sh
git commit -s -m "fix(scripts/eks-lifecycle): include eks-holmesgpt in destroy order"
```

### Task 0.2: 孤児リソースの削除

**Files:** なし（AWS API 操作のみ）

- [x] **Step 1: 孤児 instance profile を確認**

```bash
aws iam list-instance-profiles \
  --query 'InstanceProfiles[].{Name:InstanceProfileName,Roles:Roles[].RoleName}' --output json
```

Expected: `eks-production_513473553642647435` が `Roles: []` で 1 件返る

- [x] **Step 2: instance profile を削除**

```bash
aws iam delete-instance-profile --instance-profile-name eks-production_513473553642647435
```

- [x] **Step 3: レガシーログ グループを削除**

state に対応の無い 3 本のみ。`/github-repository/{ansible,deploy-actions,dotfiles,monorepo,panicboat-actions,platform}` は `platform/repository/develop` state が管理しているため残す。

```bash
aws logs delete-log-group --region ap-northeast-1 --log-group-name /github-repository/generated-manifests
aws logs delete-log-group --region ap-northeast-1 --log-group-name /github-repository/kubernetes-clusters
aws logs delete-log-group --region us-east-1   --log-group-name /github-actions/claude-code-action-monorepo
```

- [x] **Step 4: 削除を確認**

```bash
aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text
aws logs describe-log-groups --region ap-northeast-1 --query 'logGroups[].logGroupName' --output text
aws logs describe-log-groups --region us-east-1 --query 'logGroups[].logGroupName' --output text
```

Expected: instance profile が空、`ap-northeast-1` が 8 本、`us-east-1` が空

### Task 0.3: `dystopia.city` の stale DNS レコード削除

削除済み ALB を指す ALIAS 4 件と external-dns 所有権 TXT 2 件が残っている。Phase 7 で external-dns がレコードを「作成」できることをもって疎通確認したいので先に消す。

**Files:** なし（Route53 API 操作のみ）

- [x] **Step 1: 対象レコードを確認**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query "ResourceRecordSets[?Type=='A'||Type=='AAAA'||(Type=='TXT'&&contains(Name,'auth'))]" --output json
```

Expected: 6 件。ALIAS の向き先が `k8s-application-92fded7941-*` であること

- [x] **Step 2: 削除用 change batch を生成**

値を手で書き写すと ALIAS の `HostedZoneId` を取り違えるため、必ず API 出力から生成する。

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query "ResourceRecordSets[?Type=='A'||Type=='AAAA'||(Type=='TXT'&&contains(Name,'auth'))]" \
  --output json \
  | jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' \
  > /tmp/dystopia-stale-delete.json

cat /tmp/dystopia-stale-delete.json
```

Expected: `Changes` が 6 要素

- [x] **Step 3: 削除を実行**

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --change-batch file:///tmp/dystopia-stale-delete.json
```

- [x] **Step 4: 残存レコードを確認**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03420722KS9MTSCUSIQZ \
  --query 'ResourceRecordSets[].{N:Name,T:Type}' --output text
```

Expected: 5 件（`dystopia.city.` の SOA / NS / MX / TXT、`google._domainkey.dystopia.city.` TXT）

### Task 0.4: Secrets Manager の値を退避

8 件の値は Terraform 管理外（手動投入）で、旧アカウントを片付けると復旧できない。

**Files:** なし

**Interfaces:**
- Produces: `$HOME/.secrets-backup-559744160976.json`。Task 6.1 と Task 8.1 が読む

- [x] **Step 1: 全 secret 名を列挙**

```bash
aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text | tr '\t' '\n'
```

Expected: 8 件（`panicboat/oauth2-proxy/google`, `panicboat/grafana/admin`, `panicboat/github-app/panicboat`, `panicboat/keycloak/admin`, `panicboat/holmes/slack`, `panicboat/holmes/alertmanager`, `panicboat/holmes/github`, `panicboat/alertmanager/slack-notify`）

- [x] **Step 2: 値を退避**

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

Expected: パーミッションが `-rw-------`

- [x] **Step 3: 退避件数を確認**

```bash
grep -c '"name"' "$HOME/.secrets-backup-559744160976.json"
```

Expected: `8`

### Task 0.5: GitHub 側の非 IaC 設定を棚卸しする

設計 §5-5 で「変更不要」と判断した項目のうち、org レベルの secret / variable は権限不足で確認できていない。移行前に確定させる。

**Files:** なし

- [x] **Step 1: `panicboat` が Organization かどうかを確認**

org レベルの secret / variable は Organization アカウント専用の機能。所有者が User アカウントなら概念ごと存在しない。

```bash
gh api users/panicboat --jq '{login, type}'
```

Expected: `{"login":"panicboat","type":"User"}` — **User なので org レベルの secret / variable は存在し得ない**。`gh api orgs/panicboat/actions/secrets` が 404 を返すのはスコープ不足ではなくこれが理由。`"type":"Organization"` が返った場合のみ、`gh auth refresh -s admin:org` でスコープを足して一覧を取得し、AWS アカウント ID を含む値があれば Phase 4 の差し替え対象に加える

- [x] **Step 2: リポジトリレベルの設定が AWS アカウントに依存しないことを確認**

```bash
for r in platform monorepo; do
  echo "--- $r ---"
  gh secret list -R "panicboat/$r"
  gh variable list -R "panicboat/$r"
done
```

Expected: `platform` は `APP_PRIVATE_KEY` / `APP_ID`（`1371999`）、`monorepo` は加えて `SLACK_BOT_TOKEN`。いずれも GitHub App とSlack の資格情報で AWS アカウント ID を含まない

- [x] **Step 3: GitHub Environments の有無を確認**

`aws/github-oidc-auth` の trust policy が `repo:panicboat/*:environment:{master,develop,production}` を許可条件に含むが、Environment が存在しなければこの条件は使われない。

```bash
for r in platform monorepo; do
  echo "--- $r ---"
  gh api "repos/panicboat/$r/environments" --jq '.environments[].name'
done
```

Expected: 両方とも出力なし（0 件）。もし存在する場合は、移行後も同名で残っていることを Phase 9 で再確認する

- [x] **Step 4: ruleset の現状を記録**

Phase 3 の `github/branch` re-home 前後で変化していないことを比較するための基準値。

```bash
for r in monorepo platform deploy-actions; do
  gh api "repos/panicboat/$r/rulesets" --jq '.[] | "\(.id) \(.name) \(.enforcement)"'
done
```

Expected: 3 本とも `active`（`15519991 monorepo-main` / `15519990 platform-main` / `15519988 deploy-actions-main`）。この出力を控えておく

---

# Phase 1: 新アカウント作成

手動 AWS 操作のみ。コード変更もコミットも無い。

> **実行記録（2026-08-20 完了）**
>
> | env | Account ID | root email |
> |---|---|---|
> | production | `337169763788` | `aws+production@panicboat.net` |
> | develop | `270242382571` | `aws+develop@panicboat.net` |
>
> - 両アカウントとも `SUCCEEDED`。プラスアドレスの衝突は起きなかった
> - `OrganizationAccountAccessRole` の assume を両方で確認済
> - Identity Center の `AdministratorAccess` を 3 アカウント全てに割当済
> - Task 1.2 Step 2 の実測値は On-Demand / Spot ともに **5.0**（設計の予測どおり AWS デフォルト）。増枠 2 件を申請し `PENDING`
> - **Task 1.2 Step 5 のコンソール操作は不要だった。** Bedrock のモデルアクセスは新アカウントで既に有効（`authorizationStatus: AUTHORIZED` / `entitlementAvailability: AVAILABLE` / `agreementAvailability: NOT_AVAILABLE` = 同意取得不要）。手順を修正済

### Task 1.1: メンバーアカウント 2 つを作成

**Files:** なし

**Interfaces:**
- Produces: `337169763788` と `270242382571`。以降の全タスクが依存する

- [x] **Step 1: 既存アカウント一覧を確認**

```bash
aws organizations list-accounts --query 'Accounts[].{Id:Id,Name:Name,Email:Email,State:State}' --output table
```

Expected: `583677814390`（CLOSED）、`504150922582`（CLOSED）、`559744160976`（ACTIVE）

- [x] **Step 2: `aws@panicboat.net` が受信できることを確認**

`panicboat.net` は Google Workspace（MX = `smtp.google.com`）で、プラスアドレスはベースのメールボックスへ配送される。`aws@panicboat.net` がユーザーまたはエイリアスとして存在しないと、ルートアカウントの検証メールとパスワードリセットが届かずアカウントを復旧できなくなる。

```bash
dig +short MX panicboat.net
```

Expected: `1 smtp.google.com.`

Google Workspace 管理コンソール（Directory → Users、または該当ユーザーの Alternate email addresses）で `aws@panicboat.net` の存在を確認する。無ければエイリアスを作成し、外部から `aws+production@panicboat.net` 宛にテストメールを送って受信できることを確かめてから次へ進む。

- [x] **Step 3: production アカウントを作成**

クローズ済みアカウントが保持しているのは `admin@panicboat.net` と `aws@dystopia.city` で、いずれも下記とは別アドレス。

```bash
aws organizations create-account \
  --email 'aws+production@panicboat.net' \
  --account-name 'production' \
  --iam-user-access-to-billing DENY
```

Expected: `CreateAccountStatus.State` が `IN_PROGRESS`

- [x] **Step 4: develop アカウントを作成**

```bash
aws organizations create-account \
  --email 'aws+develop@panicboat.net' \
  --account-name 'develop' \
  --iam-user-access-to-billing DENY
```

- [x] **Step 5: 両方の完了とアカウント ID を確認**

```bash
aws organizations list-create-account-status --states SUCCEEDED FAILED \
  --query 'CreateAccountStatuses[?AccountName==`production`||AccountName==`develop`].{Name:AccountName,Id:AccountId,State:State,Reason:FailureReason}' \
  --output table
```

Expected: 両方 `SUCCEEDED` で `AccountId` が返る。この 2 値を `337169763788` / `270242382571` として記録する。`EMAIL_ALREADY_EXISTS` で失敗した場合は別のプラスアドレス（例: `aws+prod2@panicboat.net`）で再試行する

- [x] **Step 6: 両アカウントで `OrganizationAccountAccessRole` を assume できることを確認**

```bash
for acct in 337169763788 270242382571; do
  aws sts assume-role \
    --role-arn "arn:aws:iam::${acct}:role/OrganizationAccountAccessRole" \
    --role-session-name bootstrap-check \
    --query 'AssumedRoleUser.Arn' --output text
done
```

Expected: 2 行とも `arn:aws:sts::<acct>:assumed-role/OrganizationAccountAccessRole/bootstrap-check`

- [x] **Step 7: Identity Center の AdministratorAccess を両アカウントに割当**

```bash
for acct in 337169763788 270242382571; do
  aws sso-admin create-account-assignment \
    --instance-arn arn:aws:sso:::instance/ssoins-7758e2d4fb37f3a7 \
    --permission-set-arn arn:aws:sso:::permissionSet/ssoins-7758e2d4fb37f3a7/ps-77583734ef962d6b \
    --principal-type USER \
    --principal-id e7146ab8-20b1-70eb-a63d-b9887df5d7a6 \
    --target-id "$acct" \
    --target-type AWS_ACCOUNT \
    --region ap-northeast-1
done
```

- [x] **Step 8: 割当を確認**

```bash
aws sso-admin list-accounts-for-provisioned-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-7758e2d4fb37f3a7 \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-7758e2d4fb37f3a7/ps-77583734ef962d6b \
  --region ap-northeast-1
```

Expected: `AccountIds` に 3 件（管理 + production + develop）

### Task 1.2: Service Quota 増枠申請と Bedrock 有効化

増枠の承認待ちが本移行で最長のクリティカルパスになるため、アカウント作成直後に投げる。EKS が乗るのは production だけなので production アカウントのみ対象。

**Files:** なし

- [x] **Step 1: production アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::337169763788:role/OrganizationAccountAccessRole \
  --role-session-name quota-request --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `337169763788`

- [x] **Step 2: 現在値を確認**

```bash
for qc in L-1216C47A L-34B43A08; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code $qc \
    --region ap-northeast-1 --query 'Quota.{Name:QuotaName,Value:Value}' --output json
done
```

Expected: いずれも `5.0`（AWS デフォルト）

- [x] **Step 3: 増枠を申請**

管理アカウントの適用値（On-Demand 64 / Spot 256）に合わせる。

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A --desired-value 64 --region ap-northeast-1
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-34B43A08 --desired-value 256 --region ap-northeast-1
```

- [x] **Step 4: 申請が受理されたことを確認**

```bash
aws service-quotas list-requested-service-quota-change-history --region ap-northeast-1 \
  --query 'RequestedQuotas[].{Q:QuotaName,V:DesiredValue,S:Status}' --output table
```

Expected: 2 件が `PENDING` または `CASE_OPENED`

- [x] **Step 5: Bedrock のモデルアクセス状態を確認**

Anthropic の Claude モデルは同意取得が不要になっており、新アカウントでも既定でアクセス可能。コンソールでのアクセスリクエストは不要（2026-08-20 実測）。

```bash
for m in anthropic.claude-sonnet-4-6 anthropic.claude-opus-4-6-v1; do
  aws bedrock get-foundation-model-availability --model-id "$m" --region us-east-1 \
    --query '{model:modelId,agreement:agreementAvailability.status,auth:authorizationStatus,entitlement:entitlementAvailability}' --output json
done
```

Expected: `authorizationStatus: AUTHORIZED` かつ `entitlementAvailability: AVAILABLE`。`agreementAvailability: NOT_AVAILABLE` は「同意取得の仕組み自体が無い」= 不要という意味で、異常ではない。`auth` が `NOT_AUTHORIZED` の場合のみ `us-east-1` の Bedrock コンソールでアクセスをリクエストする

- [x] **Step 6: HolmesGPT が使う inference profile が存在することを確認**

`kubernetes/components/holmesgpt/production/values.yaml.gotmpl` の `modelList` は inference profile ID を直接指定する。

```bash
aws bedrock list-inference-profiles --region us-east-1 \
  --query 'inferenceProfileSummaries[?starts_with(inferenceProfileId, `us.anthropic.claude`)].{Id:inferenceProfileId,Status:status}' --output table
```

Expected: `us.anthropic.claude-sonnet-4-6` が `ACTIVE`。`modelList` の `sonnet-5` / `opus-5` は 2026-08-20 時点で quota 0 のため使えない（`aws/eks-holmesgpt` の IAM ポリシーにも含まれていない）。詳細は設計 §1「既存の不整合」参照

---

# Phase 2: State Backend Bootstrap

> **実行記録（2026-08-20 完了、PR #809）**
>
> - Task 2.1 / 4.2 / 4.3 の `terragrunt backend bootstrap` は `--non-interactive` が必須（既定では bucket 作成の y/N プロンプトで停止する）
> - Task 3.5 の `terragrunt backend migrate` は**移行元ディレクトリが存在している必要がある**。先に `git mv` すると `src unit not found` で失敗するため、コピーで並存させてから移行し、あとで旧ディレクトリを削除する
> - `terragrunt backend migrate` は移行先へのコピーだけでなく**旧 state の削除まで行う**。plan の「旧 state を削除」ステップは不要だった
> - Task 3.6 の policy に **`route53:ListTagsForResource` が必要**だった。`data.aws_route53_zone` は zone 解決の一環でタグを読むため、無いと Task 5.1 の plan が 403 になる
> - Task 3.1 の apply で OIDC provider の thumbprint が更新される（`22ff8958...` → `ab9d0263...`）。`data.tls_certificate.github` の再計算による既存ドリフトで、AWS は当該 IdP の thumbprint を検証しないため影響なしと判断（REASONED）
> - `github/repository` に `allow_forking = true -> false` の既存ドリフトあり。env 移設とは無関係

### Task 2.1: 両新アカウントに state バケットとロックテーブルを作る

全 `root.hcl` が `bucket = "terragrunt-state-${get_aws_account_id()}"` で組むため、コード変更は不要。

**Files:** なし

**Interfaces:**
- Consumes: Task 1.1 の `337169763788` / `270242382571`
- Produces: 両アカウントの `terragrunt-state-<ID>` バケットと `terragrunt-state-locks` テーブル

- [x] **Step 1: production アカウントで bootstrap**

`vpc` は依存が無く最も軽い。Task 1.2 Step 1 の認証情報がまだ有効ならそのまま使う。

```bash
cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt backend bootstrap
```

Expected: S3 バケットと DynamoDB テーブルが作成される旨のログ

- [x] **Step 2: production の backend を確認**

```bash
aws s3api head-bucket --bucket terragrunt-state-337169763788
aws s3api get-bucket-versioning --bucket terragrunt-state-337169763788
aws dynamodb describe-table --table-name terragrunt-state-locks --region ap-northeast-1 \
  --query 'Table.KeySchema' --output json
```

Expected: バケットが存在し versioning が `Enabled`、HASH キーが `LockID`

- [x] **Step 3: develop アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::270242382571:role/OrganizationAccountAccessRole \
  --role-session-name terragrunt-bootstrap --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `270242382571`

- [x] **Step 4: develop アカウントで bootstrap**

develop env を持つ唯一のスタックが `github-oidc-auth`。

```bash
cd aws/github-oidc-auth/envs/develop && TG_TF_PATH=tofu terragrunt backend bootstrap
```

- [x] **Step 5: develop の backend を確認**

```bash
aws s3api head-bucket --bucket terragrunt-state-270242382571
aws dynamodb describe-table --table-name terragrunt-state-locks --region ap-northeast-1 \
  --query 'Table.KeySchema' --output json
```

Expected: バケットとテーブルが存在する

---

# Phase 3: `master` Env 新設

管理アカウントに残る資産を `master` に集約する。ここからは管理アカウントの認証情報（`panicboat` IAM ユーザー）で作業する。

### Task 3.1: `master` env の GitHub OIDC を立て、既存 provider を引き取る

`aws_iam_openid_connect_provider` は 1 アカウント 1 つ。現在は `develop` env が管理しているが、develop はアカウントごと移動するため `master` が引き取る。削除して作り直すと `master` のロール trust が一時的に壊れるので import する。

**Files:**
- Create: `aws/github-oidc-auth/envs/master/env.hcl`
- Create: `aws/github-oidc-auth/envs/master/terragrunt.hcl`

**Interfaces:**
- Produces: `github-oidc-auth-master-github-actions-{plan,apply}-role` と、`master` state が所有する OIDC provider。Task 3.2 の `workflow-config.yaml` が参照する

- [x] **Step 1: 管理アカウントの認証情報であることを確認**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text
```

Expected: `arn:aws:iam::559744160976:user/panicboat`

- [x] **Step 2: `env.hcl` を作成**

```hcl
# env.hcl - Master environment configuration
#
# master = 管理アカウント (= 559744160976) に残る横断資産の env。
# production / develop を専用アカウントへ分離したあと、Route53 hosted zone・
# GitHub 設定・支払アカウント単位の cost-management がここに集まる。
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

  # OIDC provider は develop env が作成したものを本 env が import で引き取る
  # (= develop はアカウントごと移動するため、管理アカウントの provider を
  #    誰も管理しない状態になるのを避ける)。
  create_oidc_provider = true
  oidc_provider_arn    = ""

  # Session duration (4 hours, production と同水準)
  max_session_duration = 14400

  additional_tags = {
    Component = "github-oidc-auth"
    Owner     = "panicboat"
  }
}
```

- [x] **Step 3: `terragrunt.hcl` を作成**

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

- [x] **Step 4: `develop` state から provider を外す**

二重管理を作らないため、import より先に実行する。

```bash
cd aws/github-oidc-auth/envs/develop
TG_TF_PATH=tofu terragrunt state rm 'aws_iam_openid_connect_provider.github[0]'
```

Expected: `Successfully removed 1 resource instance(s).`

- [x] **Step 5: `master` state へ provider を import**

```bash
cd aws/github-oidc-auth/envs/master
TG_TF_PATH=tofu terragrunt init
TG_TF_PATH=tofu terragrunt import 'aws_iam_openid_connect_provider.github[0]' \
  arn:aws:iam::559744160976:oidc-provider/token.actions.githubusercontent.com
```

Expected: `Import successful!`

- [x] **Step 6: plan で provider が再作成されないことを確認**

```bash
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `aws_iam_openid_connect_provider.github[0]` に `create` や `replace` が出ず、追加は plan / apply role・policy・attachment 3・log group のみ。tag の in-place update は許容

- [x] **Step 7: apply**

```bash
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [x] **Step 8: provider とロールを確認**

```bash
aws iam list-open-id-connect-providers
aws iam get-role --role-name github-oidc-auth-master-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-master-github-actions-apply-role --query 'Role.Arn' --output text
```

Expected: provider が 1 件のまま（重複作成されていない）、両ロールの ARN が返る

- [x] **Step 9: コミット**

```bash
git add aws/github-oidc-auth/envs/master/
git commit -s -m "feat(aws/github-oidc-auth): add master environment and adopt the shared OIDC provider"
```

### Task 3.2: `workflow-config.yaml` に `master` env を追加

`panicboat/deploy-actions/label-resolver` は `workflow-config.yaml` の `environments:` を読んで `aws/{service}/envs/{environment}/` と `github/{service}/envs/{environment}/` を解決する（`docs/superpowers/specs/2026-04-26-environment-naming-design.md` 参照）。`master` を宣言しないと Task 3.3-3.5 で移すスタックが CI から見えない。

**Files:**
- Modify: `workflow-config.yaml`

- [x] **Step 1: `master` env を `environments:` の先頭に追加**

```yaml
  - environment: master
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-plan-role
        iam_role_apply: arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-apply-role
```

- [x] **Step 2: YAML として妥当か確認**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('workflow-config.yaml')); print([e['environment'] for e in d['environments']])"
```

Expected: `['master', 'develop', 'production']`

- [x] **Step 3: コミット**

```bash
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): declare master environment"
```

### Task 3.3: `aws/route53` を `master` へ re-home

hosted zone は管理アカウントの資産なので env 帰属を移す。state key が変わるため `terragrunt backend migrate` を伴う（resources=8 の実 state あり）。

**Files:**
- Create: `aws/route53/envs/master/env.hcl`
- Create: `aws/route53/envs/master/terragrunt.hcl`
- Delete: `aws/route53/envs/production/`

**Interfaces:**
- Consumes: Task 3.2 の `master` env 宣言
- Produces: `platform/route53/master/terraform.tfstate`。Task 3.6 が同スタックに追記する

- [x] **Step 1: 移行前の state を確認**

```bash
cd aws/route53/envs/production && TG_TF_PATH=tofu terragrunt state list
```

Expected: 6 個の `aws_route53_record` と 2 個の `module.route53.data.aws_route53_zone`

- [x] **Step 2: `env.hcl` を作成**

```hcl
# env.hcl - Environment-specific configuration for master

locals {
  # Environment-specific settings
  environment = "master"

  # AWS configuration
  aws_region = "ap-northeast-1"

  # production アカウント (= route53-zone-access を assume する側)。
  # Task 1.1 で確定した値に置き換えること。
  production_account_id = "337169763788"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "route53"
    Owner       = "panicboat"
  }
}
```

- [x] **Step 3: `terragrunt.hcl` を作成**

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

- [x] **Step 4: state を移行**

```bash
terragrunt backend migrate aws/route53/envs/production aws/route53/envs/master
```

- [x] **Step 5: 移行先 state を確認**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt state list
```

Expected: Step 1 と同じ 8 エントリ

- [x] **Step 6: 差分を確認**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: レコードの再作成が無いこと。`Environment` タグの develop→master 変更に伴う in-place update は許容

- [x] **Step 7: 旧 env と旧 state を削除**

```bash
git rm -r aws/route53/envs/production
aws s3 rm s3://terragrunt-state-559744160976/platform/route53/production/terraform.tfstate
```

- [x] **Step 8: コミット**

```bash
git add aws/route53/envs/master/
git commit -s -m "refactor(aws/route53): re-home stack from production to master environment"
```

### Task 3.4: `aws/cost-management` を `master` へ re-home

Compute Optimizer と Cost Optimization Hub の登録は支払アカウント単位。develop がアカウントごと移動しても、この登録は管理アカウントに残す必要がある。

**Files:**
- Create: `aws/cost-management/envs/master/env.hcl`
- Create: `aws/cost-management/envs/master/terragrunt.hcl`
- Delete: `aws/cost-management/envs/develop/`

- [x] **Step 1: 移行前の state を確認**

```bash
cd aws/cost-management/envs/develop && TG_TF_PATH=tofu terragrunt state list
```

Expected: `aws_computeoptimizer_enrollment_status.this` と `aws_costoptimizationhub_enrollment_status.this` の 2 件（後者は #801 で `terraform_data` + `local-exec` の回避策から置き換え済）

- [x] **Step 2: `env.hcl` を作成**

module 側が `us-east-1` に固定しているため `aws_region` は現状を踏襲する。

```hcl
# env.hcl - Environment-specific configuration for master

locals {
  # Environment-specific settings
  environment = "master"

  # AWS configuration (Cost Optimization Hub / Compute Optimizer home region)
  aws_region = "us-east-1"

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Component   = "cost-management"
    Owner       = "panicboat"
  }
}
```

- [x] **Step 3: `terragrunt.hcl` を作成**

develop 版との差分は先頭コメントの env 名のみ（`aws_region` は module が `us-east-1` に固定するため渡していない）。

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

# Reference to Terraform modules
terraform {
  source = "../../modules"
}

# Input variables for the module
# aws_region is intentionally not passed; the module pins region to us-east-1.
inputs = {
  environment = include.env.locals.environment

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "cost-management"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
```

- [x] **Step 4: state を移行**

```bash
terragrunt backend migrate aws/cost-management/envs/develop aws/cost-management/envs/master
```

- [x] **Step 5: 差分を確認**

```bash
cd aws/cost-management/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `aws_computeoptimizer_enrollment_status` と `aws_costoptimizationhub_enrollment_status` のどちらにも再作成が出ないこと。タグの in-place update は許容

`aws_costoptimizationhub_enrollment_status` は `include_member_accounts` が `optional + computed` で、省略時は AWS API の返り値を採用するため差分が出ない（#801 で実 state での `No changes.` を確認済）。差分が出る場合は provider のバージョンが上がって挙動が変わっている可能性があるため、apply せずに調査する

- [x] **Step 6: 旧 env と旧 state を削除**

```bash
git rm -r aws/cost-management/envs/develop
aws s3 rm s3://terragrunt-state-559744160976/platform/cost-management/develop/terraform.tfstate
```

- [x] **Step 7: コミット**

```bash
git add aws/cost-management/envs/master/
git commit -s -m "refactor(aws/cost-management): re-home stack to master environment"
```

### Task 3.5: `github/repository` と `github/branch` を `master` へ re-home

GitHub リポジトリと ruleset は環境を持たない組織横断資産。付随する CloudWatch ログ グループも管理アカウントに残る。

**Files:**
- Move: `github/repository/envs/develop/` → `github/repository/envs/master/`
- Move: `github/branch/envs/develop/` → `github/branch/envs/master/`

- [x] **Step 1: 移行前の state を確認**

```bash
cd github/repository/envs/develop && TG_TF_PATH=tofu terragrunt state list
cd ../../../branch/envs/develop && TG_TF_PATH=tofu terragrunt state list
```

Expected: repository 側は `aws_cloudwatch_log_group.github_repository_logs` / `github_repository.repository` / `github_workflow_repository_permissions.repository` の 3 件、branch 側は `data.github_repository.repo` / `github_repository_ruleset.branches` の 2 件

- [x] **Step 2: ディレクトリを `git mv` で移動**

per-repo の `.hcl` ファイル（`monorepo.hcl` 等）も一緒に移す。

```bash
git mv github/repository/envs/develop github/repository/envs/master
git mv github/branch/envs/develop github/branch/envs/master
ls github/repository/envs/master/ github/branch/envs/master/
```

Expected: repository 側に 7 ファイル（`terragrunt.hcl` + repo 別 6 本）、branch 側に 5 ファイル（`terragrunt.hcl` + `defaults.hcl` + repo 別 3 本）

- [x] **Step 3: ハードコードされた `develop` が無いことを確認**

env 名は `root.hcl` がディレクトリパスから導出するため、移動だけで切り替わるはず。

```bash
grep -rn "develop" github/repository/envs/master/ github/branch/envs/master/
```

Expected: 出力なし。あれば `master` に書き換える

- [x] **Step 4: `GITHUB_TOKEN` を設定して state を移行**

両スタックとも `get_env("GITHUB_TOKEN")` を読むため、未設定だと terragrunt が評価時に失敗する。

```bash
export GITHUB_TOKEN=$(gh auth token)
terragrunt backend migrate github/repository/envs/develop github/repository/envs/master
terragrunt backend migrate github/branch/envs/develop github/branch/envs/master
```

- [x] **Step 5: 差分を確認**

```bash
cd github/repository/envs/master && TG_TF_PATH=tofu terragrunt plan
cd ../../../branch/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: GitHub リポジトリ・ruleset・ログ グループの再作成や削除が無いこと。ログ グループの `Environment` タグ in-place update は許容

- [x] **Step 6: 旧 state を削除**

```bash
aws s3 rm s3://terragrunt-state-559744160976/platform/repository/develop/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/branch/develop/terraform.tfstate
```

- [x] **Step 7: コミット**

```bash
git add github/
git commit -s -m "refactor(github): re-home repository and branch stacks to master environment"
```

### Task 3.6: `route53-zone-access` ロールを作る

production アカウントから管理アカウントの hosted zone を操作するためのロール。信頼先は production アカウント root 1 つで、実際に誰が assume できるかは production 側の IAM で制御する（設計 §4 参照）。

**Files:**
- Create: `aws/route53/modules/zone_access.tf`
- Modify: `aws/route53/modules/variables.tf`

**Interfaces:**
- Consumes: Task 3.3 の `production_account_id` input
- Produces: `arn:aws:iam::559744160976:role/route53-zone-access`。Task 4.2 の `assume_role_arns`、Task 5.1 の provider alias、Task 5.2 の external-dns IAM、Task 5.3 の helm 値が参照する

- [x] **Step 1: `variables.tf` に変数を追加**

`aws/route53/modules/variables.tf` の末尾に追記する。

```hcl
variable "production_account_id" {
  description = "AWS account ID of the production account allowed to assume route53-zone-access"
  type        = string
}
```

- [x] **Step 2: `zone_access.tf` を作成**

```hcl
# zone_access.tf - Cross-account role that lets the production account manage
# records in the hosted zones owned by this (= management) account.
#
# Why a root principal instead of listing individual role ARNs: IAM rejects a
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

- [x] **Step 3: fmt と validate**

```bash
tofu fmt -recursive aws/route53/
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt validate
```

Expected: fmt が差分を出さず、validate が成功

- [x] **Step 4: plan で追加内容を確認**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `aws_iam_role.zone_access` と `aws_iam_role_policy.zone_access` の 2 追加のみ。既存レコード 6 件に変更が出ないこと

- [x] **Step 5: apply**

```bash
cd aws/route53/envs/master && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [x] **Step 6: ロールとポリシーを確認**

```bash
aws iam get-role --role-name route53-zone-access --query 'Role.AssumeRolePolicyDocument' --output json
aws iam get-role-policy --role-name route53-zone-access --policy-name route53-zone-access --output json
```

Expected: trust の Principal が `arn:aws:iam::337169763788:root`、ポリシー 1 つ目の Resource が 2 zone ARN

- [x] **Step 7: コミット**

```bash
git add aws/route53/modules/
git commit -s -m "feat(aws/route53): add cross-account zone access role for production"
```

---

# Phase 4: `develop` / `production` の OIDC ロールと CI 切替

各新アカウントに OIDC provider と plan / apply ロールを作り、CI の向き先を切り替える。**ロールの存在を確認してから `workflow-config.yaml` をマージする。**

### Task 4.1: plan ロールに `sts:AssumeRole` を付与できるようにする

`ReadOnlyAccess` 管理ポリシーには `sts:AssumeRole` が含まれないため、production の plan ロールが `route53-zone-access` を assume できない。

**Files:**
- Modify: `aws/github-oidc-auth/modules/variables.tf`
- Modify: `aws/github-oidc-auth/modules/main.tf`

**Interfaces:**
- Produces: `assume_role_arns` input。Task 4.3 の production env.hcl が値を渡す

- [x] **Step 1: `variables.tf` に変数を追加**

```hcl
variable "assume_role_arns" {
  description = "Cross-account role ARNs the plan role is allowed to assume (apply role already has AdministratorAccess)"
  type        = list(string)
  default     = []
}
```

- [x] **Step 2: `main.tf` にインラインポリシーを追加**

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

- [x] **Step 3: fmt と validate**

```bash
tofu fmt -recursive aws/github-oidc-auth/
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功

- [x] **Step 4: `master` env に差分が出ないことを確認**

デフォルト空リストなので `count = 0` となり影響しないはず。

```bash
cd aws/github-oidc-auth/envs/master && TG_TF_PATH=tofu terragrunt plan
```

Expected: `No changes.`

- [x] **Step 5: コミット**

```bash
git add aws/github-oidc-auth/modules/
git commit -s -m "feat(aws/github-oidc-auth): allow granting cross-account assume to the plan role"
```

### Task 4.2: `develop` の OIDC ロールを新アカウントに作る

`aws/github-oidc-auth/envs/develop/env.hcl` は既に `create_oidc_provider = true` で、アカウントが変わるだけなのでコード変更は不要。

**Files:** なし（既存スタックの apply のみ）

- [x] **Step 1: develop アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::270242382571:role/OrganizationAccountAccessRole \
  --role-session-name oidc-bootstrap --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `270242382571`

- [x] **Step 2: plan**

state は Task 2.1 で bootstrap した新バケットを向くため、全て新規追加になる。

```bash
cd aws/github-oidc-auth/envs/develop && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt plan
```

Expected: OIDC provider / plan role / apply role / state lock policy / attachment 3 / log group が全て新規追加

- [x] **Step 3: apply**

```bash
cd aws/github-oidc-auth/envs/develop && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [x] **Step 4: ロールと provider を確認**

```bash
aws iam list-open-id-connect-providers
aws iam get-role --role-name github-oidc-auth-develop-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-develop-github-actions-apply-role --query 'Role.Arn' --output text
```

Expected: provider が 1 件、両ロールの ARN が `270242382571`

### Task 4.3: `production` の OIDC ロールを新アカウントに作る

**Files:**
- Modify: `aws/github-oidc-auth/envs/production/env.hcl`
- Modify: `aws/github-oidc-auth/envs/production/terragrunt.hcl`

**Interfaces:**
- Consumes: Task 3.6 の `route53-zone-access` ARN、Task 4.1 の `assume_role_arns`
- Produces: 新アカウントの production plan / apply ロール

- [x] **Step 1: `env.hcl` の OIDC provider 設定を反転**

以下 2 行を置き換える。

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
  # 存在しないため自前で作成する (= master / develop も各アカウントで自前作成)。
  create_oidc_provider = true
  oidc_provider_arn    = ""
```

- [x] **Step 2: `env.hcl` に `assume_role_arns` を追加**

`additional_tags` ブロックの直前に追記する。

```hcl
  # Route53 hosted zone は管理アカウント (= 559744160976) に残しているため、
  # plan 時の data.aws_route53_zone 解決に cross-account assume が要る。
  assume_role_arns = [
    "arn:aws:iam::559744160976:role/route53-zone-access",
  ]
```

- [x] **Step 3: `terragrunt.hcl` で input を渡す**

`inputs` ブロックに追記する。

```hcl
  assume_role_arns = include.env.locals.assume_role_arns
```

- [x] **Step 4: production アカウントの認証情報に切り替える**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::337169763788:role/OrganizationAccountAccessRole \
  --role-session-name oidc-bootstrap --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
aws sts get-caller-identity --query Account --output text
```

Expected: `337169763788`

- [x] **Step 5: plan と apply**

```bash
cd aws/github-oidc-auth/envs/production && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt plan
cd aws/github-oidc-auth/envs/production && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

Expected: plan は全て新規追加。apply が成功する

- [x] **Step 6: ロールと assume ポリシーを確認**

```bash
aws iam get-role --role-name github-oidc-auth-production-github-actions-plan-role --query 'Role.Arn' --output text
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role --query 'Role.Arn' --output text
aws iam get-role-policy --role-name github-oidc-auth-production-github-actions-plan-role \
  --policy-name cross-account-assume --output json
```

Expected: 両ロールの ARN が `337169763788`、assume ポリシーの Resource が `route53-zone-access` ARN

- [x] **Step 7: クロスアカウント assume の疎通を確認**

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::559744160976:role/route53-zone-access \
  --role-session-name migration-check \
  --query 'AssumedRoleUser.Arn' --output text
```

Expected: `arn:aws:sts::559744160976:assumed-role/route53-zone-access/migration-check`

- [x] **Step 8: コミット**

```bash
git add aws/github-oidc-auth/envs/production/
git commit -s -m "feat(aws/github-oidc-auth): provision production OIDC in its dedicated account"
```

### Task 4.4: `workflow-config.yaml` の `develop` / `production` を差し替える

**Files:**
- Modify: `workflow-config.yaml`

- [x] **Step 1: 両アカウントのロールが存在することを再確認**

差し替え前の必須ゲート。ここを飛ばして先にマージすると CI が存在しないロールを assume して壊れる。

```bash
for acct in 270242382571 337169763788; do
  CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::${acct}:role/OrganizationAccountAccessRole" \
    --role-session-name verify --query Credentials --output json)
  AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId) \
  AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey) \
  AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken) \
    aws iam list-roles --query 'Roles[?starts_with(RoleName, `github-oidc-auth-`)].RoleName' --output text
done
```

Expected: develop アカウントで develop の 2 ロール、production アカウントで production の 2 ロールが返る

- [x] **Step 2: `develop` と `production` の ARN を差し替え**

```yaml
  - environment: develop
    stacks:
      terragrunt:
        aws_region: us-east-1
        iam_role_plan: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-plan-role
        iam_role_apply: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-apply-role

  - environment: production
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-plan-role
        iam_role_apply: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-apply-role
```

- [x] **Step 3: 3 env が正しいアカウントを向いていることを確認**

```bash
python3 - <<'EOF'
import yaml
d = yaml.safe_load(open('workflow-config.yaml'))
for e in d['environments']:
    tg = e.get('stacks', {}).get('terragrunt', {})
    print(e['environment'], tg.get('aws_region'), tg.get('iam_role_apply'))
EOF
```

Expected: `master` が `559744160976`、`develop` が `270242382571`、`production` が `337169763788`

- [x] **Step 4: コミット**

```bash
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): point develop and production at their dedicated accounts"
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
- Consumes: Task 3.6 の `route53-zone-access` ARN
- Produces: `var.route53_zone_role_arn`（`aws/alb` 内）

- [x] **Step 1: `variables.tf` に変数を追加**

```hcl
variable "route53_zone_role_arn" {
  description = "Role in the management account assumed to read/write the hosted zones"
  type        = string
}
```

- [x] **Step 2: `terraform.tf` に alias provider を追加**

既存 `provider "aws"` ブロックの直後に追記する。

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

- [x] **Step 3: `lookups.tf` で provider を差し替え**

ファイル全体を以下に置き換える。

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

- [x] **Step 4: validation レコードに provider を指定**

`aws/alb/modules/main.tf` の `aws_route53_record.wildcard_panicboat_net_validation` と `aws_route53_record.wildcard_dystopia_city_validation` の両方に、`for_each` の直前へ 1 行追加する。

```hcl
  provider = aws.route53
```

ACM 証明書（`aws_acm_certificate`）と検証待ち（`aws_acm_certificate_validation`）は production アカウント側のリソースなので default provider のまま。

- [x] **Step 5: `env.hcl` に ARN を追加**

`environment_tags` ブロックの直前に追記する。

```hcl
  # 管理アカウント (= 559744160976) の hosted zone を操作するための assume 先。
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
```

- [x] **Step 6: `terragrunt.hcl` で input を渡す**

`inputs` ブロック、`aws_region` の次の行に追記する。

```hcl
  route53_zone_role_arn = include.env.locals.route53_zone_role_arn
```

- [x] **Step 7: fmt と validate**

```bash
tofu fmt -recursive aws/alb/
cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功

- [x] **Step 8: plan で zone が解決できることを確認**

production アカウントの認証情報で実行する。

```bash
cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt plan
```

Expected: `data.aws_route53_zone` の解決に成功し、ACM 証明書 2 枚と validation レコードの新規作成が計画される。`Invalid provider configuration` や `no matching Route53Zone found` が出ないこと

- [x] **Step 9: コミット**

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
- Consumes: Task 3.6 の `route53-zone-access` ARN
- Produces: `eks-production-external-dns` ロールが `sts:AssumeRole` を持つ。Task 5.3 の helm 値と対になる

- [x] **Step 1: `module.route53` の参照箇所が 1 つだけであることを再確認**

```bash
grep -rn "module\.route53" aws/eks/modules/
```

Expected: `addons.tf` の 2 行（`panicboat_net.arn` / `dystopia_city.arn`）のみ

- [x] **Step 2: `variables.tf` に変数を追加**

```hcl
variable "route53_zone_role_arn" {
  description = "Role in the management account that external-dns assumes to manage hosted zone records"
  type        = string
}
```

- [x] **Step 3: `addons.tf` の external-dns IRSA を差し替え**

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

- [x] **Step 4: `lookups.tf` から route53 lookup を削除**

ファイル全体を以下に置き換える。

```hcl
# lookups.tf - External stack lookups for the EKS cluster.

module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}
```

- [x] **Step 5: `env.hcl` に ARN を追加**

`environment_tags` ブロックの直前に追記する。

```hcl
  # external-dns が管理アカウント (= 559744160976) の hosted zone を操作するための assume 先。
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
```

- [x] **Step 6: `terragrunt.hcl` で input を渡す**

`inputs` ブロックに追記する。

```hcl
  route53_zone_role_arn = include.env.locals.route53_zone_role_arn
```

- [x] **Step 7: fmt と validate**

```bash
tofu fmt -recursive aws/eks/
cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade && TG_TF_PATH=tofu terragrunt validate
```

Expected: 成功。`module.route53` への未解決参照が残っていればここで落ちる

- [x] **Step 8: コミット**

```bash
git add aws/eks/
git commit -s -m "feat(aws/eks): grant external-dns cross-account assume instead of zone-scoped Route53"
```

### Task 5.3: external-dns に `--aws-assume-role` を設定

**Files:**
- Modify: `kubernetes/components/external-dns/production/values.yaml.gotmpl`

**Interfaces:**
- Consumes: Task 5.2 の IRSA ロール、Task 3.6 の `route53-zone-access`

- [x] **Step 1: `extraArgs` セクションを追加**

`txtOwnerId` ブロックと `serviceAccount` ブロックの間に挿入する。

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

- [x] **Step 2: helmfile が template できることを確認**

```bash
helmfile -e production -f kubernetes/components/external-dns/production/helmfile.yaml template \
  | grep -- "--aws-assume-role"
```

Expected: `--aws-assume-role=arn:aws:iam::559744160976:role/route53-zone-access` が出力される

- [x] **Step 3: コミット**

```bash
git add kubernetes/components/external-dns/production/values.yaml.gotmpl
git commit -s -m "feat(external-dns): assume the management-account role for Route53"
```

---

# Phase 6: 共有リソースの再作成

### Task 6.1: service-linked role と Secrets Manager を production アカウントに作る

**Files:** なし（既存スタックの apply と手動投入）

**Interfaces:**
- Consumes: Task 0.4 の退避ファイル `$HOME/.secrets-backup-559744160976.json`

- [x] **Step 1: production アカウントの認証情報で `iam-service-linked-roles` を apply**

```bash
cd aws/iam-service-linked-roles/envs/production && TG_TF_PATH=tofu terragrunt init && TG_TF_PATH=tofu terragrunt apply -auto-approve
```

- [x] **Step 2: service-linked role を確認**

```bash
aws iam get-role --role-name AWSServiceRoleForEC2Spot --query 'Role.Arn' --output text
```

Expected: `arn:aws:iam::337169763788:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot`

- [x] **Step 3: platform 管理外の secret 6 件を作成**

`panicboat/holmes/{slack,alertmanager}` は monorepo が管理するため Task 8.1 で扱う。

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

- [x] **Step 4: 退避した値を投入**

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

- [x] **Step 5: 投入結果を確認**

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
- Modify: `kubernetes/components/{aws-load-balancer-controller,external-dns,loki,mimir,tempo}/production/helmfile.yaml`

- [ ] **Step 1: 差し替え対象を列挙**

```bash
grep -rn "559744160976" kubernetes/helmfile.yaml.gotmpl kubernetes/components/
```

Expected: 12 行（親 5 + 子 6 + Task 5.3 で追加した `--aws-assume-role` 1）

- [ ] **Step 2: 一括置換**

`values.yaml.gotmpl` の `--aws-assume-role` は**管理アカウント ID のまま残す**必要があるため除外する。

```bash
grep -rl "559744160976" kubernetes/helmfile.yaml.gotmpl kubernetes/components/ \
  | grep -v 'external-dns/production/values.yaml.gotmpl' \
  | xargs sed -i '' 's/559744160976/337169763788/g'
```

- [ ] **Step 3: 置換結果を検証**

```bash
grep -rn "559744160976" kubernetes/helmfile.yaml.gotmpl kubernetes/components/
grep -rn "337169763788" kubernetes/helmfile.yaml.gotmpl kubernetes/components/ | wc -l
```

Expected: 1 つ目は `external-dns/production/values.yaml.gotmpl` の `--aws-assume-role` 行 1 本のみ。2 つ目は 11

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

既存の recreate runbook を実行する。本タスクは runbook を呼び出す薄いラッパで、runbook 内の手順を複製しない。

**Files:**
- Modify: `docs/runbooks/eks-production-recreate.md`

- [ ] **Step 1: Service Quota の増枠が承認済みか確認**

未承認なら Karpenter がノードを 1 台も出せずに詰むため、ここが本 Phase のゲート。

```bash
for qc in L-1216C47A L-34B43A08; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code $qc \
    --region ap-northeast-1 --query 'Quota.{Name:QuotaName,Value:Value}' --output json
done
```

Expected: On-Demand が 64 以上、Spot が 256 以上

- [ ] **Step 2: runbook の前提記述を更新**

`docs/runbooks/eks-production-recreate.md` の 2.2 節と Phase 0 に `arn:aws:iam::559744160976:user/panicboat` がハードコードされている。production はアカウントが変わったため置き換える。

2.2 節の operator environment 記述:

```
- production アカウント (= `337169763788`) の AdministratorAccess 相当の principal
  (= IAM Identity Center の AdministratorAccess、または管理アカウントから
  `OrganizationAccountAccessRole` を assume した session)
```

Phase 0 の期待値コメント `# → arn:aws:iam::559744160976:user/panicboat` は、`aws sts get-caller-identity --query Account --output text` が `337169763788` を返すことを確認する記述に変える。

- [ ] **Step 3: runbook の Phase 1-10 を実行**

Phase 7 の残りスタック apply には `eks-holmesgpt` が含まれていないため、`eks-secrets eks-logs eks-metrics eks-traces` の後に追加で apply する。

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

**Files（monorepo リポジトリ）:**
- Modify: `workflow-config.yaml`

**Interfaces:**
- Consumes: Task 2.1 の state バケット、Task 4.3 の production ロール、Task 0.4 の退避ファイル

- [ ] **Step 1: 現状の state を確認**

```bash
aws s3 ls s3://terragrunt-state-559744160976/services/ --recursive
aws s3 ls s3://terragrunt-state-559744160976/system-components/ --recursive
```

Expected: `services/monolith/production`、`services/nginx-app/develop`、`system-components/holmes/production` の 3 件

- [ ] **Step 2: production アカウントの認証情報で holmes スタックを apply**

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

- [ ] **Step 5: monorepo の `workflow-config.yaml` を更新**

現状 `develop` のみ宣言され、production スタックは手動 apply 運用になっている。develop もアカウントが変わるため両方書く。

```yaml
environments:
  - environment: develop
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-plan-role
        iam_role_apply: arn:aws:iam::270242382571:role/github-oidc-auth-develop-github-actions-apply-role

  - environment: production
    stacks:
      terragrunt:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-plan-role
        iam_role_apply: arn:aws:iam::337169763788:role/github-oidc-auth-production-github-actions-apply-role
```

- [ ] **Step 6: 新アカウントの state を確認**

```bash
aws s3 ls s3://terragrunt-state-337169763788/ --recursive
```

Expected: `services/monolith/production` と `system-components/holmes/production` が存在する

- [ ] **Step 7: コミット（monorepo リポジトリ）**

```bash
cd ../monorepo
git add workflow-config.yaml
git commit -s -m "feat(workflow-config): point stacks at the dedicated AWS accounts"
```

---

# Phase 9: 旧アカウントの後片付け

### Task 9.1: 管理アカウントから production / develop の IAM 資産を除去

**Files:** なし

- [ ] **Step 1: 管理アカウントの認証情報に戻す**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text
```

Expected: `arn:aws:iam::559744160976:user/panicboat`

- [ ] **Step 2: 削除対象が旧アカウント側であることを確認**

Task 4.2 / 4.3 でスタックは新アカウントを向いているため、`terragrunt destroy` を打つと新アカウント側が消える。旧アカウント側は AWS API で直接削除する。

```bash
aws iam list-roles --query 'Roles[?starts_with(RoleName, `github-oidc-auth-`)].Arn' --output text | tr '\t' '\n'
```

Expected: `arn:aws:iam::559744160976:role/github-oidc-auth-{develop,production,master}-github-actions-{plan,apply}-role` の 6 本

- [ ] **Step 3: develop と production のロール・ポリシー・ログ グループを削除**

`master` の 2 本は残す。

```bash
for env in develop production; do
  aws iam detach-role-policy --role-name "github-oidc-auth-${env}-github-actions-apply-role" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  aws iam detach-role-policy --role-name "github-oidc-auth-${env}-github-actions-plan-role" \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
  aws iam detach-role-policy --role-name "github-oidc-auth-${env}-github-actions-plan-role" \
    --policy-arn "arn:aws:iam::559744160976:policy/github-oidc-auth-${env}-terragrunt-state-lock"
  aws iam delete-role --role-name "github-oidc-auth-${env}-github-actions-apply-role"
  aws iam delete-role --role-name "github-oidc-auth-${env}-github-actions-plan-role"
  aws iam delete-policy --policy-arn "arn:aws:iam::559744160976:policy/github-oidc-auth-${env}-terragrunt-state-lock"
  aws logs delete-log-group --region ap-northeast-1 --log-group-name "/github-actions/github-oidc-auth-${env}"
done
```

- [ ] **Step 4: 残存ロールを確認**

```bash
aws iam list-roles --query 'Roles[?!contains(Path, `aws-service-role`)].RoleName' --output text | tr '\t' '\n'
```

Expected: `AWSReservedSSO_AdministratorAccess_*`、`github-oidc-auth-master-github-actions-{plan,apply}-role`、`route53-zone-access` の 4 つ

### Task 9.2: 旧 state と旧 secret を削除

**Files:** なし

- [ ] **Step 1: production / develop の旧 state を削除**

`platform/{route53,cost-management,repository,branch}` は Phase 3 で `master` へ移行済。

```bash
for key in alb eks eks-holmesgpt eks-logs eks-metrics eks-secrets eks-traces github-oidc-auth iam-service-linked-roles karpenter vpc; do
  aws s3 rm "s3://terragrunt-state-559744160976/platform/${key}/production/terraform.tfstate"
done
aws s3 rm s3://terragrunt-state-559744160976/platform/github-oidc-auth/develop/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/services/monolith/production/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/system-components/holmes/production/terraform.tfstate
```

- [ ] **Step 2: 孤児 state を削除**

対応する env ディレクトリを持たないもの。`platform/github-repository/{monorepo,platform}` は `github_repository` を `platform/repository/master` と二重管理しており、`github_branch_protection` は GitHub 上に存在しない（3 リポジトリとも 404、現在の保護は ruleset）。

```bash
aws s3 rm s3://terragrunt-state-559744160976/platform/ai-assistant/develop/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/claude-code/develop/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/claude-code-action/develop/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/github-oidc-auth/staging/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/github-repository/monorepo/terraform.tfstate
aws s3 rm s3://terragrunt-state-559744160976/platform/github-repository/platform/terraform.tfstate
```

- [ ] **Step 3: 旧 secret を削除**

新アカウントへの投入完了（Task 6.1 Step 5 と Task 8.1 Step 3）を確認してから実行する。

```bash
for name in $(aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text); do
  aws secretsmanager delete-secret --region ap-northeast-1 --secret-id "$name" --force-delete-without-recovery
done
```

- [ ] **Step 4: 管理アカウントに残った state を確認**

```bash
aws s3 ls s3://terragrunt-state-559744160976/ --recursive
```

Expected: `platform/{branch,cost-management,github-oidc-auth,repository,route53}/master/terraform.tfstate` の 5 件と `services/nginx-app/develop/terraform.tfstate` のみ

### Task 9.3: README を更新して PR を出す

**Files:**
- Modify: `README.md`
- Modify: `README-ja.md`

- [ ] **Step 1: 環境表を 3 アカウント構成に更新**

`README.md` の「Environments and authentication」節と `README-ja.md` の対応箇所に以下を反映する。

- `master` = 管理アカウント `559744160976`。Route53 hosted zone、GitHub リポジトリ / ruleset、cost-management を持つ
- `develop` = 専用アカウント。現時点では `aws/github-oidc-auth` のみ
- `production` = 専用アカウント。EKS 一式
- Route53 hosted zone は `master` に残り、production からは `route53-zone-access` を assume して操作する

- [ ] **Step 2: 差分を確認**

```bash
git diff README.md README-ja.md
```

Expected: 環境表と認証まわりの記述のみが変わっている

- [ ] **Step 3: コミット**

```bash
git add README.md README-ja.md
git commit -s -m "docs: describe the three-account layout"
```

- [ ] **Step 4: PR を更新**

```bash
git push
gh pr view --json isDraft,title --jq '{draft: .isDraft, title: .title}'
```

Expected: Draft のまま。レビュー依頼は Verification Checklist を全て満たしてから

---

## Verification Checklist

- [ ] `aws organizations list-accounts` に ACTIVE なアカウントが 3 件（管理 + production + develop）
- [ ] `aws iam list-open-id-connect-providers` が 3 アカウントそれぞれで 1 件を返す
- [ ] `terragrunt-state-337169763788` と `terragrunt-state-270242382571` が存在する
- [ ] 管理アカウントの state バケットに残るのが `platform/*/master/` 5 件と `services/nginx-app/develop` のみ
- [ ] 新 production アカウントから `route53-zone-access` を assume できる
- [ ] `aws eks list-clusters --region ap-northeast-1` が新 production アカウントで `eks-production` を返す
- [ ] `*.panicboat.net` / `*.dystopia.city` の ACM 証明書が新 production アカウントで `ISSUED`
- [ ] external-dns が管理アカウントの zone にレコードを作成できている
- [ ] `git grep -n 559744160976 -- kubernetes/ workflow-config.yaml` の結果が、`master` env の ARN 2 本と external-dns の `--aws-assume-role` 1 本だけ
- [ ] GitHub の ruleset 3 本が `active` のまま（`gh api repos/panicboat/{monorepo,platform,deploy-actions}/rulesets`）
- [ ] 管理アカウントの Secrets Manager が空
- [ ] `aws iam list-instance-profiles` が空
- [ ] `master` env の CI が plan を通せる（`GITHUB_TOKEN` の供給経路が機能している）
