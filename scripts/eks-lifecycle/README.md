# EKS Lifecycle

Temporary teardown / idempotent recreate of `eks-production` cluster + 周辺 AWS stacks. 手元 shell から実行する想定 (= CI 経由 trigger は未対応)。

詳細設計: `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`

## Prerequisites

- **操作者の IAM principal** が以下を満たすこと:
  - terragrunt apply / destroy に必要な AWS 操作権限を default credential chain で利用可能 (= 例: panicboat IAM user は `AdministratorAccess` 保持)。GitHub OIDC apply role (= `github-oidc-auth-${ENV}-github-actions-apply-role`) は `sts:AssumeRoleWithWebIdentity` のみ trust で IAM user からは assume 不可、operator 自身の credentials で直接 terragrunt を実行する
  - `eks-admin-${ENV}` role を `sts:AssumeRole` で assume 可能 (= 同 role の trust policy は IAM root を許可、AWS 上で account 内任意の IAM principal が `sts:AssumeRole` 権限保持していれば成立)
- 手元に installed: `tofu`, `terragrunt`, `kubectl`, `flux`, `jq`, `aws`, `make`, `bash`
- repo root から `make` を実行する (= `Makefile` がある場所)
- **対話型 terminal で実行**: `confirm` プロンプトが stdin から `y` を読むため、CI / pipe / nohup 経由などの非対話実行ではプロンプトで EOF となり `set -e` で即終了する

## Pre-flight checks

teardown / recreate 開始前に以下を確認:

```bash
# 1. AWS env をリセット (= eks-login 等で assumed-role creds が export されている状態を解除)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# 2. operator identity (= 期待する IAM user / role か)
aws sts get-caller-identity
# → user/panicboat (= 操作者本人の IAM principal) が出ること。
# assumed-role/eks-admin-production/... のままだと、 eks-admin は EC2 / VPC
# describe 権限を持たないため後段 (= 40-orphan-verify.sh の aws ec2 describe-*)
# が UnauthorizedOperation で fail する。

# 3. cluster 接続性 (= recreate 後の検証にも使う)
kubectl config current-context
kubectl get nodes

# 4. 70-reconcile-watch.sh が wait する HelmRelease の audit
#    (= 出力が lib/70-reconcile-watch.sh の wait_helmreleases 引数と一致するか確認)
kubectl get helmreleases -A -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | sort
```

3 番目で差分 (= 新規 chart 追加 / removal) があれば `lib/70-reconcile-watch.sh` 側を先に更新してから recreate を回す。

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

### Recreate (= cluster 再作成)

```bash
# Dry-run
DRY_RUN=1 make eks-recreate ENV=production

# Live run (= 途中で operator の手作業が入る、後述)
make eks-recreate ENV=production
```

実行内容:

1. `50-apply-stacks.sh`: 「8 stack を apply するか」y/N 確認 → 8 stacks を固定順で `terragrunt apply` (= vpc → alb → eks → karpenter → eks-secrets → eks-logs/metrics/traces)
2. `60-flux-bootstrap.sh`: **operator-prompted RECREATE marker update** (後述) → re-hydrate kubernetes manifests → git commit + push to main → `kubectl apply -k kubernetes/clusters/production/`
3. `70-reconcile-watch.sh`: 全 HelmRelease が Ready になるまで Phase 単位で wait

部分実行:

```bash
make eks-recreate-aws ENV=production       # terragrunt apply only
make eks-recreate-flux ENV=production      # flux bootstrap only (= operator-prompted)
make eks-recreate-watch ENV=production     # reconcile watch only
```

### Operator-prompted RECREATE marker update (= `60-flux-bootstrap.sh` Step 60.2)

recreate のたびに変化する 2 種類の値 (= 新 cluster ID + 新 VPC ID) を hardcode した 4 箇所を、operator が手で更新する。 `60-flux-bootstrap.sh` が以下のように marker を grep + 列挙して `confirm` で待機する:

```
=================================================================
 The following values must be updated MANUALLY before continuing.
 For each '# RECREATE: <command>' line, run the command and
 replace the next line's value with the command's stdout.
=================================================================

## kubernetes/helmfile.yaml.gotmpl
  38:  # RECREATE: cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname
  39-  eksApiEndpoint: <old value>
  40:  # RECREATE: cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id
  41-  vpcId: <old value>

## kubernetes/components/aws-load-balancer-controller/production/helmfile.yaml
  16:  # RECREATE: cd aws/vpc/envs/production && TG_TF_PATH=tofu terragrunt output -raw vpc_id
  17-  vpcId: <old value>

## kubernetes/components/cilium/production/helmfile.yaml
  15:  # RECREATE: cd aws/eks/envs/production && TG_TF_PATH=tofu terragrunt output -raw cluster_endpoint_hostname
  16-  eksApiEndpoint: <old value>

Have you updated all RECREATE-marked values? (y to continue) [y/N]
```

operator の手順:

1. 別 terminal で 2 つの `terragrunt output` コマンドを実行し、新 cluster_endpoint_hostname と vpc_id を取得
2. editor で **4 箇所** を新値に書き換え (= eksApiEndpoint × 2 + vpcId × 2)
3. script に戻って `y` を入力 → script が `kubernetes/components/*/${ENV}/` を hydrate → `git diff kubernetes/` を表示 → `confirm` で push 承認 → main に commit + push → `kubectl apply -k kubernetes/clusters/production/`

marker convention の design rationale は `kubernetes/helmfile.yaml.gotmpl` 冒頭コメント参照 (= sed 自動置換ではなく operator-prompted を選んだ理由: PR #326 incident で audit pass 漏れがあり、目視で 1 件ずつ確認する方が confidence 高い)。

## Failure handling

- 各 step は **fail fast** (= 即 exit 1)、診断メッセージで「次に何を打つべきか」を提示
- partial state からの再 run は idempotent: `make eks-teardown` / `make eks-recreate` は何度叩いても安全
- ロールバックは前進復旧のみ (= teardown 中断は再 teardown、recreate 中断は再 recreate)
- admin role 一時 credentials の expire (= 1h STS session) は `30-destroy-stacks.sh` / `50-apply-stacks.sh` の各 stack 開始時に `creds_expiring_soon` (< 5min) で検出して `00-auth.sh` を re-source、admin role を assume し直す
- `40-orphan-verify.sh` は read-only verify で auto-delete しない (= false-positive 含み得る出力を operator が目視精査し、必要なら提示された AWS CLI コマンドで個別削除)。検出時の exit code は live run = 1 (= operator 注意喚起 + make chain 停止)、DRY_RUN=1 = 0 (= live cluster の現役 resource を warn として列挙、make chain は継続)
- `terragrunt destroy / apply` で `Module version requirements have changed` (= 既存 `.terragrunt-cache/` の module version と現行 main.tf の constraint が乖離) のエラーが出たら、対象 stack を `terragrunt init -upgrade` で更新してから再開する。 8 stack 一括は以下:
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
