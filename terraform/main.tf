locals {
  name_prefix = "${var.prefix}-${var.environment}"
}

# VPC using community module
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name_prefix
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}

data "aws_availability_zones" "available" {}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "voting-app-cluster"
  cluster_version = "1.32"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # IRSA (OIDC) disabled per request to avoid OIDC usage; workloads must use node role or static creds
  enable_irsa = false

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3a.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      capacity_type  = "ON_DEMAND"
      tags = {
        Name = "${local.name_prefix}-node"
      }
    }
  }

  tags = var.tags
}

# ECR Repositories
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.ecr_repositories)
  name                 = "${var.prefix}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = merge(var.tags, { Component = each.key })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.ecr_enable_lifecycle ? aws_ecr_repository.this : {}
  repository = each.value.name
  policy     = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images > 10"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Security groups for DB / Redis
resource "aws_security_group" "rds" {
  count       = var.create_rds ? 1 : 0
  name        = "${local.name_prefix}-rds"
  description = "Allow Postgres"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_subnet_group" "this" {
  count      = var.create_rds ? 1 : 0
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = module.vpc.private_subnets
  tags       = var.tags
}

resource "aws_db_instance" "postgres" {
  count                      = var.create_rds ? 1 : 0
  identifier                 = "${local.name_prefix}-pg"
  engine                     = "postgres"
  engine_version             = "15"
  instance_class             = var.rds_instance_class
  allocated_storage          = var.rds_allocated_storage
  db_name                    = "postgres"
  username                   = var.rds_username
  password                   = var.rds_password
  skip_final_snapshot        = true
  deletion_protection        = false
  publicly_accessible        = false
  vpc_security_group_ids     = [aws_security_group.rds[0].id]
  db_subnet_group_name       = aws_db_subnet_group.this[0].name
  multi_az                   = false
  storage_encrypted          = true
  backup_retention_period    = 1
  apply_immediately          = true
  auto_minor_version_upgrade = true
  tags                       = var.tags
}

# Redis (ElastiCache)
resource "aws_security_group" "redis" {
  count       = var.create_redis ? 1 : 0
  name        = "${local.name_prefix}-redis"
  description = "Allow Redis"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  count      = var.create_redis ? 1 : 0
  name       = "${local.name_prefix}-redis-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "redis" {
  count                         = var.create_redis ? 1 : 0
  replication_group_id          = "${replace(local.name_prefix, "-", "")}-redis"
  description                   = "Redis for ${local.name_prefix}"
  node_type                     = var.redis_node_type
  num_cache_clusters            = var.redis_num_cache_clusters
  engine                        = "redis"
  engine_version                = var.redis_engine_version
  parameter_group_name          = "default.redis7"
  automatic_failover_enabled    = var.redis_num_cache_clusters > 1
  transit_encryption_enabled    = true
  at_rest_encryption_enabled    = true
  security_group_ids            = [aws_security_group.redis[0].id]
  subnet_group_name             = aws_elasticache_subnet_group.redis[0].name
  maintenance_window            = "sun:05:00-sun:06:00"
  snapshot_window               = "03:00-04:00"
  snapshot_retention_limit      = 1
  apply_immediately             = true
  port                          = 6379
  multi_az_enabled              = var.redis_num_cache_clusters > 1
  tags                          = var.tags
}
