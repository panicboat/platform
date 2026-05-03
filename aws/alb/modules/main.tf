# main.tf - ACM wildcard certificate for *.panicboat.net.

resource "aws_acm_certificate" "wildcard_panicboat_net" {
  domain_name               = "*.panicboat.net"
  subject_alternative_names = ["panicboat.net"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

# DNS validation records in the panicboat.net hosted zone.
resource "aws_route53_record" "wildcard_panicboat_net_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard_panicboat_net.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = module.route53.zones.panicboat_net.id
}

resource "aws_acm_certificate_validation" "wildcard_panicboat_net" {
  certificate_arn         = aws_acm_certificate.wildcard_panicboat_net.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_panicboat_net_validation : record.fqdn]
}
