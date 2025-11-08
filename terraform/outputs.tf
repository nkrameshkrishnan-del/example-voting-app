output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the created VPC"
}

output "private_subnets" {
  value       = module.vpc.private_subnets
  description = "Private subnet IDs"
}

output "public_subnets" {
  value       = module.vpc.public_subnets
  description = "Public subnet IDs"
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API server endpoint"
}


output "ecr_repositories" {
  value = { for k, repo in aws_ecr_repository.this : k => repo.repository_url }
  description = "Map of ECR repository URLs"
}

output "rds_endpoint" {
  value       = try(aws_db_instance.postgres[0].endpoint, null)
  description = "PostgreSQL RDS endpoint (null if not created)"
}

output "redis_primary_endpoint" {
  value       = try(aws_elasticache_replication_group.redis[0].primary_endpoint_address, null)
  description = "Redis primary endpoint (null if not created)"
}

output "redis_secret_arn" {
  value       = try(aws_secretsmanager_secret.redis_auth[0].arn, null)
  description = "ARN of Redis AUTH token secret in Secrets Manager"
}

output "rds_secret_arn" {
  value       = try(aws_secretsmanager_secret.rds_credentials[0].arn, null)
  description = "ARN of RDS credentials secret in Secrets Manager"
}
