# Route53 allows only one resource per (name, type) pair; colocate apex TXT entries in a single resource.
resource "aws_route53_record" "panicboat_net_apex_txt" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "panicboat.net"
  type    = "TXT"
  ttl     = 300
  records = [
    "google-site-verification=Pn_YBgisFYxUKSrVSNuaeVQaCpe63WT8tsd9lA-k9A8",
    "v=spf1 include:_spf.google.com ~all",
  ]
}

# Single MX record routes internally to Google MX cluster per Google Workspace spec.
resource "aws_route53_record" "panicboat_net_apex_mx" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "panicboat.net"
  type    = "MX"
  ttl     = 3600
  records = [
    "1 smtp.google.com.",
  ]
}

# 2048-bit DKIM key split into adjacent character-strings to meet 255-byte DNS string limit per RFC 1035.
resource "aws_route53_record" "panicboat_net_google_domainkey_txt" {
  zone_id = module.route53.zones.panicboat_net.id
  name    = "google._domainkey.panicboat.net"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzRNsux6oCcjpDmqavp8gzzwxD3mhkhlAaBGvjfwMBPVAHsCWnL7Km6vEmC4NIKccCNCxQAslTZgpui1QYyvxurH3ll24EivfOMR58nFqdwvmISLV79e/QHHIMGT9AHshKacC77G13LWwqdTkk3IqbnK8MtLH/iuICaJJm+HSpy/PQdz29GPbptadhZNXiGEZ6CJ\" \"uR44biyYu8fpGHRGvGXmXkoACIL7ZAz2sHUKNVJLjpNQYkzWHNde5t0pOU4G04rOV14zosTqWzuPPrd13uiTtantcph6E58dJ+GbNSN+qRszUb3evLls/cueQJP+C6XRq3EkKjcDJCewa/3SrswIDAQAB",
  ]
}
