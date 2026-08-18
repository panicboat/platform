# Production AWS Account Migration Design

`production` 環境を、現在の AWS アカウント `559744160976`（= AWS Organizations の管理アカウント）から専用のメンバーアカウントへ分離する。

## 1. Background

### 現状のアカウント構成

`559744160976` は Organization `o-es9qoj85gw`（FeatureSet `ALL`）の管理アカウントであり、同時に `develop` と `production` の両環境が同居している。環境分離はリソース命名と IAM ロール名のプレフィックスだけで担保されており、アカウント境界による分離が無い。

IAM Identity Center インスタンス `ssoins-7758e2d4fb37f3a7`（primary region `ap-northeast-1`）も同アカウントが保有する。permission set は `AdministratorAccess` 1 つのみで、`559744160976` に対してユーザー `me@panicboat.net` が割当済。

過去に 2 回メンバーアカウントを作成して両方クローズしている。

| Account | Name | 作成 | 状態 |
|---|---|---|---|
| 583677814390 | Production (`admin@panicboat.net`) | 2026-08-05 | SUSPENDED / CLOSED |
| 504150922582 | dystopia (`aws@dystopia.city`) | 2026-08-18 | SUSPENDED / CLOSED |

Support プランは Basic（Premium Support 未契約）。

### 現状の稼働リソース

`ap-northeast-1` に EKS クラスタ・VPC・EC2・NAT Gateway・EIP・ELBv2・Security Group・Launch Template はいずれも存在しない（デフォルト VPC も無い）。ACM は `ap-northeast-1` / `us-east-1` ともに 0 件、ECR・KMS CMK・SNS・SQS も 0 件。EKS スタック群は teardown 済で、移行対象は基盤リソースと state に限られる。

state は 26 ファイル中 11 ファイルにのみ resources が入っている。`production` 系で実体があるのは以下の 4 つ。

| state key | resources | 内容 |
|---|---|---|
| `platform/route53/production` | 8 | MX / TXT / DKIM レコード 6 + zone data 2 |
| `platform/eks-holmesgpt/production` | 7 | IAM role + inline policy + Pod Identity Association |
| `platform/github-oidc-auth/production` | 9 | plan / apply role + policy + log group |
| `platform/iam-service-linked-roles/production` | 1 | `AWSServiceRoleForEC2Spot` |

`eks` / `vpc` / `alb` / `eks-logs` / `eks-metrics` / `eks-traces` / `eks-secrets` / `karpenter` は resources=0 の空 state。

残存する実リソースは以下。

- S3: `terragrunt-state-559744160976`（`ap-northeast-1`、versioning 有効、SSE-KMS `alias/aws/s3`、public access block 全 true、Terragrunt 自動生成の `EnforcedTLS` + `RootAccess` バケットポリシー）、`panicboat-attached-storage`（Terraform 管理外・platform 無関係）
- DynamoDB: `terragrunt-state-locks`（`ap-northeast-1`、HASH=`LockID`、PAY_PER_REQUEST）
- IAM: OIDC provider 1、ロール 5（`github-oidc-auth-{develop,production}-github-actions-{plan,apply}-role` + `eks-production-holmesgpt`）、カスタマー管理ポリシー 2、IAM ユーザー `panicboat`（AdministratorAccess）
- Secrets Manager（`ap-northeast-1`）8 件: `panicboat/{oauth2-proxy/google, grafana/admin, github-app/panicboat, keycloak/admin, holmes/slack, holmes/alertmanager, holmes/github, alertmanager/slack-notify}`
- Route53: hosted zone 3 本（`panicboat.net` = `Z07598371GKBU0WMF89MD`、`dystopia.city` = `Z03420722KS9MTSCUSIQZ`、`nyx.place` = `Z05920991VJAPXQE581DN`）+ Route53 Registrar 登録ドメイン 3 件
- CloudWatch Logs: `ap-northeast-1` 10 本、`us-east-1` 1 本

