# outputs.tf - Outputs for the cost-management module.

output "spot_datafeed_bucket_name" {
  description = "S3 bucket name for the AWS Spot Instance Data Feed. Referenced (as a hardcoded value, see aws/eks-cost and kubernetes/components/opencost/ for why) by aws/eks-cost's IAM policy Resource ARN and kubernetes/components/opencost/ helmfile values (opencost.customPricing.costModel.awsSpotDataBucket)."
  value       = module.spot_datafeed_bucket.s3_bucket_id
}

output "spot_datafeed_region" {
  description = "AWS region of the Spot Instance Data Feed bucket. Used as opencost.customPricing.costModel.awsSpotDataRegion."
  value       = local.spot_datafeed_region
}
