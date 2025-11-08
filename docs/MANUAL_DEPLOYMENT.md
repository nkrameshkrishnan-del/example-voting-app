# Manual Deployment Steps (Testing Before GitHub Actions)

## Prerequisites
- Terraform infrastructure deployed successfully
- kubectl configured to access the cluster
- Helm installed

## Step-by-Step Deployment

### 1. Update kubeconfig
```bash
aws eks update-kubeconfig --name voting-app-cluster --region us-east-1
kubectl cluster-info
kubectl get nodes
```

### 2. Create namespace
```bash
kubectl create namespace voting-app
```

### 3. Install External Secrets Operator
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

### 4. Apply ConfigMap
```bash
kubectl apply -f k8s-specifications/configmap.yaml -n voting-app
```

### 5. Apply External Secrets Configuration
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

### 6. Deploy Application Services
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

### 7. Wait for Deployments
```bash
kubectl rollout status deployment/vote -n voting-app --timeout=5m
kubectl rollout status deployment/result -n voting-app --timeout=5m
kubectl rollout status deployment/worker -n voting-app --timeout=5m
```

### 8. Check Status
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

### 9. View Logs (if issues)
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
