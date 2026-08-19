# Multi-account Migration Design

`production` と `develop` をそれぞれ専用の AWS アカウントへ分離し、現在の `559744160976`（= AWS Organizations 管理アカウント）は横断資産だけを持つ `master` 環境として残す。

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

state は 26 ファイル中 11 ファイルにのみ resources が入っている。実体があるのは以下。

| state key | resources | 内容 | 移行後の所属 |
|---|---|---|---|
| `platform/route53/production` | 8 | MX / TXT / DKIM レコード 6 + zone data 2 | `master` |
| `platform/repository/develop` | 3 | GitHub repo 6 + log group 6 + workflow permissions 2 | `master` |
| `platform/branch/develop` | 2 | ruleset 3 + repo data 3 | `master` |
| `platform/cost-management/develop` | 2 | Compute Optimizer + Cost Optimization Hub 登録 | `master` |
| `platform/github-oidc-auth/develop` | 10 | OIDC provider + plan / apply role + policy + log group | provider のみ `master`、残りは廃棄 |
| `platform/github-oidc-auth/production` | 9 | plan / apply role + policy + log group | 廃棄（新アカウントで再作成） |
| `platform/eks-holmesgpt/production` | 7 | IAM role + inline policy + Pod Identity Association | 廃棄（ドリフト済、§1 末尾参照） |
| `platform/iam-service-linked-roles/production` | 1 | `AWSServiceRoleForEC2Spot` | 廃棄（新アカウントで再作成） |
| `platform/github-repository/monorepo` | 4 | **レガシー孤児**（§1 末尾参照） | 削除 |
| `platform/github-repository/platform` | 4 | **レガシー孤児**（同上） | 削除 |
| `system-components/holmes/production` | 2 | Secrets Manager 2 件（monorepo 管理） | 新 production アカウント |

`eks` / `vpc` / `alb` / `eks-logs` / `eks-metrics` / `eks-traces` / `eks-secrets` / `karpenter` / `ai-assistant` / `claude-code` / `claude-code-action` / `github-oidc-auth/staging` / `services/monolith/production` は resources=0 の空 state。

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

移行のついでに解消するもの。

- `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS` 配列（8 スタック）に `eks-holmesgpt` が含まれていない。#795 でスタック分離した際の追加漏れで、`eks-production-holmesgpt` ロールが teardown 後も残存している。`platform/eks-holmesgpt/production` state は存在しないクラスタを `data.aws_eks_cluster.this` で参照しており、現状 plan が data source 解決で失敗する
- `platform/github-repository/{monorepo,platform}` state は対応する env ディレクトリを持たないレガシー孤児。`github_repository` を `platform/repository/develop` と二重管理しており、さらに `github_branch_protection` は GitHub 上に既に存在しない（`gh api repos/panicboat/{monorepo,platform,deploy-actions}/branches/main/protection` が全て 404、現在の保護は `platform/branch/develop` が管理する ruleset 3 本）
- IAM instance profile `eks-production_513473553642647435`（Roles 空）が孤児として残存。Karpenter が生成した Terraform 管理外リソース
- state に対応の無いログ グループ 3 本: `/github-repository/generated-manifests`、`/github-repository/kubernetes-clusters`、`us-east-1` の `/github-actions/claude-code-action-monorepo`
- `dystopia.city` zone に削除済み ALB を指す ALIAS レコード 4 件（`dystopia.city.` A/AAAA、`auth.dystopia.city.` A/AAAA）と external-dns 所有権 TXT 2 件（`aaaa-auth.` / `cname-auth.`、`owner=eks-production`）が残存
- `aws/cost-management/modules/cost_optimization_hub.tf` が 2 つの回避策（`terraform_data` + `local-exec` による enrollment、`aws_costoptimizationhub_preferences` の非管理）を抱えているが、どちらも根拠が「非管理アカウントだから」であり、`559744160976` は 2026-08-04 に管理アカウントになっている。**本移行の前に別 PR で解消する**（§10 参照）

## 2. Decisions

