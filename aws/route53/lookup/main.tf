data "aws_route53_zone" "panicboat_net" {
  name         = "panicboat.net."
  private_zone = false
}

data "aws_route53_zone" "dystopia_city" {
  name         = "dystopia.city."
  private_zone = false
}
