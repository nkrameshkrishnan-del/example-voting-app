# External Secrets Integration

## Overview
This project uses [External Secrets Operator (ESO)](https://external-secrets.io/) to sync secrets from AWS Secrets Manager into Kubernetes, eliminating the need to commit credentials to Git.

## Architecture

```
AWS Secrets Manager → External Secrets Operator → Kubernetes Secrets → Pods
```

1. **AWS Secrets Manager** stores sensitive credentials (RDS password, Redis auth token)
2. **External Secrets Operator** watches `ExternalSecret` CRDs and syncs data
3. **Kubernetes Secrets** (`redis-secret`, `db-secret`) are auto-created and refreshed
4. **Application pods** consume secrets via environment variables (existing pattern unchanged)

## Components

### Terraform (`terraform/secrets.tf`)
- Creates AWS Secrets Manager secrets:
  - `voting-app-dev/redis/auth-token` (ElastiCache AUTH token)
  - `voting-app-dev/rds/credentials` (PostgreSQL username, password, host, port)
- Creates IAM policy allowing EKS nodes to read these secrets
- Attaches policy to node group IAM role

### Kubernetes Manifests (`k8s-specifications/external-secrets/`)

**`secretstore.yaml`**
- Defines how ESO connects to AWS Secrets Manager
- Uses node IAM role for authentication (no IRSA since disabled)

**`externalsecrets.yaml`**
- Declares `ExternalSecret` CRDs for `redis-secret` and `db-secret`
- Refreshes every hour
- Maps AWS Secrets Manager JSON keys to Kubernetes secret keys

## Setup

### 1. Deploy infrastructure with Terraform

```bash
cd terraform
terraform init
terraform apply \
  -var=create_rds=true \
  -var=create_redis=true \
  -var=rds_password="$(openssl rand -base64 32)" \
  -var=redis_auth_token="$(openssl rand -base64 32)"
```

**Important:** Store the generated passwords securely (e.g., password manager). Terraform state contains them.

### 2. Verify secrets in AWS

```bash
aws secretsmanager get-secret-value \
  --secret-id voting-app-dev/rds/credentials \
  --query SecretString \
  --output text | jq .

aws secretsmanager get-secret-value \
  --secret-id voting-app-dev/redis/auth-token \
  --query SecretString \
  --output text | jq .
```

### 3. Deploy to EKS

The CD workflow automatically:
- Installs External Secrets Operator via Helm
- Applies `SecretStore` and `ExternalSecret` manifests
- Waits for secrets to sync
- Deploys application workloads

Alternatively, manually:

```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --wait

# Apply manifests
kubectl apply -f k8s-specifications/external-secrets/ -n voting-app

# Verify sync
kubectl get externalsecrets -n voting-app
kubectl get secrets redis-secret db-secret -n voting-app
```

### 4. Update ConfigMap endpoints

Edit `k8s-specifications/configmap.yaml` with actual AWS endpoints:

```yaml
redis_host: "<terraform-output-redis_primary_endpoint>"
postgres_host: "<terraform-output-rds_endpoint>"
```

Then apply:

```bash
kubectl apply -f k8s-specifications/configmap.yaml -n voting-app
```

## Troubleshooting

### ExternalSecret not syncing

Check status:
```bash
kubectl describe externalsecret redis-credentials -n voting-app
```

Common issues:
- **IAM permissions**: Verify node role has `secretsmanager:GetSecretValue` for the secret ARNs
- **Secret path mismatch**: Ensure `key:` in `externalsecrets.yaml` matches actual secret name in AWS
- **Region mismatch**: `secretstore.yaml` must reference correct region

### Verify IAM policy attachment

```bash
aws iam list-attached-role-policies \
  --role-name <node-group-role-name>

aws iam get-policy-version \
  --policy-arn <secrets-reader-policy-arn> \
  --version-id v1
```

### Manual secret rotation

Update secret in AWS:
```bash
aws secretsmanager put-secret-value \
  --secret-id voting-app-dev/rds/credentials \
  --secret-string '{"username":"postgres","password":"new-password","host":"...","port":"5432","dbname":"postgres"}'
```

ESO will sync within 1 hour (or force refresh):
```bash
kubectl annotate externalsecret db-credentials \
  force-sync=$(date +%s) \
  -n voting-app
```

## Security Notes

1. **No secrets in Git**: `k8s-specifications/secrets.yaml` is now obsolete (can be deleted or kept as template)
2. **Terraform state security**: Use remote backend with encryption (S3 + DynamoDB)
3. **Least privilege**: IAM policy restricts access to specific secret ARNs only
4. **Audit trail**: CloudTrail logs all `GetSecretValue` API calls
5. **Rotation**: Update secrets in AWS Secrets Manager; ESO auto-syncs to pods

## Cost

- AWS Secrets Manager: $0.40/secret/month + $0.05 per 10k API calls
- For 2 secrets: ~$0.80/month + minimal API charges (ESO caches responses)

## Migration from static secrets

If you previously used `kubectl apply -f secrets.yaml`:

```bash
# Delete old static secrets
kubectl delete secret redis-secret db-secret -n voting-app

# Apply External Secrets (auto-creates them from AWS)
kubectl apply -f k8s-specifications/external-secrets/ -n voting-app
```

Application pods automatically pick up new secrets on restart (or wait for kubelet refresh).

## References

- [External Secrets Operator Docs](https://external-secrets.io/)
- [AWS Secrets Manager Provider](https://external-secrets.io/latest/provider/aws-secrets-manager/)
- [Terraform aws_secretsmanager_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret)