| 論点 | 決定 | 理由 |
|---|---|---|
| アカウント分割 | `production` / `develop` をそれぞれ専用メンバーアカウントに分離し、`559744160976` は横断資産のみ保持 | 環境境界をアカウント境界に一致させる |
| 新アカウントの位置づけ | 同 Organization のメンバーとして新規作成 | `OrganizationAccountAccessRole` が自動生成され bootstrap 経路が確保できる。請求も管理アカウントに集約される |
| Route53 hosted zone | 管理アカウントに残し、クロスアカウント参照にする | NS 切替に伴う DNS 断と Google Workspace の MX / DKIM 再検証を回避する |
| 管理アカウントに残る資産の env 名 | `master` を新設 | `production` でも `develop` でもない「横断資産」を表す env が必要 |
| `github/*` スタックの所属 | `master` | GitHub リポジトリ・ruleset は環境を持たない組織横断資産。付随する CloudWatch ログ グループも管理アカウントに残る |
| `aws/cost-management` の所属 | `master` | Compute Optimizer / Cost Optimization Hub の登録は支払アカウント単位。管理アカウントから離せない |

### 新アカウントのルートメールアドレス

| env | アドレス |
|---|---|
| `production` | `aws+production@panicboat.net` |
| `develop` | `aws+develop@panicboat.net` |

クローズ済みアカウントが保持しているのは `admin@panicboat.net`（583677814390）と `aws@dystopia.city`（504150922582）で、いずれも上記とは別アドレスのため衝突しない。

**前提条件:** `panicboat.net` は Google Workspace（MX = `smtp.google.com`）で、プラスアドレスはベースとなるメールボックスへ配送される。したがって `aws@panicboat.net` がユーザーまたはエイリアスとして存在している必要がある。存在しないとルートアカウントの検証メールとパスワードリセットが届かず、アカウントを復旧できなくなる。アカウント作成前に実際に受信できることを確認する。

## 3. Environment Taxonomy

| env | アカウント | workflow-config の region | スタック |
|---|---|---|---|
| `master` | 559744160976（管理） | `ap-northeast-1` | `aws/route53`、`aws/cost-management`、`aws/github-oidc-auth`、`github/repository`、`github/branch` |
| `develop` | 新規（`aws+develop@panicboat.net`） | `us-east-1` | `aws/github-oidc-auth` |
| `production` | 新規（`aws+production@panicboat.net`） | `ap-northeast-1` | `aws/{vpc,alb,eks,eks-karpenter,eks-secrets,eks-logs,eks-metrics,eks-traces,eks-holmesgpt,iam-service-linked-roles,github-oidc-auth}` |

`workflow-config.yaml` の `aws_region` は CI が OIDC ロールを assume する際のリージョンであり、スタック内のリソースリージョンとは独立している（現状も `develop` = `us-east-1` に対し `github/repository/root.hcl` の inputs は `ap-northeast-1` で既に乖離している）。`aws/cost-management` は module 側で `us-east-1` に固定されているため `master` に移しても挙動は変わらない。

移行後の `develop` アカウントは `aws/github-oidc-auth` だけを持つほぼ空のアカウントになる。将来の develop ワークロード（EKS 等）を受け入れる器として先に用意する位置づけ。

### OIDC provider の所有

`aws_iam_openid_connect_provider` は 1 アカウントに 1 つしか作れない。現在は `develop` env が `559744160976` に作ったものを `production` env が ARN 参照で共有している。分離後は 3 アカウントそれぞれが自前で持つ。

| env | `create_oidc_provider` | 備考 |
|---|---|---|
| `master` | `true` | **既存 provider を import する**（新規作成ではない） |
| `develop` | `true` | 新アカウントに新規作成 |
| `production` | `true` | 新アカウントに新規作成 |

`master` が import で引き取る理由: provider は現在 `platform/github-oidc-auth/develop` state が管理しているが、`develop` env はアカウントごと移動する。管理アカウントの provider を誰も管理しない状態を避けるため、`develop` state から `state rm` した上で `master` state へ import する。削除して作り直すと、その間 `master` の plan / apply ロールの trust が壊れる。

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

