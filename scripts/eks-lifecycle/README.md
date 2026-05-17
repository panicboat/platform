# EKS Lifecycle

Temporary teardown of `eks-production` cluster + 周辺 AWS stacks. 手元 shell から実行する想定 (= CI 経由 trigger は未対応)。

詳細設計: `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`

Recreate (= cluster bootstrap) は manual runbook で実行する: `docs/runbooks/eks-production-recreate.md`

## Prerequisites

- **操作者の IAM principal** が以下を満たすこと:
  - terragrunt destroy に必要な AWS 操作権限を default credential chain で利用可能 (= 例: panicboat IAM user は `AdministratorAccess` 保持)。GitHub OIDC apply role (= `github-oidc-auth-${ENV}-github-actions-apply-role`) は `sts:AssumeRoleWithWebIdentity` のみ trust で IAM user からは assume 不可、operator 自身の credentials で直接 terragrunt を実行する
  - `eks-admin-${ENV}` role を `sts:AssumeRole` で assume 可能 (= 同 role の trust policy は IAM root を許可、AWS 上で account 内任意の IAM principal が `sts:AssumeRole` 権限保持していれば成立)
- 手元に installed: `tofu`, `terragrunt`, `kubectl`, `jq`, `aws`, `make`, `bash`
- repo root から `make` を実行する (= `Makefile` がある場所)
- **対話型 terminal で実行**: `confirm` プロンプトが stdin から `y` を読むため、CI / pipe / nohup 経由などの非対話実行ではプロンプトで EOF となり `set -e` で即終了する

## Pre-flight checks

teardown 開始前に以下を確認:

```bash
# 1. AWS env をリセット (= eks-login 等で assumed-role creds が export されている状態を解除)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# 2. operator identity (= 期待する IAM user / role か)
aws sts get-caller-identity
# → user/panicboat (= 操作者本人の IAM principal) が出ること。
# assumed-role/eks-admin-production/... のままだと、 eks-admin は EC2 / VPC
# describe 権限を持たないため後段 (= 40-orphan-verify.sh の aws ec2 describe-*)
# が UnauthorizedOperation で fail する。

# 3. cluster 接続性
kubectl config current-context
kubectl get nodes
```

## Usage

### Teardown (= cluster + 周辺 stacks を削除)

```bash
# Dry-run (= AWS / kubectl コマンドを echo のみ、実行しない)
DRY_RUN=1 make eks-teardown ENV=production

# Live run
make eks-teardown ENV=production
```

実行内容:

1. `10-k8s-cleanup.sh`: kubectl delete ingress / LB svc / Karpenter NodePool、ノード drain 待機
2. `30-destroy-stacks.sh`: 「8 stack を destroy するか」y/N 確認 → 8 stacks を固定順で `terragrunt destroy` (= karpenter → eks-secrets → eks-logs/metrics/traces → eks → alb → vpc)
3. `40-orphan-verify.sh`: ENI / EBS / target group / SG / Route53 record / CloudWatch log group の orphan 検出 (= 削除はしない、人間に diagnostic 提示)

部分実行:

```bash
make eks-teardown-k8s ENV=production       # k8s cleanup only
make eks-teardown-aws ENV=production       # terragrunt destroy only
make eks-teardown-verify ENV=production    # orphan verify only
```

### Recreate

`docs/runbooks/eks-production-recreate.md` を参照。 cilium native CNI との chicken-and-egg があり、 operator が 2 terminal 並行で sequentially bootstrap する manual runbook で実行する。

## Failure handling

- 各 step は **fail fast** (= 即 exit 1)、診断メッセージで「次に何を打つべきか」を提示
- partial state からの再 run は idempotent: `make eks-teardown` は何度叩いても安全
- ロールバックは前進復旧のみ (= teardown 中断は再 teardown)
- admin role 一時 credentials の expire (= 1h STS session) は `30-destroy-stacks.sh` の各 stack 開始時に `creds_expiring_soon` (< 5min) で検出して `00-auth.sh` を re-source、admin role を assume し直す
- `40-orphan-verify.sh` は read-only verify で auto-delete しない (= false-positive 含み得る出力を operator が目視精査し、必要なら提示された AWS CLI コマンドで個別削除)。検出時の exit code は live run = 1 (= operator 注意喚起 + make chain 停止)、DRY_RUN=1 = 0 (= live cluster の現役 resource を warn として列挙、make chain は継続)
- `terragrunt destroy` で `Module version requirements have changed` (= 既存 `.terragrunt-cache/` の module version と現行 main.tf の constraint が乖離) のエラーが出たら、対象 stack を `terragrunt init -upgrade` で更新してから再開する。 8 stack 一括は以下:
  ```bash
  for stack in karpenter eks-secrets eks-logs eks-metrics eks-traces eks alb vpc; do
    echo "=== init: $stack ==="
    ( cd aws/$stack/envs/production && TG_TF_PATH=tofu terragrunt init -upgrade )
  done
  make eks-teardown-aws ENV=production   # 中断地点から再開、 fail fast 後の再 run は idempotent
  ```
  発生例: Renovate PR で `terraform-aws-modules/eks/aws` を `~> 21.20` に更新済みだが、 操作者の `.terragrunt-cache/` には v21.19.0 がキャッシュされているケース

## What is preserved through teardown

- AWS Secrets Manager service の secret 値 (= terragrunt 管理外で手動管理)
- `aws/route53` (= panicboat.net hosted zone)
- `aws/github-oidc-auth` / `ai-assistant` / `cost-management` (= EKS 非依存)
- terragrunt remote state (= S3 + DynamoDB)

## What is destroyed

- `aws/eks`, `aws/karpenter`, `aws/eks-secrets`, `aws/eks-logs`, `aws/eks-metrics`, `aws/eks-traces` (= EKS 専用)
- `aws/alb` (= ACM wildcard cert *.panicboat.net、recreate 時は DNS validation 5〜10 分)
- `aws/vpc` (= NAT gateway 含む)
