# External Secrets Integration

> Current Status: Terraform provisions AWS Secrets Manager secrets and grants read access to the node role. External Secrets Operator (ESO) is optional and not yet enforced in production. Redis AUTH is disabled; only RDS credentials are required. Recovery window for secrets is set to `0` (immediate hard delete) — see Caution section.

## Overview
We store sensitive data (PostgreSQL credentials) in AWS Secrets Manager via Terraform. Redis currently runs with encryption in transit and **no AUTH**, so there is no Redis password secret. External Secrets Operator (ESO) can be enabled to automate syncing from Secrets Manager to Kubernetes; until enabled, you may create Kubernetes secrets manually or let Terraform output guide kubectl creation.

| Secret | Present | Source | Sync Method | Notes |
|--------|---------|--------|-------------|-------|
| RDS credentials (username/password/host/port) | Yes | Terraform AWS Secrets Manager | Manual or ESO (optional) | Required for worker + result services |
| Redis auth token | No (disabled) | N/A | N/A | Redis AUTH deliberately disabled; omit secret |
| Future app feature flags | Optional | Could use Secrets Manager | TBD | Consider ExternalSecret when added |

## Architecture (Optional ESO Flow)

```
AWS Secrets Manager → (Terraform creates) → [Optional] External Secrets Operator → Kubernetes Secret → Pod Env Vars
```

If ESO is not installed:
```
AWS Secrets Manager → (Terraform creates) → Manual kubectl secret creation → Pod Env Vars
```

Redis secret nodes removed from diagrams because AUTH disabled.

## Components

### Terraform (`terraform/secrets.tf`)
Creates and manages:
- `voting-app-dev/rds/credentials` (JSON: username, password, host, port, dbname)

If Redis AUTH is re-enabled later you would add:
- `voting-app-dev/redis/auth-token`

IAM policy grants least-privilege `secretsmanager:GetSecretValue` access only to defined ARNs. Recovery window (`recovery_window_in_days = 0`) means deletes are permanent immediately (see Caution).

### Kubernetes Manifests (`k8s-specifications/external-secrets/`)
Status: Optional – apply only if choosing ESO.

**`secretstore.yaml`**
- Connects ESO to Secrets Manager using node role (IRSA currently disabled)

**`externalsecrets.yaml`**
- Should ONLY declare `db-secret` right now (remove or comment out `redis-secret` block if present)
- Refresh interval: hourly (can shorten for faster rotation reaction)
- Maps JSON keys: `username`, `password`, `host`, `port`, `dbname`

## Setup

### Decide: Manual vs ESO
| Scenario | Recommendation |
|----------|---------------|
| Simple demo / low change frequency | Manual secret creation in Kubernetes |
| Need rotation without redeploy | Enable ESO |
| Plan to add >3 secrets or feature flags | Enable ESO early |

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

**Important:** Store generated passwords securely. Terraform state contains secrets in plain text—use remote encrypted backend (S3 + KMS + DynamoDB lock). Consider enabling secret value encryption at rest (default Secrets Manager behavior already applies).

### 2. Verify secrets in AWS

```bash
aws secretsmanager get-secret-value \
  --secret-id voting-app-dev/rds/credentials \
  --query SecretString \
  --output text | jq .

 # Redis secret intentionally absent while AUTH disabled.
```

### 3. Deploy to EKS

If ESO enabled, CD workflow can:
- Install External Secrets Operator via Helm
- Apply `SecretStore` and `ExternalSecret` manifests
- Wait for sync before deploying workloads

If ESO NOT enabled:
Create secret manually:
```bash
kubectl create secret generic db-secret \
  --from-literal=username="postgres" \
  --from-literal=password="$(aws secretsmanager get-secret-value --secret-id voting-app-dev/rds/credentials --query 'SecretString' --output text | jq -r .password)" \
  --from-literal=host="$(aws secretsmanager get-secret-value --secret-id voting-app-dev/rds/credentials --query 'SecretString' --output text | jq -r .host)" \
  --from-literal=port="$(aws secretsmanager get-secret-value --secret-id voting-app-dev/rds/credentials --query 'SecretString' --output text | jq -r .port)" \
  --from-literal=dbname="$(aws secretsmanager get-secret-value --secret-id voting-app-dev/rds/credentials --query 'SecretString' --output text | jq -r .dbname)" \
  -n voting-app
```

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
- **IAM permissions**: Verify node role has `secretsmanager:GetSecretValue` for secret ARN (RDS credentials only)
- **Redis secret missing**: Expected while AUTH disabled; remove from `externalsecrets.yaml`
- **Secret path mismatch**: Ensure `key:` matches AWS secret name (`voting-app-dev/rds/credentials`)
- **Region mismatch**: `secretstore.yaml` must reference correct region
- **Force sync not working**: Ensure annotation key is correct (`force-sync`) and value changes.

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

1. **No Redis secret**: AUTH disabled; do not create false placeholder secrets.
2. **Terraform state security**: Use remote encrypted backend (S3 + KMS + DynamoDB).
3. **Least privilege**: Policy restricts access to RDS secret ARN only; expand cautiously.
4. **Audit trail**: CloudTrail logs `GetSecretValue`; monitor unusual frequency.
5. **Immediate Deletion Caution**: `recovery_window_in_days = 0` means accidental deletion is irreversible; consider setting to `7` for production safety.
6. **Rotation**: Update secret in AWS; ESO (if enabled) syncs automatically; manually recreate k8s secret otherwise.
7. **Pod Restart**: Some apps read credentials only at startup; restart deployments after rotation.
8. **Future IRSA**: When IRSA enabled, migrate ESO to use service account role rather than node role.

## Cost

- AWS Secrets Manager: $0.40/secret/month + $0.05 per 10k API calls
Currently 1 secret; cost minimal (<$0.50/month). Adding more increases linear cost.

## Migration from static secrets

If you previously used `kubectl apply -f secrets.yaml`:

```bash
# Delete old static secrets
kubectl delete secret redis-secret db-secret -n voting-app

# Apply External Secrets (auto-creates them from AWS)
kubectl apply -f k8s-specifications/external-secrets/ -n voting-app
```

Application pods pick up updated Kubernetes secret data automatically for env vars only on restart; config watchers not implemented.

## Caution: Hard Delete Behavior
With `recovery_window_in_days = 0`, deleting a secret immediately makes recovery impossible. Recommended production adjustment:
```hcl
resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "voting-app-dev/rds/credentials"
  recovery_window_in_days = 7
}
```
Rotate weekly and monitor access anomalies.

## References

- [External Secrets Operator Docs](https://external-secrets.io/)
- [AWS Secrets Manager Provider](https://external-secrets.io/latest/provider/aws-secrets-manager/)
- [Terraform aws_secretsmanager_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret)
- See `TROUBLESHOOTING_GUIDE.md` (Secrets section) for runtime diagnostics.