**個別ロール ARN ではなく root を信頼する理由:** IAM は trust policy に存在しないロール ARN を書くと `MalformedPolicyDocument` で拒否する。`eks-production-external-dns` は EKS apply まで存在せず、`github-oidc-auth-production-*` も production アカウントの bootstrap まで存在しないため、個別 ARN を列挙すると zone access ロールの作成順序が最後尾に固定され、疎通確認より後ろになってしまう。root 信頼にすれば新アカウント ID が確定した時点で作成でき、順序依存が消える。信頼先アカウントは自分たちが完全に管理下に置いているため、委譲先を production アカウントの IAM に寄せる標準パターンで問題ない。

**read / write を 1 本にまとめた理由:** Terraform の provider alias は静的な設定であり、plan と apply で assume 先を切り替える手段が現構成に無い（terragrunt inputs は env 単位で固定、CI executor は外部リポジトリ `panicboat/panicboat-actions/terragrunt-run`）。分離するには plan / apply で異なる `TF_VAR` を注入する仕組みが必要になり、コストに見合わない。トレードオフとして plan ロールが Route53 の 2 zone に限って書き込み可能なロールを assume できるようになるが、`terragrunt plan` が `ChangeResourceRecordSets` を呼ぶことはない。

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

### external-dns 側の配線

external-dns chart 1.21.1（appVersion 0.21.0）の `extraArgs` に `--aws-assume-role` を渡す。

```yaml
extraArgs:
  - --aws-assume-role=arn:aws:iam::559744160976:role/route53-zone-access
```

IRSA ロール側は Route53 権限を持たず `sts:AssumeRole` のみを持つ。`terraform-aws-modules/iam//modules/iam-role-for-service-accounts` v6 は `source_policy_documents` にポリシードキュメントを渡すと `create_policy` が真になりインラインポリシーを生成するため、`attach_external_dns_policy` / `external_dns_hosted_zone_arns` を外して `source_policy_documents` に差し替える。

## 5. Non-IaC Resources

Terraform / Terragrunt の state に入らないため、アカウント分割で自動的には追随しないリソース。移行時は個別に対応する。

### 5-1. AWS — アカウント基盤

| リソース | 現在の所在 | 対応 |
|---|---|---|
| Organization / OU 構成 | 559744160976 | メンバーアカウント 2 つを追加。OU は未使用（root 直下）のまま |
| IAM Identity Center インスタンス | 559744160976（`ap-northeast-1`） | 管理アカウントに残す。`AdministratorAccess` permission set を新 2 アカウントへ割当追加 |
| IAM ユーザー `panicboat` | 559744160976 | 管理アカウントに残す。新アカウントへは Identity Center か `OrganizationAccountAccessRole` でアクセスする（新アカウントに IAM ユーザーは作らない） |
| `OrganizationAccountAccessRole` | 新アカウントに自動生成 | 作成されることを確認するのみ。Terraform 管理下に置かない |
| 支払い手段（payment instrument） | 559744160976 | 管理アカウントに残る。メンバーアカウントは連結請求で自動的に追随 |
| Service Quota 適用値 | 559744160976（On-Demand 64 / Spot 256） | 新 production アカウントで**増枠申請が必要**。デフォルトは 5 |
| Bedrock モデルアクセス | 559744160976（`us-east-1`） | 新 production アカウントでコンソールから有効化が必要 |
| Support プラン | Basic | 変更しない |

### 5-2. AWS — Terragrunt backend

Terragrunt が bootstrap するため、どの state にも入らない。

| リソース | 対応 |
|---|---|
| S3 `terragrunt-state-559744160976` | 管理アカウントに残す（`master` スタックの state 置き場） |
| S3 `terragrunt-state-<PROD_ACCOUNT_ID>` | `terragrunt backend bootstrap` で新規作成 |
| S3 `terragrunt-state-<DEV_ACCOUNT_ID>` | 同上 |
| DynamoDB `terragrunt-state-locks` | 3 アカウントそれぞれに必要（バケットと同時に bootstrap される） |

### 5-3. AWS — シークレットの値

