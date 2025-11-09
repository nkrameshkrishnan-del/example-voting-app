# Terraform Infrastructure for Voting App

## Overview
This Terraform configuration provisions AWS infrastructure for the "voting-app" including:

- VPC with public and private subnets across 3 AZs
- EKS 1.32 cluster with managed node group
- RDS PostgreSQL 15 instance (requires SSL connections)
- ElastiCache Redis 7.0 with transit encryption (AUTH token disabled)
- ECR repositories for application images
- IAM roles and policies for AWS Load Balancer Controller and External Secrets Operator
- AWS Secrets Manager integration for database credentials

It is modular and gated by variables so you can enable components selectively.

## Files
- `versions.tf`: Terraform and provider version constraints
- `providers.tf`: AWS + Kubernetes providers (K8s provider configured after cluster creation)
- `variables.tf`: Input variables controlling resource creation
- `main.tf`: Core resources (VPC, EKS, ECR, RDS, Redis, Secrets)
- `alb-controller.tf`: IAM policy and role for AWS Load Balancer Controller
- `external-secrets.tf`: IAM policy and role for External Secrets Operator
- `outputs.tf`: Useful outputs (endpoints, repository URLs, ARNs)

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

# Initialize Terraform
terraform init

# Plan with RDS and Redis enabled (default configuration)
terraform plan -var=environment=dev

# Apply infrastructure
terraform apply -auto-approve -var=environment=dev

# Get cluster credentials
aws eks update-kubeconfig --name voting-app-cluster --region us-east-1
```

**Note**: The default configuration creates RDS and ElastiCache which incur ongoing costs.

## Configuration Details

### Database (RDS PostgreSQL)
- **Engine**: PostgreSQL 15
- **Instance**: db.t3.micro
- **Storage**: 20GB encrypted
- **SSL Required**: Applications MUST use SSL/TLS connections
- **Default Password**: `changeme123!` (override with `-var=rds_password="your_password"`)

### Redis (ElastiCache)
- **Engine**: Redis 7.0
- **Node Type**: cache.t3.micro
- **Transit Encryption**: Enabled
- **AUTH Token**: Disabled (empty password)
- **Application Config**: Use `REDIS_SSL=true` and empty/no password

### Network Architecture
- **VPC CIDR**: 10.0.0.0/16
- **Private Subnets**: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24
- **Public Subnets**: 10.0.101.0/24, 10.0.102.0/24, 10.0.103.0/24
- **NAT Gateway**: Single shared NAT gateway (cost optimization)

### EKS Cluster
- **Version**: 1.32
- **Node Group**: 2-4 nodes (t3.medium)
- **IRSA**: Disabled (nodes use IAM instance profile)
- **Access**: Cluster creator (enable_cluster_creator_admin_permissions=true) and configured GitHub Actions user have admin access

## Variables
Key configuration variables:
- `prefix` – Resource naming prefix (default: "voting-app")
- `environment` – Environment tag (default: "dev")
- `region` – AWS region (default: "us-east-1")
- `create_rds` – Enable RDS PostgreSQL (default: true)
- `create_redis` – Enable ElastiCache Redis (default: true)
- `rds_password` – RDS master password (default: "changeme123!" - **change for production**)
- `redis_auth_token` – Redis AUTH token (default: "" - disabled)
- `github_actions_user_arn` – IAM user/role ARN for EKS cluster access (default: configured)
- `enable_nat_gateway` / `single_nat_gateway` – NAT gateway configuration (default: true/true)
- `ecr_repositories` – List of ECR repo names (default: ["vote", "result", "worker", "seed-data"])

## Outputs
After apply, important outputs include:
- `eks_cluster_name` – EKS cluster name
- `eks_cluster_endpoint` – EKS API endpoint
- `vpc_id` – VPC identifier
- `private_subnets` / `public_subnets` – Subnet IDs
- `ecr_repositories` – Map of ECR repository URLs
- `rds_endpoint` – PostgreSQL endpoint (host:port)
- `redis_endpoint` – Redis primary endpoint (host only)
- `alb_controller_role_arn` – IAM role ARN for Load Balancer Controller
- `external_secrets_role_arn` – IAM role ARN for External Secrets Operator

View all outputs:
```bash
terraform output
terraform output -json | jq
```

## Using the Cluster
Retrieve kubeconfig:
```bash
aws eks update-kubeconfig --name voting-app-cluster --region us-east-1
kubectl get nodes
```

Verify access:
```bash
kubectl auth can-i get pods --all-namespaces
```

## Application Deployment Notes

### Database Connection Requirements
**CRITICAL**: RDS PostgreSQL requires SSL/TLS connections. Applications must configure SSL:

**Node.js (pg library)**:
```javascript
const pool = new Pool({
  connectionString: connectionString,
  ssl: {
    rejectUnauthorized: false
  }
});
```

**C# (Npgsql)**:
```csharp
var connString = $"Host={host};Port={port};Username={user};Password={pass};Database=postgres;SslMode=Require;Trust Server Certificate=true;";
```

### ConfigMap Structure
The `postgres_host` in ConfigMap should **NOT** include the port:
```yaml
data:
  postgres_host: "voting-app-dev-pg.curq228s8eze.us-east-1.rds.amazonaws.com"
  postgres_port: "5432"  # Separate field
  redis_host: "master.votingappdev-redis.r0rtqe.use1.cache.amazonaws.com"
  redis_port: "6379"
  redis_ssl: "true"
