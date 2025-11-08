# Terraform Infrastructure for Voting App

## Overview
This Terraform configuration provisions AWS infrastructure for the "voting-app" including:

- VPC with public and private subnets
- EKS cluster with managed node group
- Optional RDS PostgreSQL instance (disabled by default)
- Optional ElastiCache Redis (disabled by default)
- ECR repositories for application images

It is modular and gated by variables so you can enable components selectively.

## Files
- `versions.tf`: Terraform and provider version constraints (optionally remote backend stub)
- `providers.tf`: AWS + Kubernetes providers (K8s only works after cluster is created)
- `variables.tf`: Input variables controlling resource creation
- `main.tf`: Core resources (VPC, EKS, ECR, RDS, Redis)
- `outputs.tf`: Useful outputs (endpoints, repository URLs)

## Prerequisites
- Terraform >= 1.6.0
- AWS credentials exported (env vars or shared config):
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - (Optionally `AWS_SESSION_TOKEN`)
- S3 bucket & DynamoDB table if you enable remote state backend (recommended for team usage)

## Quick Start
```bash
cd terraform
terraform init
terraform plan -var=environment=dev -var=create_rds=false -var=create_redis=false
terraform apply -auto-approve -var=environment=dev
```

## Enabling RDS
```bash
terraform apply -var=create_rds=true -var=rds_password="$(openssl rand -hex 16)" -auto-approve
```

## Enabling Redis (ElastiCache)
```bash
terraform apply -var=create_redis=true -auto-approve
```

## Variables
Key toggles:
- `create_rds` (bool) – create PostgreSQL
- `create_redis` (bool) – create ElastiCache Redis
- `ecr_repositories` – list of repository names (logical components)
- `enable_nat_gateway` / `single_nat_gateway` – cost controls

## Outputs
After apply, note:
- `eks_cluster_name`, `eks_cluster_endpoint`
- `ecr_repositories` map
- `rds_endpoint` (if created)
- `redis_primary_endpoint` (if created)

## Using the Cluster
Retrieve kubeconfig:
```bash
aws eks update-kubeconfig --name $(terraform output -raw eks_cluster_name) --region $(terraform output -raw aws_region 2>/dev/null || echo us-east-1)
```
(You can also capture module outputs explicitly.)

## Cost Considerations ⚠️
- NAT Gateways incur hourly + data processing charges; disable or reduce via variables for dev.
- RDS & ElastiCache add ongoing costs. Keep them disabled for ephemeral test environments.
- EKS control plane cost is standard; node group instances billed per hour.

## Security Notes
- `rds_password` default is insecure—override via `-var` or environment variable `TF_VAR_rds_password`.
- IRSA (OIDC) has been intentionally disabled per request. This means pods will inherit the node IAM role or require injected static credentials (e.g., via secrets). This increases blast radius if compromised. Re-enable by setting `enable_irsa = true` in `main.tf` for least-privilege service account roles.
- Add security group ingress rules more selectively for production.

## Remote State (Recommended)
Uncomment backend in `versions.tf`, then create supporting resources:
```bash
aws s3 mb s3://my-terraform-state-bucket
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```
Re-run `terraform init` after editing.

## Cleanup
```bash
terraform destroy -auto-approve
```
If repos contain images you want to retain, delete them manually first or set `force_delete=false` in repository block (requires resource edit).

## Next Enhancements
- Re-enable IRSA for per-service AWS access (recommended)
- Add SSM Parameter Store & Secrets Manager integration
- Add separate dev/stage/prod workspaces
- Add CloudWatch log group retention tuning

## Disclaimer
Provided configuration is a starting point; review for compliance, security hardening, and scaling needs before production use.
