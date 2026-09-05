# secrets-manager

`aws_secretsmanager_secret` の container (name/tags) を管理する stack。実際の secret value (`aws_secretsmanager_secret_version`) は対象外で、これまで通り手動運用のまま維持する (tfstate/git に平文 secret を持ち込まないため)。

## destroy/recreate cycle 対象外

`aws/eks` 系 stack (`eks`, `eks-secrets`, `eks-logs`, `eks-metrics`, `eks-traces`, `eks-karpenter`, `eks-holmesgpt`) は `docs/runbooks/eks-production-recreate.md` の destroy/recreate cycle 対象だが、本 stack は対象外 (`scripts/eks-lifecycle/lib/30-destroy-stacks.sh` の `STACKS` にも含めないこと)。GitHub App の private key など AWS 側で再生成できない secret を扱うため、cluster の destroy/recreate に巻き込むと復旧不能なデータ消失になりうる。`aws/iam-service-linked-roles` と同じ位置付け。

## 新しい secret が必要になったら

新規 stack を作らず、`modules/main.tf` の `local.secrets` に entry を追加する。
