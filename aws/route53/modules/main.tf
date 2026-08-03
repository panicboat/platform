# main.tf - Zone-apex DNS records for panicboat.net.
#
# Route53 allows only one resource per (name, type) pair; multiple TXT values
# must live in `records` on a single aws_route53_record. Colocate all
# apex-level TXT entries (domain verification, SPF, etc.) here so a single
# resource owns the apex TXT set.

resource "aws_route53_record" "panicboat_net_apex_txt" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "panicboat.net"
  type    = "TXT"
  ttl     = 300
  records = [
    "google-site-verification=Pn_YBgisFYxUKSrVSNuaeVQaCpe63WT8tsd9lA-k9A8",
  ]
}

# Google Workspace single-record MX setup. `smtp.google.com` fans out to
# Google's MX cluster internally, so no ALT* records are needed.
# https://support.google.com/a/answer/140034
resource "aws_route53_record" "panicboat_net_apex_mx" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "panicboat.net"
  type    = "MX"
  ttl     = 3600
  records = [
    "1 smtp.google.com.",
  ]
}
