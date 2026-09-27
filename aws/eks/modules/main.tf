module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.1"

  name               = "eks-${var.environment}"
  kubernetes_version = var.cluster_version

  vpc_id                   = module.vpc.vpc.id
  subnet_ids               = module.vpc.subnets.private.ids
  control_plane_subnet_ids = module.vpc.subnets.private.ids

  endpoint_public_access  = true
  endpoint_private_access = true

  # Native Cilium CNI and KPR replace vpc-cni and kube-proxy; CoreDNS is managed via addons.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  # Audit logs omitted to avoid massive ingestion volume from controller reconcile loops.
  enabled_log_types                      = ["authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Envelope encryption disabled by setting config null to prevent auto-creating KMS keys.
  encryption_config = null

  access_entries = local.access_entries
  addons         = local.cluster_addons

  create_security_group      = false
  security_group_id          = module.vpc.security_groups.private_trust.id
  create_node_security_group = false
  node_security_group_id     = module.vpc.security_groups.private_trust.id

  tags = var.common_tags
}
