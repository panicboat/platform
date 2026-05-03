# main.tf - Lookup of Route53 hosted zones by domain name.
#
# Add new zones here as they're brought into scope (e.g., dystopia.city
# for monorepo migration). Consumers reference outputs.zones.<key>.

data "aws_route53_zone" "panicboat_net" {
  name         = "panicboat.net."
  private_zone = false
}
