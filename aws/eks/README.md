# aws/eks

EKS clusters `eks-${env}` for the panicboat platform.

## Environments

`workflow-config.yaml` 由来の env / region 対応：

| Environment | Region | Cluster Name | Status |
|---|---|---|---|
| `production` | `ap-northeast-1` | `eks-production` | Active |
| `develop` | `us-east-1` | `eks-develop` | 未作成（必要時に `envs/production/` を複製して `envs/develop/` を新設） |

新環境を追加する際は、対応する `aws_region` を `envs/${env}/env.hcl` に書き、`panicboat/ansible` 側の `eks-login.sh` の `case` 文にも region を追加すること（DRY 違反の二重管理だが現状は許容）。

## Cluster (production)

| 項目 | 値 |
|---|---|
| Name | `eks-production` |
| Region | `ap-northeast-1` |
| Version | tracked via Renovate (`endoflife-date/amazon-eks`); see `envs/production/env.hcl` |
| Endpoint | public + private 両方有効 |
| Authentication | EKS Access Entries (`authentication_mode = "API"`) |
| Compute | Managed Node Group `system` (m6g.large × 2-4, AL2023 ARM64, gp3 50 GiB) |
| Add-ons | vpc-cni / kube-proxy / coredns / aws-ebs-csi-driver / eks-pod-identity-agent (all AWS-managed) |
| IRSA | enabled; vpc-cni と aws-ebs-csi-driver は別途 IRSA role |
| Secrets envelope encryption | 無効 (Out of Scope, spec 参照) |
| Control plane logs | `audit` + `authenticator` のみ、CloudWatch retention 7 日 |

## kubectl access

人間が kubectl を叩く経路は **`eks-admin-production` IAM role を assume する 1 本のみ**。CI 上の apply role は AWS API のみで Kubernetes API は触らない（GitOps 原則）。

### Quick start (推奨: login script)

`panicboat/ansible` で deploy される `eks-login.sh` を source する：

```bash
source ~/Workspace/eks-login.sh                          # → eks-production / ap-northeast-1
source ~/Workspace/eks-login.sh production               # 同上 (明示)
source ~/Workspace/eks-login.sh develop                  # → eks-develop / us-east-1 (将来 cluster 追加時)
source ~/Workspace/eks-login.sh staging us-west-2        # 未知 env は region 必須
```

スクリプトは：

1. env / region を解決（既知 env は default region、未知 env は明示必須）
2. `aws sts get-caller-identity` で現在の account ID を動的取得
3. `eks-admin-${env}` role を assume（session 1 時間）
4. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` を export
5. `aws eks update-kubeconfig` で kubeconfig 更新

完了後 `kubectl get nodes` 等が通るようになる。

> Source 必須（実行しても export が parent shell に反映されない）。スクリプトは `source` チェックで弾く。

### Manual login (script なし)

```bash
ENV=production    # or develop
REGION=ap-northeast-1   # production の場合。develop なら us-east-1。

ADMIN_ROLE_ARN=$(cd aws/eks/envs/${ENV} && TG_TF_PATH=tofu terragrunt output -raw admin_role_arn)
CREDS=$(aws sts assume-role \
  --role-arn "$ADMIN_ROLE_ARN" \
  --role-session-name "kubectl-${USER:-debug}" \
  --query 'Credentials' \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)

aws eks update-kubeconfig --region "${REGION}" --name "eks-${ENV}"
```

session を破棄するには `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`。

## terragrunt 操作

通常は CI が PR 経由で plan / apply を実行する（merge 時に main push が trigger）。手元から流したい場合：

```bash
cd aws/eks/envs/production
TG_TF_PATH=tofu terragrunt plan
TG_TF_PATH=tofu terragrunt apply -auto-approve
TG_TF_PATH=tofu terragrunt destroy -auto-approve
```

apply role の credentials が必要（CI と同じ `github-oidc-auth-production-github-actions-apply-role` を assume するか、AdministratorAccess 相当の IAM principal）。

## Architecture

- 設計詳細: `docs/superpowers/specs/2026-04-30-aws-eks-production-design.md`
- 実装プラン: `docs/superpowers/plans/2026-05-01-aws-eks-production.md`
- VPC cross-stack lookup（`module "vpc"` の参照規約）: `docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md`

主な設計ハイライト：

- **CNI**: VPC CNI を IPAM として残し、別途 Cilium を chaining mode で乗せる前提（次の Kubernetes spec で扱う）。node IAM role には `AmazonEKS_CNI_Policy` を付与せず、IRSA で aws-node SA に渡す（`iam_role_attach_cni_policy = false` + addon 側の `before_compute = true`）。
- **Access Entries**: `eks-admin-production` role 1 本のみに `AmazonEKSClusterAdminPolicy` を付与。`enable_cluster_creator_admin_permissions = false` でステルス admin を防止。
- **Node アクセス**: SSM Session Manager のみ（`AmazonSSMManagedInstanceCore`）、SSH key なし。

## Troubleshooting

| 症状 | 原因 / 対処 |
|---|---|
| `kubectl: error: You must be logged in to the server (Unauthorized)` | session credentials が expired（max 1 時間）または未 export。`eks-login.sh` を再 source。 |
| `kubectl: error: ... credentials` after switching shells | 新 shell では assume-role の env vars が引き継がれない。再 source。 |
| `aws sts assume-role: AccessDenied` | 実行している IAM principal に `sts:AssumeRole` resource permission がない。IAM 側で付与（リポジトリ管理外）。 |
| `update-kubeconfig: ResourceNotFoundException: No cluster found` | cluster が destroy 済 or 別 region。region と cluster name 確認。 |
| Node が `NotReady` / Pod scheduling 不能 | vpc-cni / IRSA まわりの bootstrap 順序問題の可能性。spec の Errata E-2 を参照（`before_compute = true` で対処済）。 |

## Renovate

`envs/production/env.hcl` の `cluster_version` 行に Renovate marker（`# renovate: datasource=endoflife-date depName=amazon-eks versioning=loose`）が埋め込まれており、AWS が新しい EKS バージョンを GA するたびに Renovate が PR を起票する。production パスは既存 `packageRules` で **automerge 無効** + `⚠️ production` ラベル付与の対象になるため、手動 merge 必須。

EKS は **minor skip upgrade 不可**（1.34 → 1.36 のような飛び級は不可、1 minor ずつ）。Renovate は 1 minor ずつしか PR を出さないので運用上は素直に merge していけば追従できる。