```

### Redis Configuration
ElastiCache has transit encryption enabled but AUTH token disabled:
- Set `REDIS_SSL=true` in application
- Do NOT set `REDIS_PASSWORD` or use empty password
- Remove password handling from application connection logic

## Cost Considerations ⚠️
- NAT Gateways incur hourly + data processing charges; disable or reduce via variables for dev.
- RDS & ElastiCache add ongoing costs. Keep them disabled for ephemeral test environments.
- EKS control plane cost is standard; node group instances billed per hour.

## Security Notes
- **RDS Password**: Default `changeme123!` is insecure—override via `-var=rds_password="$(openssl rand -hex 16)"` or environment variable `TF_VAR_rds_password`
- **Secrets Management**: Credentials stored in AWS Secrets Manager with immediate deletion (recovery_window=0). Use External Secrets Operator to sync to Kubernetes.
- **IRSA Disabled**: Pod-level IAM roles (IRSA) intentionally disabled per requirements. Pods inherit node IAM role or use injected credentials. This increases blast radius—re-enable IRSA for production by setting `enable_irsa = true` in EKS module.
- **SSL/TLS Required**: Both RDS and ElastiCache require encrypted connections. Applications must configure SSL properly.
- **EKS Access**: Cluster creator and configured `github_actions_user_arn` have admin access. Manage additional access via `access_entries` in main.tf.
- **Security Groups**: Current configuration allows VPC-wide access to RDS (10.0.0.0/16). Restrict for production using specific security group IDs.
- **ALB Controller**: Uses IAM policy from main branch (more permissive than v2.7.0) to avoid missing permissions.

## Remote State (Recommended)
Uncomment backend configuration in `versions.tf`, then create supporting resources:
```bash
# Create S3 bucket for state
aws s3 mb s3://voting-app-terraform-state-${AWS_ACCOUNT_ID}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket voting-app-terraform-state-${AWS_ACCOUNT_ID} \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for locking
aws dynamodb create-table \
  --table-name voting-app-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Update `versions.tf`:
```hcl
terraform {
  backend "s3" {
    bucket         = "voting-app-terraform-state-ACCOUNT_ID"
    key            = "voting-app/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "voting-app-terraform-locks"
    encrypt        = true
  }
}
```

Re-run `terraform init -migrate-state` after editing.

## Cleanup

### Proper Teardown Order
To avoid dependency errors, clean up in this order:

