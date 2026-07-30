# main.tf - Account 単位の IAM service-linked role。
#
# 新しい service-linked role が必要になったら、この module 内に resource
# block を追加する (stack を分けない。理由は terragrunt.hcl 参照)。

# EC2 Spot: Karpenter の system-components NodePool
# (kubernetes/components/karpenter/production/kustomization/nodepool.yaml)
# が capacity-type [spot, on-demand] で spot instance を起動する際に必要。
#
# Karpenter controller IAM policy (terraform-aws-modules 標準 policy) は
# least-privilege 設計で iam:CreateServiceLinkedRole を含まないため、AWS 側
# の自動作成に失敗し spot 経由の node 起動/consolidation が
# AuthFailure.ServiceLinkedRoleCreationNotPermitted で失敗する。
#
# aws/karpenter (per-env stack) には埋め込まない。理由:
# 1. account 単位 singleton なので、複数 env (production 以外に将来
#    staging/develop 等) が同一 account に増えると 2 つ目以降の env の
#    apply が確実に EntityAlreadyExists で失敗する。
# 2. aws/karpenter は docs/runbooks/eks-production-recreate.md の
#    destroy/recreate cycle 対象。spot instance が残っている間は
#    DeleteServiceLinkedRole が AWS 側で非同期に遅延/失敗しうるため、
#    destroy/recreate に巻き込むと無用な失敗点になる。
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}
