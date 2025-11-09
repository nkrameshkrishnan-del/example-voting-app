# Manual Deployment Steps (Testing Before GitHub Actions)

> Purpose: Lightweight manual path to validate changes without waiting for CI/CD. Assumes Terraform provisioned EKS, RDS (SSL required), Redis (AUTH disabled, TLS enabled), and that images may be built locally for linux/amd64.

## Quick Matrix
| Component | Terraform | Manual Here | Notes |
|-----------|-----------|-------------|-------|
| VPC/EKS/RDS/Redis | Yes | Skip creation | Verify outputs only |
| Secrets (RDS) | Yes (AWS SM) | Create k8s secret or enable ESO | Redis secret omitted |
| External Secrets Operator | No (optional) | Optional | Can skip entirely |
| Ingress (ALB) | No | Apply YAML | Ensure WebSocket annotations |
| App Images | No | Build & push | Must target linux/amd64 |
| Access Entries | Yes | Skip | Unless adding new principal |

Badge Legend: (Skip if Terraform) fully provisioned; (Optional) can omit for quick test.

## Prerequisites
- Terraform infrastructure deployed successfully (Skip if Terraform)
- kubectl configured to access the cluster
- Helm installed (Optional if skipping ESO)
- Docker configured with ECR login
- AWS CLI credentials for account
- Node architecture target: linux/amd64 images

## Step-by-Step Deployment

### 1. Update kubeconfig (Skip if already configured)
```bash
aws eks update-kubeconfig --name voting-app-cluster --region us-east-1
kubectl cluster-info
kubectl get nodes
```

### 2. Create namespace
```bash
kubectl create namespace voting-app
```

### 3. (Optional) Install External Secrets Operator
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --wait

# Wait for CRDs to be available
kubectl wait --for condition=established --timeout=60s crd/secretstores.external-secrets.io
kubectl wait --for condition=established --timeout=60s crd/externalsecrets.external-secrets.io
kubectl wait --for condition=established --timeout=60s crd/clustersecretstores.external-secrets.io

# Verify ESO is running
kubectl get pods -n external-secrets-system
```

### 4. Apply ConfigMap (Ensure host/port separation)
Before applying, edit `k8s-specifications/configmap.yaml` so:
```yaml
postgres_host: "<rds_endpoint_without_port>"
postgres_port: "5432"
redis_host: "<redis_primary_endpoint>"
redis_port: "6379"
redis_ssl: "true"
```
```bash
kubectl apply -f k8s-specifications/configmap.yaml -n voting-app
```

### 5. (Optional) Apply External Secrets Configuration
```bash
# Apply ClusterSecretStore (cluster-wide resource)
kubectl apply -f k8s-specifications/external-secrets/clustersecretstore.yaml

# Apply ExternalSecrets (namespace-scoped)
kubectl apply -f k8s-specifications/external-secrets/externalsecrets.yaml -n voting-app

# Wait for secrets to sync
sleep 10

# Verify secrets were created
kubectl get secret redis-secret db-secret -n voting-app
kubectl describe externalsecret -n voting-app
```

### 6. Build & Push Images (if testing new changes)
```bash
export AWS_ACCOUNT_ID=<acct>
export AWS_REGION=us-east-1
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_BASE}

# vote
docker build --platform linux/amd64 -t ${ECR_BASE}/vote:manual-test ./vote
docker push ${ECR_BASE}/vote:manual-test

# result
docker build --platform linux/amd64 -t ${ECR_BASE}/result:manual-test ./result
docker push ${ECR_BASE}/result:manual-test

# worker
docker build --platform linux/amd64 -t ${ECR_BASE}/worker:manual-test ./worker
docker push ${ECR_BASE}/worker:manual-test
```
Update the deployment YAMLs image tags to `manual-test` if needed.

### 7. Deploy Application Services
```bash
# Deploy vote service
kubectl apply -f k8s-specifications/vote-deployment.yaml -n voting-app
kubectl apply -f k8s-specifications/vote-service.yaml -n voting-app

# Deploy result service
kubectl apply -f k8s-specifications/result-deployment.yaml -n voting-app
kubectl apply -f k8s-specifications/result-service.yaml -n voting-app