容器（`aws_secretsmanager_secret`）は Terraform 管理だが、**値は手動投入**（`aws/eks-secrets` および monorepo の holmes スタックのコメントに明記）。

| Secret | 管理スタック | 対応 |
|---|---|---|
| `panicboat/oauth2-proxy/google` | なし（手動） | 新 production アカウントで再作成 + 値投入 |
| `panicboat/grafana/admin` | なし（手動） | 同上 |
| `panicboat/github-app/panicboat` | なし（手動） | 同上 |
| `panicboat/keycloak/admin` | なし（手動） | 同上 |
| `panicboat/holmes/github` | なし（手動） | 同上 |
| `panicboat/alertmanager/slack-notify` | なし（手動） | 同上 |
| `panicboat/holmes/slack` | monorepo `system-components/holmes` | スタック apply 後に値投入 |
| `panicboat/holmes/alertmanager` | monorepo `system-components/holmes` | 同上 |

**旧アカウントを片付ける前に全 8 件の値を退避する。** 退避せずに削除すると復旧できない。

### 5-4. AWS — コントローラが実行時に生成するリソース

Terraform 管理外だが、クラスタ再構築で自動的に作り直される。旧アカウント側では孤児として残るため掃除が要る。

| 生成元 | リソース | 対応 |
|---|---|---|
| Karpenter | EC2 インスタンス、launch template、IAM instance profile | 旧アカウントの孤児 instance profile `eks-production_513473553642647435` を削除 |
| AWS Load Balancer Controller | ALB / NLB、自動生成 Security Group | 旧アカウントには残存なし（destroy 時に `30-destroy-stacks.sh` が掃除済） |
| external-dns | Route53 レコード | 管理アカウントの zone に残存。`dystopia.city` の 6 件を削除 |
| EBS CSI Driver | EBS ボリューム | 旧アカウントには残存なし |

### 5-5. GitHub

| リソース | 現在の状態 | 対応 |
|---|---|---|
| GitHub App（App ID `1371999`） | `panicboat` org にインストール | **変更不要。** AWS アカウントに依存しない |
| リポジトリ variable `APP_ID` | `platform` / `monorepo` の両方に設定 | 変更不要 |
| リポジトリ secret `APP_PRIVATE_KEY` | `platform` / `monorepo` の両方に設定 | 変更不要 |
| リポジトリ secret `SLACK_BOT_TOKEN` | `monorepo` のみ | 変更不要 |
| Organization レベルの secret / variable | `gh api orgs/panicboat/actions/{secrets,variables}` が 404（トークンのスコープ不足の可能性あり、**未確認**） | 実装時に org 管理権限のあるトークンで再確認する |
| GitHub Environments | `platform` / `monorepo` ともに **0 件** | `aws/github-oidc-auth` の trust policy が `repo:panicboat/*:environment:{master,develop,production}` を許可条件に含むが、Environment が存在しないためこの条件は現状使われていない。environment gate を使う場合は GitHub 側での作成が別途必要 |
| `GITHUB_TOKEN` 環境変数 | `github/{repository,branch}/envs/*/terragrunt.hcl` が `get_env("GITHUB_TOKEN")` で読む | `master` env に移しても供給経路は変わらない。CI 側で `panicboat/panicboat-actions/terragrunt-run` が `token` input を `GITHUB_TOKEN` として export しているかは**未確認**。`master` env の初回 CI 実行で検証する |
| ruleset 3 本（`{monorepo,platform,deploy-actions}-main`） | `platform/branch/develop` state が管理、GitHub 上で `active` | state を `master` へ移すのみ。GitHub 側の実体は変わらない |
| 旧 branch protection | GitHub 上に**存在しない**（3 リポジトリとも 404） | `platform/github-repository/{monorepo,platform}` state を削除するだけでよい |

### 5-6. 外部 SaaS

