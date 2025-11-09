variable "prefix" {
  description = "Project prefix for naming resources"
  type        = string
  default     = "voting-app"
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 3
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateways (costly). If false, private subnets may lose outbound internet unless using alternate egress."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway instead of one per AZ"
  type        = bool
  default     = true
}

variable "create_rds" {
  description = "Whether to create an RDS PostgreSQL instance"
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "Allocated storage (GB) for RDS"
  type        = number
  default     = 20
}

variable "rds_username" {
  description = "Master username for RDS"
  type        = string
  default     = "postgres"
}

variable "rds_password" {
  description = "Master password for RDS (do not hardcode in production; use TF_VAR variables or SSM)"
  type        = string
  sensitive   = true
  default     = "changeme123!"
}

variable "create_redis" {
  description = "Whether to create an ElastiCache Redis replication group"
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "Instance type for Redis nodes"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters (1 for no replicas)"
  type        = number
  default     = 1
}

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

variable "redis_auth_token" {
  description = "ElastiCache Redis AUTH token (leave empty to disable AUTH)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ecr_repositories" {
  description = "List of ECR repositories to create"
  type        = list(string)
  default     = ["vote", "result", "worker", "seed-data"]
}

variable "ecr_enable_lifecycle" {
  description = "Enable lifecycle policy to expire old untagged images"
  type        = bool
  default     = true
}

variable "github_actions_user_arn" {
  description = "IAM user or role ARN for GitHub Actions to access EKS cluster. Example: arn:aws:iam::123456789012:user/github-actions. DEPRECATED: Use additional_access_entries instead to avoid cluster creator conflicts."
  type        = string
  default     = ""
}

variable "additional_access_entries" {
  description = <<-EOT
    List of additional IAM principals (users/roles) to grant EKS cluster access.
    Each entry should be DIFFERENT from the cluster creator to avoid conflicts.
    Example:
    [
      {
        principal_arn = "arn:aws:iam::123456789012:user/github-actions"
        type          = "STANDARD"  # Optional, defaults to STANDARD
      },
      {
        principal_arn = "arn:aws:iam::123456789012:role/developer-role"
        kubernetes_groups = ["system:masters"]  # Optional, for custom RBAC
      }
    ]
  EOT
  type = list(object({
    principal_arn     = string
    type              = optional(string)
    kubernetes_groups = optional(list(string))
  }))
  default = []
}

variable "enable_cluster_creator_access" {
  description = "Whether to create an access entry for the IAM identity running terraform apply. Set to false if the cluster creator already has access or to manage manually."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply"
  type        = map(string)
  default     = {}
}
