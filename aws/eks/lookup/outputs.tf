# outputs.tf - Pass-through outputs of the underlying data source.

output "cluster" {
  description = "EKS cluster information (pass-through of aws_eks_cluster data source)."
  value = {
    name                       = data.aws_eks_cluster.this.name
    arn                        = data.aws_eks_cluster.this.arn
    endpoint                   = data.aws_eks_cluster.this.endpoint
    cluster_security_group_id  = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id

    # Cluster info needed by the standalone `eks-managed-node-group` submodule's
    # AL2023 user data generator (auto-wired when MNGs live inside `module "eks"`,
    # but standalone submodule requires explicit pass-through).
    certificate_authority_data = data.aws_eks_cluster.this.certificate_authority[0].data
    service_cidr               = data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
    ip_family                  = data.aws_eks_cluster.this.kubernetes_network_config[0].ip_family

    # OIDC provider ARN is constructed from the issuer URL by AWS provider.
    # IRSA consumers use oidc_provider_arn; Pod Identity consumers don't need it.
    oidc_provider_arn          = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"
    oidc_provider              = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  }
}