| サービス | 用途 | 対応 |
|---|---|---|
| Google Workspace | `panicboat.net` / `dystopia.city` のメール（MX / DKIM / site verification） | **変更不要。** zone を管理アカウントに残す決定により DNS レコードが動かない |
| Google OAuth client | monitoring UIs 4 host の oauth2-proxy 認証（GCP プロジェクト `526108552713`） | redirect URI はホスト名ベースで AWS アカウントに依存しない。**変更不要** |
| Slack App | holmes / Alertmanager 通知 | 変更不要。トークンは Secrets Manager 経由（§5-3） |
| Route53 Registrar 登録ドメイン 3 件 | `panicboat.net`（TransferLock ON）、`dystopia.city`（TransferLock ON）、`nyx.place` | **管理アカウントに残す。** zone を移さない決定によりアカウント間移管は不要 |

## 6. Files Changed

### 新規作成

- `aws/github-oidc-auth/envs/master/{env.hcl,terragrunt.hcl}`
- `aws/route53/envs/master/{env.hcl,terragrunt.hcl}`
- `aws/route53/modules/zone_access.tf`
- `aws/cost-management/envs/master/{env.hcl,terragrunt.hcl}`
- `github/repository/envs/master/*`（`develop` からの `git mv`）
- `github/branch/envs/master/*`（同上）

### 削除

- `aws/route53/envs/production/`
- `aws/cost-management/envs/develop/`
- `github/repository/envs/develop/`、`github/branch/envs/develop/`

### 変更

| ファイル | 内容 |
|---|---|
| `workflow-config.yaml` | `master` env 追加、`develop` / `production` の IAM ロール ARN を各新アカウントへ差し替え |
| `aws/github-oidc-auth/envs/production/env.hcl` | `create_oidc_provider = true` に反転、`oidc_provider_arn = ""`、`assume_role_arns` 追加 |
| `aws/github-oidc-auth/envs/production/terragrunt.hcl` | `assume_role_arns` の受け渡し |
| `aws/github-oidc-auth/modules/{main,variables}.tf` | plan ロールへ `sts:AssumeRole` インラインポリシー（`assume_role_arns` 変数） |
| `aws/route53/modules/variables.tf` | `production_account_id` 追加 |
| `aws/alb/modules/{terraform,lookups,main,variables}.tf` | クロスアカウント provider alias |
| `aws/alb/envs/production/{env.hcl,terragrunt.hcl}` | `route53_zone_role_arn` |
| `aws/eks/modules/{lookups,addons,variables}.tf` | route53 lookup 削除、external-dns を assume role 方式へ |
| `aws/eks/envs/production/{env.hcl,terragrunt.hcl}` | `route53_zone_role_arn` |
| `kubernetes/components/external-dns/production/values.yaml.gotmpl` | `extraArgs` に `--aws-assume-role` |
| `kubernetes/helmfile.yaml.gotmpl` + 子 helmfile 5 本 | アカウント ID 11 箇所 |
| `scripts/eks-lifecycle/lib/30-destroy-stacks.sh` | `STACKS` に `eks-holmesgpt` |
| `README.md` / `README-ja.md` | 環境表に `master` を追加、3 アカウント構成を記載 |

### 変更しないもの

`aws/github-oidc-auth/envs/develop/env.hcl` は既に `create_oidc_provider = true` で、`aws_region` も `us-east-1` のまま使える。develop はアカウントが変わるだけでスタック定義は無変更。差し替えるのは `workflow-config.yaml` のロール ARN のみ。

### 別リポジトリ（`panicboat/monorepo`）

- `system-components/holmes/terragrunt` — Secrets Manager 2 件を新 production アカウントで再作成し値を投入
- `services/monolith/terragrunt` — resources=0 のため state を新規作成するのみ
- `workflow-config.yaml` — `production` env が未定義（手動 apply 運用）。追加するかは実装時に判断

## 7. State Migration Map

`master` へ移すスタックは、アカウントは変わらず state key だけが変わる（`terragrunt backend migrate`）。`develop` / `production` はアカウントごと変わるため、state を移送せず新アカウントで作り直す。

