# cli.hcl - CLI role configuration for develop

locals {
  trusted_principal_arns = [
    "arn:aws:iam::559744160976:user/panicboat",
  ]
}
