output "aws_region" {
  description = "AWS deployment region"
  value       = "ap-south-1"
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = module.vpc.nat_gateway_id
}
