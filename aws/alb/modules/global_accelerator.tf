# global_accelerator.tf - Stable front door for the "application" ALB.

# The ALB is recreated with a new ARN whenever the EKS cluster is rebuilt.
# These controller-set tags stay stable across recreation.
data "aws_lb" "application" {
  tags = {
    "ingress.k8s.aws/stack" = "application"
    "elbv2.k8s.aws/cluster" = "eks-${var.environment}"
  }
}

resource "aws_globalaccelerator_accelerator" "application" {
  name            = "application-${var.environment}"
  ip_address_type = "IPV4"
  enabled         = true

  tags = var.common_tags
}

resource "aws_globalaccelerator_listener" "application" {
  accelerator_arn = aws_globalaccelerator_accelerator.application.arn
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "application" {
  listener_arn          = aws_globalaccelerator_listener.application.arn
  endpoint_group_region = var.aws_region

  endpoint_configuration {
    endpoint_id = data.aws_lb.application.arn
    weight      = 100
    # This creates an EC2 Security Group named "GlobalAccelerator" in the VPC.
    # It must be deleted before VPC teardown, or it blocks destroy with DependencyViolation.
    client_ip_preservation_enabled = true
  }
}

# master account's dystopia.city apex now points only at this accelerator's stable DNS name, decoupled from ALB churn.
resource "aws_route53_record" "dystopia_city_apex" {
  provider = aws.route53

  zone_id = module.route53.zones.dystopia_city.id
  name    = "dystopia.city"
  type    = "A"

  alias {
    name                   = aws_globalaccelerator_accelerator.application.dns_name
    zone_id                = aws_globalaccelerator_accelerator.application.hosted_zone_id
    evaluate_target_health = false
  }

  # Takes over the currently-unmanaged manually-created record.
  allow_overwrite = true
}
