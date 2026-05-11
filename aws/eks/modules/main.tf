# main.tf - EKS cluster composition via terraform-aws-modules/eks/aws

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.20.0"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

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

  tags = var.common_tags
}