### Service Quota の乖離

`ap-northeast-1` の増枠申請履歴は空だが、適用値は AWS 側の自動調整で新規アカウントのデフォルトから乖離している。新アカウントはデフォルト値から始まるため、Karpenter が worker node を出す前に増枠が必要になる。

| Quota | 現アカウント適用値 | AWS デフォルト値 |
|---|---|---|
| Running On-Demand Standard vCPU | 64 | 5 |
| All Standard Spot Instance Requests | 256 | 5 |
| EC2-VPC Elastic IPs | 5 | 5 |
| VPCs per Region | 5 | 5 |

`us-east-1` では Bedrock の Sonnet 5 / Opus 5 増枠申請 4 件がいずれも `CASE_CLOSED`（未取得）。

### 既存の不整合

- `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS` 配列（8 スタック）に `eks-holmesgpt` が含まれていない。#795 でスタック分離した際に追加漏れとなり、`eks-production-holmesgpt` ロールが teardown 後も残存している。`platform/eks-holmesgpt/production` state は存在しないクラスタを `data.aws_eks_cluster.this` で参照しており、現状 plan が data source 解決で失敗する
- IAM instance profile `eks-production_513473553642647435`（Roles 空）が孤児として残存。Karpenter が生成した Terraform 管理外リソース
- state に対応の無いログ グループ 3 本: `/github-repository/generated-manifests`、`/github-repository/kubernetes-clusters`、`us-east-1` の `/github-actions/claude-code-action-monorepo`
- `dystopia.city` zone に削除済み ALB を指す ALIAS レコード 4 件（`dystopia.city.` A/AAAA、`auth.dystopia.city.` A/AAAA）と external-dns 所有権 TXT 2 件（`aaaa-auth.` / `cname-auth.`、`owner=eks-production`）が残存

## 2. Decisions

| 論点 | 決定 | 理由 |
|---|---|---|
| 新アカウントの位置づけ | 同 Organization のメンバーとして新規作成 | `OrganizationAccountAccessRole` が自動生成され bootstrap 経路が確保できる。請求も管理アカウントに集約される |
| Route53 hosted zone | 管理アカウントに残し、クロスアカウント参照にする | NS 切替に伴う DNS 断と Google Workspace の MX / DKIM 再検証を回避する |
| 管理アカウント側の横断資産の env 名 | `master` を新設 | `production` でも `develop` でもない「管理アカウントに残る横断資産」を表す env が必要 |

クローズ済みアカウントのメールアドレス（`admin@panicboat.net` / `aws@dystopia.city`）は再利用できない前提で、新しいアドレスを用意する。

## 3. Environment Taxonomy

| env | アカウント | region | 対象スタック |
|---|---|---|---|
| `master`（新設） | 559744160976（管理） | `ap-northeast-1` | `aws/route53`、`aws/github-oidc-auth` |
| `develop` | 559744160976（管理） | `us-east-1` | `github/repository`、`github/branch`、`aws/cost-management`、`aws/github-oidc-auth` |
| `production` | 新アカウント | `ap-northeast-1` | `aws/{vpc,alb,eks,eks-karpenter,eks-secrets,eks-logs,eks-metrics,eks-traces,eks-holmesgpt,iam-service-linked-roles}`、`aws/github-oidc-auth` |

`develop` は管理アカウントに残るが、既存の GitHub / cost-management スタックを `master` へ寄せるのは state 移行を伴う別作業のため本設計の対象外とする（§9 参照）。

`master` env は `aws/github-oidc-auth/envs/master` で専用の plan / apply ロールを持つ。OIDC provider は `develop` が管理する既存のもの（`arn:aws:iam::559744160976:oidc-provider/token.actions.githubusercontent.com`）を再利用するため `create_oidc_provider = false`。

対して `production` env は新アカウントに provider が存在しないため、`aws/github-oidc-auth/envs/production/env.hcl` を `create_oidc_provider = true` に反転する。