| 現 state key | 移行後 | 方式 |
|---|---|---|
| `platform/route53/production` | `platform/route53/master` | `terragrunt backend migrate` |
| `platform/repository/develop` | `platform/repository/master` | 同上 |
| `platform/branch/develop` | `platform/branch/master` | 同上 |
| `platform/cost-management/develop` | `platform/cost-management/master` | 同上 |
| `platform/github-oidc-auth/develop` | provider のみ `platform/github-oidc-auth/master` へ | `state rm` + `import` |
| `platform/github-oidc-auth/production` | 新 production アカウントで新規作成 | 移送しない |
| `platform/iam-service-linked-roles/production` | 同上 | 移送しない |
| `platform/eks-holmesgpt/production` | 同上 | 移送しない（先にドリフト解消して destroy） |
| `system-components/holmes/production` | 同上 | 移送しない（値は手動退避 → 再投入） |

### 削除する孤児 state

`platform/{ai-assistant,claude-code,claude-code-action}/develop`、`platform/github-oidc-auth/staging`、`platform/karpenter/production`（#798 で `eks-karpenter` に改名済）、`platform/github-repository/{monorepo,platform}`、`services/monolith/production`。

## 8. Migration Sequence

順序の制約は 3 つ。

1. **`workflow-config.yaml` のロール ARN 差し替えは、対象アカウントに state バケットと OIDC ロールが揃った後**。先に main へマージすると CI が存在しないロールを assume して壊れる
2. **OIDC provider の `state rm` → `import` は、`master` env の apply より前**。二重管理を作らない
3. **Secrets Manager の値の退避は、旧アカウントの片付けより前**

| Phase | 内容 | 実行場所 |
|---|---|---|
| 0 | 旧アカウントの事前整理（`eks-holmesgpt` destroy、孤児リソース削除、stale DNS 削除、シークレット値退避） | 管理アカウント |
| 1 | 新アカウント 2 つを作成、Identity Center 割当、**Service Quota 増枠申請**、Bedrock 有効化 | 管理アカウント → 新アカウント |
| 2 | 両新アカウントで `terragrunt backend bootstrap` | ローカル |
| 3 | `master` env 新設（OIDC provider import、`route53` / `cost-management` / `github/*` の re-home、`route53-zone-access` 作成） | 管理アカウント |
| 4 | `develop` / `production` の OIDC ロールをローカル apply → `workflow-config.yaml` 差し替え | ローカル → CI |
| 5 | クロスアカウント配線のコード変更（provider alias / external-dns） | コードのみ |
| 6 | `iam-service-linked-roles` apply + Secrets Manager 再作成と値投入 | 新 production |
| 7 | helmfile のアカウント ID 更新 + `docs/runbooks/eks-production-recreate.md` の Phase 1-10 実行 | 新 production |
| 8 | monorepo リポジトリの production スタック移行 | 新 production |
| 9 | 旧アカウントの production / develop 資産の後片付け | 管理アカウント |

Phase 1 の Service Quota 増枠は承認待ちが最長のクリティカルパスになるため、アカウント作成直後に投げる。

## 9. Risks & Mitigations

### リスク 1: Service Quota 不足で Karpenter が node を出せない

新アカウントの On-Demand / Spot vCPU はデフォルト 5。Phase 7 の EKS 再構築でノードが 1 台も上がらず詰む。

**対策:** Phase 1 で増枠申請を投げ、Phase 7 開始前に `aws service-quotas get-service-quota` で適用値を確認する。承認が下りていなければ Phase 7 を開始しない。

### リスク 2: OIDC provider の二重管理

`master` が import する前に `develop` state を消すと provider が孤児になり、`master` の apply が「作成」を試みて `EntityAlreadyExists` で落ちる。逆に `develop` state に残したまま `master` で import すると 2 つの state が同じリソースを管理する。

**対策:** Phase 3 で `develop` state から `state rm` → `master` state へ `import` → `master` の plan が `No changes.` になることを確認、の順を厳守する。

### リスク 3: `workflow-config.yaml` の差し替えタイミングを誤り CI が壊れる

**対策:** Phase 4 で各アカウントのロール存在を `aws iam get-role` で確認してから `workflow-config.yaml` を含む PR をマージする。

