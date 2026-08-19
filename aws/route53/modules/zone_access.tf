# zone_access.tf - Cross-account role letting the production account manage
# records in the hosted zones this (management) account owns.
#
# Trusting the account root rather than individual role ARNs: IAM rejects a
# trust policy naming a role that does not exist yet, and
# `eks-production-external-dns` is not created until the EKS stack applies.
#
# Read and write share one role because Terraform provider aliases are static —
# plan and apply cannot point at different assume-role targets under the
# current setup. `terragrunt plan` never calls ChangeResourceRecordSets.

data "aws_iam_policy_document" "zone_access_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.production_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "zone_access" {
  name               = "route53-zone-access"
  assume_role_policy = data.aws_iam_policy_document.zone_access_assume.json

  tags = merge(var.common_tags, {
    Name = "route53-zone-access"
  })
}

resource "aws_iam_role_policy" "zone_access" {
  name = "route53-zone-access"
  role = aws_iam_role.zone_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone",
        ]
        Resource = [
          module.route53.zones.panicboat_net.arn,
          module.route53.zones.dystopia_city.arn,
        ]
      },
      {
        # Zone lookup by name and change propagation cannot be scoped to a zone.
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:GetChange",
        ]
        Resource = "*"
      },
    ]
  })
}