## 4. Cross-account Route53 Architecture

### 依存の実体

Route53 hosted zone を参照しているのは 3 箇所のみ（cert-manager は self-signed ClusterIssuer のみで DNS01 を使わない）。

1. `aws/alb/modules/main.tf` — ACM ワイルドカード証明書（`*.panicboat.net` / `*.dystopia.city`）の DNS validation レコードを zone に書き込む
2. `aws/eks/modules/addons.tf:53-70` — external-dns IRSA ロールに zone ARN スコープの Route53 権限を付与する
3. external-dns（実行時） — Ingress / Service の hostname から Route53 レコードを作成する

1 と 2 はいずれも `aws/route53/lookup` の `data "aws_route53_zone"`（名前引き）に依存する。data source は実行中の認証情報のアカウント内しか解決できないため、zone を管理アカウントに残す以上、両者に管理アカウントへの assume role 経路が要る。

### 管理アカウント側のロール

`aws/route53`（`master` env）が `route53-zone-access` ロールを 1 本作る。

**権限**

| Action | Resource |
|---|---|
| `route53:ChangeResourceRecordSets`, `route53:ListResourceRecordSets`, `route53:GetHostedZone` | `Z07598371GKBU0WMF89MD` / `Z03420722KS9MTSCUSIQZ` の 2 zone ARN |
| `route53:ListHostedZones`, `route53:ListHostedZonesByName`, `route53:GetChange` | `*`（zone 名引きと変更伝播待ちに必要。zone 単位に絞れない API） |

**信頼するプリンシパル**

`arn:aws:iam::<PROD_ACCOUNT_ID>:root` の 1 つ。実際に誰が assume できるかは production アカウント側の IAM で制御する。

| production 側のプリンシパル | assume 許可の出どころ |
|---|---|
| `github-oidc-auth-production-github-actions-plan-role` | `aws/github-oidc-auth` が付与するインラインポリシー（`ReadOnlyAccess` に `sts:AssumeRole` は含まれないため明示付与が必要） |
| `github-oidc-auth-production-github-actions-apply-role` | `AdministratorAccess` |
| `eks-production-external-dns` | `aws/eks/modules/addons.tf` の `source_policy_documents` |
| `OrganizationAccountAccessRole` | `AdministratorAccess` |

**個別ロール ARN ではなく root を信頼する理由:** IAM は trust policy に存在しないロール ARN を書くと `MalformedPolicyDocument` で拒否する。`eks-production-external-dns` は Phase 7 の EKS apply まで存在せず、`github-oidc-auth-production-*` も Phase 4 まで存在しないため、個別 ARN を列挙すると zone access ロールの作成順序が最後尾に固定され、Phase 5 の疎通確認より後ろになってしまう。root 信頼にすれば新アカウント ID が確定した時点で作成でき、順序依存が消える。信頼先アカウントは自分たちが完全に管理下に置いているため、委譲先を production アカウントの IAM に寄せる標準パターンで問題ない。

**read / write を 1 本にまとめた理由（= なぜ reader / writer に分けないか）**

Terraform の provider alias は静的な設定であり、plan と apply で assume 先を切り替える手段が現構成に無い（terragrunt inputs は env 単位で固定、CI executor は外部リポジトリ `panicboat/panicboat-actions/terragrunt-run`）。分離するには plan / apply で異なる `TF_VAR` を注入する仕組みが必要になり、コストに見合わない。

トレードオフとして、plan ロールが Route53 の 2 zone に限って書き込み可能なロールを assume できるようになる。`terragrunt plan` が `ChangeResourceRecordSets` を呼ぶことはないため実害は無いが、plan ロールの read-only 保証がこの範囲で緩む点は認識しておく。

加えて、`ReadOnlyAccess` 管理ポリシーには `sts:AssumeRole` が含まれないため、`aws/github-oidc-auth` の plan ロールに assume 許可のインラインポリシーを追加する必要がある。

