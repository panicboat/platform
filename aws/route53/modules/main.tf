# main.tf - DNS records managed by Terraform in the panicboat.net and
# dystopia.city hosted zones.
#
# Route53 allows only one resource per (name, type) pair; multiple TXT
# values must live in `records` on a single aws_route53_record. Colocate
# apex-level TXT entries (domain verification, SPF, etc.) per zone so a
# single resource owns each apex TXT set.

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

# Google Workspace DKIM public keys published at the `google` selector.
# The 2048-bit key exceeds the 255-char DNS <character-string> limit for TXT,
# so the value is split into two adjacent character-strings inside a single
# RR (RFC 1035 concatenates them for the receiver). The AWS provider wraps
# the whole value in outer quotes on our behalf, so we only emit the inner
# `" "` boundary between the two parts here.
# https://support.google.com/a/answer/174124
resource "aws_route53_record" "panicboat_net_google_domainkey_txt" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "google._domainkey.panicboat.net"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzRNsux6oCcjpDmqavp8gzzwxD3mhkhlAaBGvjfwMBPVAHsCWnL7Km6vEmC4NIKccCNCxQAslTZgpui1QYyvxurH3ll24EivfOMR58nFqdwvmISLV79e/QHHIMGT9AHshKacC77G13LWwqdTkk3IqbnK8MtLH/iuICaJJm+HSpy/PQdz29GPbptadhZNXiGEZ6CJ\" \"uR44biyYu8fpGHRGvGXmXkoACIL7ZAz2sHUKNVJLjpNQYkzWHNde5t0pOU4G04rOV14zosTqWzuPPrd13uiTtantcph6E58dJ+GbNSN+qRszUb3evLls/cueQJP+C6XRq3EkKjcDJCewa/3SrswIDAQAB",
  ]
}

resource "aws_route53_record" "dystopia_city_google_domainkey_txt" {
  zone_id = module.route53.zones.dystopia_city.id
  name    = "google._domainkey.dystopia.city"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAm0IVJrkSzvLRXAQwPKFukyVym5ybhq+hdJOZOs9+MXwmW/KLs7s9kkOZH3l5LvTckb1ur8GEktbPFhNAofX2pupvfGpweixiYAKElxofsKtaQGYGaSSDivdh5PrT2CdHjkGRMfIFAw8Uwh7MXMX7Et5r1mbWez0UV8zPz/0CYSmFLrnNKlRdGc8SuqzXcxEWIL6\" \"79735KJVSZp9xV3nv9wpSIEj+Q1BEFFZ7RZC1fIGJzGA4WkXRbrnBxEOIQ+HY1H6Ad59X2BC8gE3dgtI8xCzY8crx2W4pzy2aZFaaPbAumTeixhGfgmZ9VehWKnOkfU6osxRmKrqIBJLOcy78eQIDAQAB",
  ]
}

resource "aws_route53_record" "dystopia_city_apex_txt" {
  zone_id = module.route53.zones.dystopia_city.id
  name    = "dystopia.city"
  type    = "TXT"
  ttl     = 300
  records = [
    "google-site-verification=YEWipW1NCDu8F2uFl0cArc9ilJzHVW-EVHhDXgqhAdM",
  ]
}

resource "aws_route53_record" "dystopia_city_apex_mx" {
  zone_id = module.route53.zones.dystopia_city.id
  name    = "dystopia.city"
  type    = "MX"
  ttl     = 3600
  records = [
    "1 smtp.google.com.",
  ]
}
