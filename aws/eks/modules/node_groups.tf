# node_groups.tf - EKS managed node group definitions.
#
# Single "system" group on Graviton (ARM64) sized to host the platform
# components (Cilium / kube-proxy / CoreDNS / Prometheus-Operator / Loki /
# Tempo / OTel Collector / Beyla) plus headroom. Application workloads will
# be hosted on Karpenter-managed nodes (separate spec).

locals {
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Set EBS root volume size + type via block_device_mappings.
      # The top-level `disk_size` / `disk_type` arguments are silently
      # dropped by v21.19.0: `disk_type` is not in the v21 root schema's
      # eks_managed_node_groups object type (so it's an unknown key that
      # validates but never reaches AWS), and `disk_size` is forced to
      # `null` when `use_custom_launch_template = true` (the v21 default).
      # Using block_device_mappings is the only path that actually sets
      # gp3 / 50 GiB on the launch template.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda" # AL2023 root device
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }

      labels = {
        "node-role/system" = "true"
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        # SSM Session Manager access (no SSH key, port 22 closed)
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Do NOT attach AmazonEKS_CNI_Policy to the node IAM role.
      # v21.19.0's eks-managed-node-group submodule defaults
      # `iam_role_attach_cni_policy = true`, which would attach the policy
      # to the node role. We grant CNI permissions via IRSA instead (Task 7
      # creates the vpc-cni IRSA role bound to the aws-node ServiceAccount).
      # The trade-off: the aws-node DaemonSet must obtain its IAM
      # credentials via IRSA, which is the EKS best practice.
      iam_role_attach_cni_policy = false
    }
  }
}