### Terraform 側の配線

`aws/route53/lookup` は provider を宣言せず呼び出し側の default provider を継承する作りになっている（`aws/route53/lookup/terraform.tf` にコメント明記）。この性質をそのまま利用し、**呼び出し側で `providers = { aws = aws.route53 }` を渡して default provider を差し替える**。`configuration_aliases` の追加は不要で、`aws/route53/lookup` は無変更のまま。

```
aws/alb/modules/terraform.tf
  provider "aws" { alias = "route53"; region = var.aws_region
                   assume_role { role_arn = var.route53_zone_role_arn } }

aws/alb/modules/lookups.tf
  module "route53" { providers = { aws = aws.route53 } }

aws/alb/modules/main.tf
  aws_route53_record.*_validation に provider = aws.route53
```

**`aws/eks` は provider alias 不要。** `module.route53` の参照は `addons.tf:60-61` の `external_dns_hosted_zone_arns` 1 箇所だけで（`grep -rn "module\.route53" aws/eks/modules/` で確認済）、external-dns を assume role 方式に切り替えると zone ARN が不要になる。`aws/eks/modules/lookups.tf` から `module "route53"` ブロックごと削除する。

`aws/route53`（`master` env）自身は管理アカウントで動くため alias 不要。default provider のまま `../lookup` を呼ぶ。

`var.route53_zone_role_arn` は決定論的な値（`arn:aws:iam::559744160976:role/route53-zone-access`）なので、`aws/alb/envs/production/env.hcl` に定数として置く。

### external-dns 側の配線

external-dns chart 1.21.1（appVersion 0.21.0）の `extraArgs` に `--aws-assume-role` を渡す。

```yaml
extraArgs:
  - --aws-assume-role=arn:aws:iam::559744160976:role/route53-zone-access
```

IRSA ロール側は Route53 権限を持たず `sts:AssumeRole` のみを持つ。`terraform-aws-modules/iam//modules/iam-role-for-service-accounts` v6 は `source_policy_documents` にポリシードキュメントを渡すと `create_policy` が真になりインラインポリシーを生成するため、`attach_external_dns_policy` / `external_dns_hosted_zone_arns` を外して `source_policy_documents` に差し替える。

## 5. Files Changed

### 新規作成

- `aws/github-oidc-auth/envs/master/{env.hcl,terragrunt.hcl}` — `master` env の plan / apply ロール
- `aws/route53/envs/master/{env.hcl,terragrunt.hcl}` — `production` からの re-home 先
- `aws/route53/modules/zone_access.tf` — `route53-zone-access` ロールとポリシー

### 変更

| ファイル | 内容 |
|---|---|
| `workflow-config.yaml` | `master` env を追加。`production` の `iam_role_plan` / `iam_role_apply` を新アカウント ARN に差し替え |
| `aws/github-oidc-auth/envs/production/env.hcl:22-23` | `create_oidc_provider = true`、`oidc_provider_arn = ""` |
| `aws/github-oidc-auth/modules/main.tf` | plan ロールへ `sts:AssumeRole` インラインポリシーを追加（対象 ARN は変数化） |
| `aws/github-oidc-auth/modules/variables.tf` | `assume_role_arns` 変数を追加 |
| `aws/route53/modules/variables.tf` | `production_account_id` 変数を追加（zone access ロールの信頼先） |
| `aws/alb/modules/terraform.tf` | `provider "aws"` の alias `route53` を追加 |
| `aws/alb/modules/lookups.tf` | `module "route53"` に `providers = { aws = aws.route53 }` を渡す |
| `aws/alb/modules/main.tf` | validation レコード 2 resource に `provider = aws.route53` |
| `aws/alb/modules/variables.tf` / `envs/production/env.hcl` / `envs/production/terragrunt.hcl` | `route53_zone_role_arn` |
| `aws/eks/modules/lookups.tf` | `module "route53"` ブロックを削除 |
| `aws/eks/modules/addons.tf:53-70` | `attach_external_dns_policy` / `external_dns_hosted_zone_arns` を `source_policy_documents` に差し替え |
| `kubernetes/components/external-dns/production/values.yaml.gotmpl` | `extraArgs` に `--aws-assume-role` |
| `kubernetes/components/external-dns/production/helmfile.yaml` | `externalDnsRoleArn` のアカウント ID |
| `kubernetes/helmfile.yaml.gotmpl:43,45,57,64,69` | ロール ARN 2 + バケット名 3 のアカウント ID |
| `kubernetes/components/{aws-load-balancer-controller,loki,mimir,tempo}/production/helmfile.yaml` | 同上（helmfile v1.4 は親 → 子の値継承をしないため二重定義） |
| `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` | `STACKS` に `eks-holmesgpt` を追加 |
| `README.md` / `README-ja.md` | 環境表に `master` を追加 |

