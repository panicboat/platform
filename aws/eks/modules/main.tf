# main.tf - EKS cluster composition via terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

  # vpc-cni / kube-proxy / coredns の自動 install 抑止 (= BYOCNI 要件) は
  # terraform-aws-modules/eks/aws v21 が `aws_eks_cluster.bootstrap_self_managed
  # _addons = false` を hardcode + lifecycle ignore_changes で固定済み (= module
  # input としては expose されない)。 panicboat は Cilium native CNI を使うため
  # vpc-cni 不要、 KPR で kube-proxy 不要、 coredns は AWS managed addon として
  # 下記 `addons = local.cluster_addons` 経由で明示配備する。 cluster create
  # 直後に self-managed aws-node DaemonSet が降ってこないため、 cilium-agent
  # が CNI plugin を /opt/cni/bin に置くまで node は NotReady のまま (= 公式
  # BYOCNI bootstrap flow と整合)。

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  # `audit` is intentionally omitted: it accounted for ~99.7% of bytes in
  # /aws/eks/<cluster>/cluster (4.32 GiB/day vs 14 MiB/day for authenticator)
  # and grew from 2.16 GB/day → 4.70 GB/day over a week as Karpenter / ALB
  # Controller / Flux / observability stacks were rolled out (leader-election
  # + reconcile traffic). EKS managed control plane does not allow custom
  # audit policies, and Vended Logs Delivery to S3/Firehose is unsupported
  # (only `AUTO_MODE_*` log types are eligible), so on-source filtering is
  # not possible. Re-enable only if K8s API audit is required for compliance
  # / incident response — and budget the ~$80–100 / month CW Logs ingest.
  enabled_log_types                      = ["authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Disable Secrets envelope encryption (spec decision: Out of Scope).
  # v21.19.0 enables encryption by default when `encryption_config != null`,
  # which would auto-create a KMS key + IAM policy + attachment via the
  # `kms` submodule. Set to `null` to skip the entire encryption_config
  # block and avoid unwanted KMS resources.
  encryption_config = null

  access_entries = local.access_entries
  addons         = local.cluster_addons

  create_security_group      = false
  security_group_id          = module.vpc.security_groups.private_trust.id
  create_node_security_group = false
  node_security_group_id     = module.vpc.security_groups.private_trust.id

  tags = var.common_tags
}

// TODO: Remove after EKS uses only the private trust security group and this SG has no ENI attachments.
resource "aws_security_group" "cluster" {
  name_prefix = "eks-${var.environment}-cluster-"
  description = "EKS cluster security group"
  vpc_id      = module.vpc.vpc.id

  tags = merge(
    var.common_tags,
    { Name = "eks-${var.environment}-cluster" },
  )

  lifecycle {
    create_before_destroy = true
  }
}

moved {
  from = module.eks.aws_security_group.cluster[0]
  to   = aws_security_group.cluster
}
