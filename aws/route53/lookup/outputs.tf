# outputs.tf - Pass-through outputs of the underlying data sources.

output "zones" {
  description = "Route53 hosted zones grouped by domain key (pass-through of aws_route53_zone data sources)."
  value = {
    panicboat_net = {
      id   = data.aws_route53_zone.panicboat_net.zone_id
      arn  = data.aws_route53_zone.panicboat_net.arn
      name = data.aws_route53_zone.panicboat_net.name
    }
  }
}