### 別リポジトリ（`panicboat/monorepo`）

- `system-components/holmes/terragrunt` — Secrets Manager 2 件を新アカウントで再作成し、値を手動再投入
- `services/monolith/terragrunt` — resources=0 のため state を新規作成するのみ
- `workflow-config.yaml` — `production` env が未定義（手動 apply 運用）。追加するかは実装時に判断

## 6. Migration Sequence

順序の制約は 2 つ。

1. **`workflow-config.yaml` の `production` ロール ARN 差し替えは、新アカウントに state バケットと OIDC ロールが揃った後**。先に main へマージすると CI の production plan / apply が存在しないロールを assume して壊れる
2. **`route53-zone-access` ロールの作成は、`aws/alb` / `aws/eks` の apply より前**。trust policy に production 側の役割 ARN を書くため、新アカウント ID の確定が前提

| Phase | 内容 | 実行場所 |
|---|---|---|
| 0 | 旧アカウントの事前整理（`eks-holmesgpt` destroy、孤児リソース削除、stale DNS レコード削除） | 管理アカウント |
| 1 | 新アカウント作成、Identity Center 割当、**Service Quota 増枠申請**、Bedrock モデルアクセス有効化 | 管理アカウント → 新アカウント |
| 2 | `OrganizationAccountAccessRole` assume → `terragrunt backend bootstrap` で S3 + DynamoDB 作成 | ローカル |
| 3 | `master` env 新設 + `aws/route53` re-home + `route53-zone-access` ロール作成 | 管理アカウント |
| 4 | `github-oidc-auth/production` をローカル apply → `workflow-config.yaml` 差し替え | ローカル → CI |
| 5 | クロスアカウント配線のコード変更（provider alias / external-dns） | コードのみ |
| 6 | `iam-service-linked-roles` apply + Secrets Manager 8 件の再作成と値投入 | 新アカウント |
| 7 | helmfile のアカウント ID 更新 + `docs/runbooks/eks-production-recreate.md` の Phase 1-10 実行 | 新アカウント |
| 8 | monorepo リポジトリの production スタック移行 | 新アカウント |
| 9 | 旧アカウントの production 資産の後片付け | 管理アカウント |

Phase 1 の Service Quota 増枠は承認待ちが最長のクリティカルパスになるため、アカウント作成直後に投げる。

## 7. Risks & Mitigations

### リスク 1: Service Quota 不足で Karpenter が node を出せない

新アカウントの On-Demand / Spot vCPU はデフォルト 5。Phase 7 の EKS 再構築でノードが 1 台も上がらず詰む。

**対策:** Phase 1 で増枠申請を投げ、Phase 7 開始前に `aws service-quotas get-service-quota` で適用値を確認する。承認が下りていなければ Phase 7 を開始しない。

### リスク 2: `workflow-config.yaml` の差し替えタイミングを誤り CI が壊れる

**対策:** Phase 4 で `github-oidc-auth/production` のローカル apply が成功し、新ロールの存在を `aws iam get-role` で確認してから `workflow-config.yaml` を含む PR をマージする。