### リスク 4: クロスアカウント assume が効かず `alb` / `eks` の apply が失敗する

trust policy の ARN 誤記、`sts:AssumeRole` 権限の欠落、provider alias の渡し忘れのいずれでも起きる。

**対策:** Phase 5 完了後、Phase 7 の本番 apply の前に新 production アカウントの認証情報から `aws sts assume-role --role-arn arn:aws:iam::559744160976:role/route53-zone-access` を実行して疎通を確認する。加えて `aws/alb/envs/production` で `terragrunt plan` を打ち zone data source が解決できることを確認する。

### リスク 5: `dystopia.city` の stale レコードがクロスアカウント経路の不備を隠す

残存する ALIAS 4 件 + 所有権 TXT 2 件は `policy: sync` + 同一 `txtOwnerId=eks-production` の新クラスタが上がれば自動削除されるはずだが、assume role が効いていなければ削除されない。

**対策:** Phase 0 で手動削除しておき、Phase 7 以降に external-dns が新規レコードを作れることをもって疎通を確認する（削除ではなく作成で検証する）。

### リスク 6: Secrets Manager の値が失われる

8 件の値は Terraform 管理外（手動投入）で、旧アカウントを片付けると復旧できない。

**対策:** Phase 0 で全 8 件の値を退避し、新アカウントへの投入完了を確認してから Phase 9 に進む。

### リスク 7: `GITHUB_TOKEN` が `master` env の CI に供給されない

`github/{repository,branch}` は `get_env("GITHUB_TOKEN")` でトークンを読む。CI executor（外部リポジトリ `panicboat/panicboat-actions/terragrunt-run`）が `token` input をこの環境変数として export しているかは未確認。

**対策:** Phase 3 で `master` env の PR を出した際、CI の plan が通ることをもって確認する。落ちた場合は executor 側の対応か、`master` env の `github/*` を手動 apply 運用に留める。

## 10. Out of Scope

- `panicboat-attached-storage` バケットの移行。Terraform 管理外かつ platform と無関係
- `nyx.place` zone とドメイン登録。`aws/route53/lookup` の管理対象外
- Route53 登録ドメイン 3 件のアカウント間移管。zone を管理アカウントに残す決定により不要
- IAM Identity Center の permission set 細分化。`AdministratorAccess` 1 本のまま新 2 アカウントへ割当を追加するのみ
- SCP による新アカウントのガードレール設定
- `aws/cost-management` の回避策解消と org 横断化。詳細は下記

### `aws/cost-management` の切り分け

3 つの作業が混在しているため、依存関係で分ける。本移行が扱うのは 2 のみ。

| # | 作業 | いつ | 依存 |
|---|---|---|---|
| 1 | 回避策 A / B の解消（native リソース化） | **本移行の前に別 PR** | 無し。単独で検証できる |
| 2 | env を `develop` → `master` へ移す | 本移行（Task 3.4） | 1 が先行していれば差分が env 移動だけになる |
| 3 | org 横断化（`include_member_accounts = true`） | 本移行の完了後 | member アカウントの存在。加えて Organizations の信頼されたサービスアクセス有効化と最大 24 時間の反映待ち |

**1 と 3 は独立している。** `UpdateEnrollmentStatus` API は `includeMemberAccounts` を引数に取るため、現行の `local-exec` に `--include-member-accounts` を足すだけでも 3 は達成できてしまう。それでは回避策の代償（state に載らない・ドリフトを検知しない・destroy で解除されない・AWS CLI への暗黙依存）が残るため、1 を先に片付ける。

3 の前提として、現在 Organizations で有効な信頼されたサービスアクセスは `sso.amazonaws.com` のみ（`aws organizations list-aws-service-access-for-organization` で確認）。`aws cost-optimization-hub list-enrollment-statuses --include-organization-info` は `AccessDeniedException: Service access must be enabled to access member account data` を返す。`compute-optimizer.amazonaws.com` と `cost-optimization-hub.amazonaws.com` の有効化が要る。
- develop アカウントへのワークロード構築。器を用意するところまで
