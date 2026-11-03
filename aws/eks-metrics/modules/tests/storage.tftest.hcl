mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "337169763788"
    }
  }

  # Pinning the computed filter prefix makes the plan fail when the module configures one.
  mock_resource "aws_s3_bucket_lifecycle_configuration" {
    defaults = {
      rule = {
        filter = {
          prefix = ""
        }
      }
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::337169763788:role/role"
    }
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster = {
      name = "eks"
    }
  }
}

variables {
  aws_region = "ap-northeast-1"
  common_tags = {
    Environment = "production"
  }
}

run "names_the_pod_identity_role_after_the_service" {
  command = plan

  assert {
    condition     = aws_iam_role.pod_identity.name == "eks-mimir"
    error_message = "The Pod Identity role must be named eks-mimir."
  }
}

run "expires_every_object" {
  command = plan

  assert {
    condition     = length(module.s3.s3_bucket_lifecycle_configuration_rules) == 1
    error_message = "The bucket must have exactly one lifecycle rule."
  }

  assert {
    condition     = module.s3.s3_bucket_lifecycle_configuration_rules[0].id == "retention"
    error_message = "The lifecycle rule id must be retention."
  }

  assert {
    condition     = module.s3.s3_bucket_lifecycle_configuration_rules[0].expiration[0].days == 90
    error_message = "Objects must expire after 90 days."
  }

  assert {
    condition     = length(module.s3.s3_bucket_lifecycle_configuration_rules[0].filter) == 1
    error_message = "The lifecycle rule must have a single filter."
  }

  assert {
    condition = alltrue([
      for f in module.s3.s3_bucket_lifecycle_configuration_rules[0].filter :
      f.prefix == "" && f.object_size_greater_than == 0 && f.object_size_less_than == 0 && length(f.tag) == 0 && length(f.and) == 0
    ])
    error_message = "The lifecycle rule must not restrict objects by prefix, size or tag."
  }
}