### リスク 3: クロスアカウント assume が効かず `alb` / `eks` の apply が失敗する

trust policy の ARN 誤記、`sts:AssumeRole` 権限の欠落、provider alias の渡し忘れのいずれでも起きる。

**対策:** Phase 5 完了後、Phase 7 の本番 apply の前に `aws sts assume-role --role-arn arn:aws:iam::559744160976:role/route53-zone-access` を新アカウントの認証情報から実行して疎通を確認する。加えて `aws/alb/envs/production` で `terragrunt plan` を打ち、zone data source が解決できることを確認する。

### リスク 4: クローズ済みアカウントのメールアドレスが再利用できない

`admin@panicboat.net` / `aws@dystopia.city` は closed account が保持している可能性が高い。

**対策:** Phase 1 で新しいアドレスを用意する。`create-account` が `EMAIL_ALREADY_EXISTS` で失敗した場合はアドレスを変えて再試行する。

### リスク 5: `dystopia.city` の stale レコードがクロスアカウント経路の不備を隠す

残存する ALIAS 4 件 + 所有権 TXT 2 件は `policy: sync` + 同一 `txtOwnerId=eks-production` の新クラスタが上がれば自動削除されるはずだが、assume role が効いていなければ削除されない。

**対策:** Phase 0 で手動削除しておき、Phase 7 以降に external-dns が新規レコードを作れることをもって疎通を確認する（削除ではなく作成で検証する）。

### リスク 6: Secrets Manager の値が失われる

8 件の値は Terraform 管理外（手動投入）で、旧アカウントを片付けると復旧できない。

**対策:** Phase 6 の前に旧アカウントから全 8 件の値を取得して安全な場所に退避し、新アカウントへの投入完了を確認してから Phase 9 に進む。

## 8. Validation

### Phase 2 完了時

```bash
aws s3api head-bucket --bucket terragrunt-state-<PROD_ACCOUNT_ID>
aws dynamodb describe-table --table-name terragrunt-state-locks --region ap-northeast-1
```

### Phase 4 完了時

```bash
aws iam get-role --role-name github-oidc-auth-production-github-actions-apply-role
aws iam list-open-id-connect-providers
```

新アカウントで両方が返ること。

### Phase 5 完了時（本番 apply 前）

```bash
# 新アカウントの認証情報で管理アカウントのロールを assume できるか
aws sts assume-role \
  --role-arn arn:aws:iam::559744160976:role/route53-zone-access \
  --role-session-name migration-check

# zone data source が解決できるか
( cd aws/alb/envs/production && TG_TF_PATH=tofu terragrunt plan )
```

### Phase 7 完了時

- `aws eks list-clusters --region ap-northeast-1` で `eks-production` が返る
- external-dns が新アカウントから管理アカウントの zone にレコードを作成できている（Ingress の hostname が `dig` で解決する）
- `aws acm list-certificates --region ap-northeast-1` でワイルドカード証明書 2 枚が `ISSUED`

### Phase 9 完了時

- 旧アカウントに `github-oidc-auth-production-*` ロールが残っていない
- 旧アカウントの `terragrunt-state-559744160976` に `platform/*/production/` の state が残っていない（`master` へ re-home した route53 を除く）

## 9. Out of Scope

- `develop` env（`github/repository`、`github/branch`、`aws/cost-management`）の `master` への統合。管理アカウントに残る点は `master` と同じだが、state key 変更を伴うため別作業とする
- `panicboat-attached-storage` バケットの移行。Terraform 管理外かつ platform と無関係
- `nyx.place` zone とドメイン登録。`aws/route53/lookup` の管理対象外
- Route53 登録ドメイン 3 件のアカウント間移管。zone を管理アカウントに残す決定により不要
- IAM Identity Center の permission set 細分化。`AdministratorAccess` 1 本のまま新アカウントへ割当を追加するのみ
- SCP による新アカウントのガードレール設定
