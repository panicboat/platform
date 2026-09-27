# Passes cross-account aws.route53 provider to resolve zones in the management account.
module "route53" {
  source = "../../route53/lookup"

  providers = {
    aws = aws.route53
  }
}