```bash
# 1. Delete Kubernetes ingress (releases ALB)
kubectl delete ingress voting-app-ingress -n voting-app

# 2. Wait for ALB to be fully deleted (or delete manually)
aws elbv2 delete-load-balancer --load-balancer-arn $(aws elbv2 describe-load-balancers --names voting-app-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)

# 3. Wait for network interfaces to be released
sleep 30

# 4. Run Terraform destroy
terraform destroy -auto-approve
```

### Common Destroy Errors

**Subnet dependency violations**: ALB network interfaces block subnet deletion
- **Solution**: Delete the ALB first (see above)

**IGW detachment errors**: Elastic IPs or ENIs still attached
- **Solution**: Ensure all AWS Load Balancers are deleted

**ECR repository errors**: Repositories contain images
- **Solution**: Enable `force_delete = true` in ECR resources (already configured)

## Troubleshooting

### Application Issues

**"relation votes does not exist"** (Result service)
- Worker creates the table on first connection
- Restart result pods after worker successfully connects: `kubectl rollout restart deployment/result -n voting-app`

**"no pg_hba.conf entry... no encryption"** (Database connection)
- RDS requires SSL/TLS connections
- Update application code to enable SSL (see Application Deployment Notes above)

**Redis AUTH errors**
- ElastiCache has AUTH token disabled
- Remove `REDIS_PASSWORD` from deployment manifests
- Ensure `REDIS_SSL=true` is set

**Socket.IO 400 Bad Request / WebSocket errors**
- ALB requires sticky sessions for Socket.IO
- Ensure ingress has: `alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true`
- Configure Socket.IO path: `path: '/result/socket.io'`

**Architecture mismatch (exec format error)**
- Build images for linux/amd64: `docker build --platform linux/amd64`
- GitHub Actions runners are already amd64

### Infrastructure Issues

**"DependencyViolation" on subnet deletion**
- ALB network interfaces blocking deletion
- Delete ingress first, wait 30s, then retry destroy

**IAM access denied to EKS**
- Verify IAM user ARN matches `github_actions_user_arn` variable
- Cluster creator has automatic admin access
- Check access entries: `aws eks list-access-entries --cluster-name voting-app-cluster`

**ALB Controller missing permissions**
- Using policy from main branch instead of v2.7.0
- Includes `DescribeListenerAttributes` and other required permissions

## Next Enhancements
- Re-enable IRSA for per-service AWS access (recommended for production)
- Implement pod security policies / security contexts
- Add CloudWatch log aggregation and metrics
- Configure backup retention for RDS (currently 1 day)
- Add AWS WAF for ALB protection
- Implement Network Policies for pod-to-pod isolation
- Add separate dev/stage/prod workspaces
- Migrate to private EKS endpoint for enhanced security

## Disclaimer
Provided configuration is a starting point; review for compliance, security hardening, and scaling needs before production use.

**Known Limitations**:
- IRSA disabled (increases security blast radius)
- Single NAT gateway (no high availability)
- db.t3.micro and cache.t3.micro (not production-grade performance)
- Default passwords in variables (change for any real deployment)
- VPC-wide security group access (should be more restrictive)
- Secrets have zero recovery window (immediate permanent deletion)

**Production Readiness Checklist**:
- [ ] Enable IRSA for pod-level IAM roles
- [ ] Use AWS Secrets Manager or Parameter Store for all credentials
- [ ] Configure multi-AZ NAT gateways for HA
- [ ] Upgrade to production-grade instance types
- [ ] Implement private EKS endpoint access
- [ ] Add AWS WAF and Shield for DDoS protection
- [ ] Configure automated backups and disaster recovery
- [ ] Implement monitoring and alerting (CloudWatch, Prometheus)
- [ ] Add network policies and pod security standards
- [ ] Review and restrict security group rules
- [ ] Enable EKS audit logging to CloudWatch
- [ ] Implement GitOps workflow (ArgoCD/Flux)

---

**Last Updated**: November 2025  
**Terraform Version**: >= 1.6.0  
**AWS Provider Version**: >= 5.0  
**EKS Version**: 1.32
