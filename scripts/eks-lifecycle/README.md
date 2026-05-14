# EKS Lifecycle

Temporary teardown / idempotent recreate of `eks-production` cluster + 周辺 AWS stacks. 手元 shell から実行する想定 (= CI 経由 trigger は未対応)。

詳細設計: `docs/superpowers/specs/2026-05-10-eks-production-teardown-recreate-design.md`

## Prerequisites

- 操作者の IAM principal が `sts:AssumeRole` で以下を assume できること:
  - `arn:aws:iam::<acct>:role/github-oidc-auth-production-github-actions-apply-role`
  - `arn:aws:iam::<acct>:role/eks-admin-production`
- 手元に installed: `tofu`, `terragrunt`, `kubectl`, `flux`, `jq`, `aws`, `make`, `bash`
- repo root から `make` を実行する (= `Makefile` がある場所)

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
2. `30-destroy-stacks.sh`: 8 stacks を固定順で `terragrunt destroy` (= karpenter → eks-secrets → eks-logs/metrics/traces → eks → alb → vpc)
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

# Live run
make eks-recreate ENV=production
```

実行内容:

1. `50-apply-stacks.sh`: 8 stacks を固定順で `terragrunt apply` (= vpc → alb → eks → karpenter → eks-secrets → eks-logs/metrics/traces)
2. `60-flux-bootstrap.sh`: hydrate-component で manifests を新 cluster ID で再生成 → git commit + push → `kubectl apply -k kubernetes/clusters/production/`
3. `70-reconcile-watch.sh`: 全 HelmRelease が Ready になるまで Phase 単位で wait

## Failure handling

- 各 step は **fail fast** (= 即 exit 1)、診断メッセージで「次に何を打つべきか」を提示
- partial state からの再 run は idempotent: `make eks-teardown` / `make eks-recreate` は何度叩いても安全
- ロールバックは前進復旧のみ (= teardown 中断は再 teardown、recreate 中断は再 recreate)
- credentials 期限 1h は `00-auth.sh` が自動再 assume

## What is preserved through teardown

- AWS Secrets Manager service の secret 値 (= terragrunt 管理外で手動管理)
- `aws/route53` (= panicboat.net hosted zone)
- `aws/github-oidc-auth` / `ai-assistant` / `cost-management` (= EKS 非依存)
- terragrunt remote state (= S3 + DynamoDB)

## What is destroyed

- `aws/eks`, `aws/karpenter`, `aws/eks-secrets`, `aws/eks-logs`, `aws/eks-metrics`, `aws/eks-traces` (= EKS 専用)
- `aws/alb` (= ACM wildcard cert *.panicboat.net、recreate 時は DNS validation 5〜10 分)
- `aws/vpc` (= NAT gateway 含む)