# Deploy worker
kubectl apply -f k8s-specifications/worker-deployment.yaml -n voting-app
```

### 8. Wait for Deployments
```bash
kubectl rollout status deployment/vote -n voting-app --timeout=5m
kubectl rollout status deployment/result -n voting-app --timeout=5m
kubectl rollout status deployment/worker -n voting-app --timeout=5m
```

### 9. Check Status
```bash
# Get all resources
kubectl get all -n voting-app

# Check pods
kubectl get pods -n voting-app

# Check services
kubectl get svc -n voting-app

# Get service endpoints
kubectl get svc vote result -n voting-app -o wide
```

### 10. View Logs (if issues)
```bash
# Check External Secrets Operator logs
kubectl logs -n external-secrets-system deployment/external-secrets -f

# Check ExternalSecret status
kubectl describe externalsecret redis-credentials -n voting-app
kubectl describe externalsecret db-credentials -n voting-app

# Check application pod logs
kubectl logs -n voting-app deployment/vote
kubectl logs -n voting-app deployment/result
kubectl logs -n voting-app deployment/worker
```

## Ingress & WebSocket (Result App Real-Time Updates)
If using ALB Ingress, ensure annotations (in ingress YAML):
```yaml
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/load-balancer-attributes: routing.http2.enabled=false
alb.ingress.kubernetes.io/sticky-session.enabled: "true"
alb.ingress.kubernetes.io/sticky-session.type: load-balancer
alb.ingress.kubernetes.io/backend-protocol-version: HTTP1
```
Socket.IO path should match deployed config (`/result/socket.io`). If real-time updates fail, see `TROUBLESHOOTING_GUIDE.md` WebSocket section.

## SSL Verification (PostgreSQL)
Worker and result services must connect with SSL. Verify logs:
```bash
kubectl logs deployment/worker -n voting-app | grep -i ssl
kubectl logs deployment/result -n voting-app | grep -i SSL
```
No errors like `no pg_hba.conf entry` or `requires SSL` should appear.

## Race Condition Mitigation
If result app shows empty table or fails querying votes initially: restart after worker creates table.
```bash
kubectl rollout restart deployment/result -n voting-app
```

## Secrets Without ESO
If skipping ESO, create k8s secret manually from AWS Secrets Manager:
```bash
aws secretsmanager get-secret-value --secret-id voting-app-dev/rds/credentials --query SecretString --output text | jq .
kubectl create secret generic db-secret \
  --from-literal=username=postgres \
  --from-literal=password=<password> \
  --from-literal=host=<host_without_port> \
  --from-literal=port=5432 \
  --from-literal=dbname=postgres \
  -n voting-app
```

## Troubleshooting

### If secrets fail to sync:
```bash
# Check ESO has permissions
kubectl get pods -n external-secrets-system
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Check ExternalSecret events
kubectl describe externalsecret -n voting-app

# Verify IAM permissions on node role
aws iam list-attached-role-policies --role-name default-eks-node-group-XXXXX
```

### If ClusterSecretStore doesn't work:
The node IAM role should have the `voting-app-dev-secrets-reader` policy attached. Verify:
```bash
# Get the node role name
aws eks describe-nodegroup --cluster-name voting-app-cluster \
  --nodegroup-name default --region us-east-1 \
  --query 'nodegroup.nodeRole' --output text

# Check attached policies
aws iam list-attached-role-policies --role-name <NODE_ROLE_NAME>
```

## Access Application

### Using LoadBalancer (if configured):
```bash
kubectl get svc vote result -n voting-app
# Wait for EXTERNAL-IP to be assigned
# Then access via: http://<EXTERNAL-IP>:5000 (vote) and http://<EXTERNAL-IP>:5001 (result)
```

### Using Port Forward (for testing):
```bash
# Vote app
kubectl port-forward -n voting-app svc/vote 8080:5000

# Result app  
kubectl port-forward -n voting-app svc/result 8081:5001
```

Then access:
- Vote: http://localhost:8080
- Result: http://localhost:8081

## Cleanup
```bash
kubectl delete namespace voting-app
# Optionally remove ESO if installed
helm uninstall external-secrets -n external-secrets-system
kubectl delete namespace external-secrets-system
```

## Summary
- Terraform covers infra; this guide focuses on app-level and optional components.
- Build images for linux/amd64 to avoid node architecture mismatch.
- Ensure ConfigMap splitting host/port to prevent duplicate port errors.
- Use WebSocket-friendly ALB annotations for real-time result updates.
- Redis AUTH disabled simplifies secrets; only RDS secret required.
