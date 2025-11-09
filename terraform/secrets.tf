# AWS Secrets Manager secrets for voting app credentials

locals {
  # Workaround for Terraform crash involving marked (sensitive) values inside jsonencode + conditional.
  # We explicitly unmark (nonsensitive) before jsonencode to avoid go-cty mark assertion during destroy.
  redis_auth_effective = var.redis_auth_token != "" ? nonsensitive(var.redis_auth_token) : "CHANGEME-redis-auth-token"
  rds_password_effective = nonsensitive(var.rds_password)
}

resource "aws_secretsmanager_secret" "redis_auth" {
  count                   = var.create_redis ? 1 : 0
  name                    = "${local.name_prefix}/redis/auth-token"
  description             = "ElastiCache Redis AUTH token for ${local.name_prefix}"
  recovery_window_in_days = 0  # Force delete immediately to allow recreation
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  count     = var.create_redis ? 1 : 0
  secret_id = aws_secretsmanager_secret.redis_auth[0].id
  secret_string = jsonencode({
    password = local.redis_auth_effective
  })
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  count                   = var.create_rds ? 1 : 0
  name                    = "${local.name_prefix}/rds/credentials"
  description             = "RDS PostgreSQL credentials for ${local.name_prefix}"
  recovery_window_in_days = 0  # Force delete immediately to allow recreation
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  count     = var.create_rds ? 1 : 0
  secret_id = aws_secretsmanager_secret.rds_credentials[0].id
  secret_string = jsonencode({
    username = var.rds_username
    password = local.rds_password_effective
    host     = aws_db_instance.postgres[0].address
    port     = aws_db_instance.postgres[0].port
    dbname   = aws_db_instance.postgres[0].db_name
  })
}

# IAM policy for EKS nodes to read secrets
data "aws_iam_policy_document" "secrets_reader" {
  statement {
    sid    = "ReadSecretsManager"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = concat(
      var.create_redis ? [aws_secretsmanager_secret.redis_auth[0].arn] : [],
      var.create_rds ? [aws_secretsmanager_secret.rds_credentials[0].arn] : []
    )
  }
}

resource "aws_iam_policy" "secrets_reader" {
  name        = "${local.name_prefix}-secrets-reader"
  description = "Allow reading Secrets Manager secrets for voting app"
  policy      = data.aws_iam_policy_document.secrets_reader.json
  tags        = var.tags
}

# Attach policy to EKS node group role
resource "aws_iam_role_policy_attachment" "node_secrets_reader" {
  role       = module.eks.eks_managed_node_groups["default"].iam_role_name
  policy_arn = aws_iam_policy.secrets_reader.arn
}
