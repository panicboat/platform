# outputs.tf - Outputs for the alb module.

output "wildcard_panicboat_net_cert_arn" {
  description = "ARN of the validated *.panicboat.net wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard_panicboat_net.certificate_arn
}

output "wildcard_dystopia_city_cert_arn" {
  description = "ARN of the validated *.dystopia.city wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard_dystopia_city.certificate_arn
}
