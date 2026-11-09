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
    "v=spf1 include:_spf.google.com ~all",
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

# Start with p=none to observe; tighten to quarantine/reject once delivery looks clean.
resource "aws_route53_record" "panicboat_net_dmarc_txt" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "_dmarc.panicboat.net"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DMARC1; p=none",
  ]
}

resource "aws_route53_record" "dystopia_city_dmarc_txt" {
  zone_id = module.route53.zones.dystopia_city.id
  name    = "_dmarc.dystopia.city"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DMARC1; p=none",
  ]
}
