# cli.hcl - CLI role configuration for develop

locals {
  trusted_principal_arns = [
    "arn:aws:iam::${get_aws_account_id()}:user/panicboat",
  ]
}
