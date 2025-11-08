# Ingress Setup Guide

## Overview

The voting app uses AWS Application Load Balancer (ALB) for ingress traffic routing via the AWS Load Balancer Controller.

## Architecture

```
Internet
    ↓
AWS ALB (Application Load Balancer)
    ↓
Kubernetes Ingress Resource
    ↓
┌─────────────────┬─────────────────┐
│  /vote path     │  /result path   │
└─────────────────┴─────────────────┘
    ↓                   ↓
Vote Service        Result Service
    ↓                   ↓
Vote Pods           Result Pods
```

## Components

### 1. AWS Load Balancer Controller

**Installed via Helm in CD pipeline:**
- Watches for Ingress resources
- Provisions AWS ALB automatically
- Manages target groups and routing rules
- Uses node IAM role permissions (no IRSA needed)

**IAM Permissions:**
- Policy attached to EKS node role via Terraform (`alb-controller.tf`)
- Allows creating/managing ALBs, target groups, security groups

### 2. Ingress Resources

Two ingress configurations are provided in `k8s-specifications/ingress.yaml`:

#### Option A: Host-based Routing (Multiple Domains)
```yaml
vote.voting-app.example.com  → Vote Service
result.voting-app.example.com → Result Service
```

**Requires:**
- DNS records pointing to ALB
- Optional: ACM SSL certificate

#### Option B: Path-based Routing (Single Domain) - **Default**
```yaml
http://ALB_DNS/vote   → Vote Service
http://ALB_DNS/result → Result Service
```

**No DNS required** - uses ALB DNS name directly

## Deployment

### Via GitHub Actions CD Pipeline

The CD workflow automatically:
1. Installs AWS Load Balancer Controller via Helm
2. Deploys application services
3. Applies Ingress resource
4. Waits for ALB provisioning
5. Displays ALB DNS in deployment summary

### Manual Deployment

```bash
# 1. Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

export CLUSTER_NAME=voting-app-cluster
export AWS_REGION=us-east-1
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID \
  --wait

# 2. Verify controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 3. Deploy application services (if not already deployed)
kubectl apply -f k8s-specifications/vote-deployment.yaml -n voting-app
kubectl apply -f k8s-specifications/vote-service.yaml -n voting-app
kubectl apply -f k8s-specifications/result-deployment.yaml -n voting-app
kubectl apply -f k8s-specifications/result-service.yaml -n voting-app
kubectl apply -f k8s-specifications/worker-deployment.yaml -n voting-app

# 4. Apply Ingress
kubectl apply -f k8s-specifications/ingress.yaml -n voting-app

# 5. Wait for ALB to be provisioned (takes 2-3 minutes)
kubectl get ingress -n voting-app -w

# 6. Get ALB DNS name
kubectl get ingress voting-app-ingress-paths -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Accessing the Application

### Path-based Routing (Default)

Once the ALB is provisioned, get the DNS name:

```bash
export ALB_DNS=$(kubectl get ingress voting-app-ingress-paths -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Vote app: http://${ALB_DNS}/vote"
echo "Result app: http://${ALB_DNS}/result"
```

Access in browser:
- **Vote:** `http://<ALB_DNS>/vote`
- **Result:** `http://<ALB_DNS>/result`

### Host-based Routing (Optional)

If using host-based routing:

1. Get ALB DNS name:
   ```bash
   kubectl get ingress voting-app-ingress -n voting-app
   ```

2. Create DNS CNAME records:
   ```
   vote.voting-app.example.com   → CNAME → <ALB_DNS>
   result.voting-app.example.com → CNAME → <ALB_DNS>
   ```

3. Access via custom domains:
   - `http://vote.voting-app.example.com`
   - `http://result.voting-app.example.com`

## SSL/HTTPS Setup (Optional)

To enable HTTPS with AWS Certificate Manager (ACM):

1. **Request or import SSL certificate in ACM:**
   ```bash
   aws acm request-certificate \
     --domain-name voting-app.example.com \
     --subject-alternative-names "*.voting-app.example.com" \
     --validation-method DNS \
     --region us-east-1
   ```

2. **Update Ingress annotations:**
   ```yaml
   annotations:
     alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID
     alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
     alb.ingress.kubernetes.io/ssl-redirect: '443'
   ```

3. **Reapply Ingress:**
   ```bash
   kubectl apply -f k8s-specifications/ingress.yaml -n voting-app
   ```

## Troubleshooting

### Ingress stuck in "Pending"

Check controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### ALB not creating

**Check IAM permissions:**
```bash
# Verify policy is attached to node role
aws iam list-attached-role-policies --role-name <NODE_ROLE_NAME> | grep load-balancer
```

**Check controller events:**
```bash
kubectl describe ingress voting-app-ingress-paths -n voting-app
```

### 503 Service Unavailable

**Check target health:**
1. Go to EC2 Console → Target Groups
2. Find target group for voting-app
3. Check target health status
4. Verify security groups allow traffic

**Common causes:**
- Pods not ready: `kubectl get pods -n voting-app`
- Service selector mismatch: `kubectl describe svc vote result -n voting-app`
- Health check path incorrect

### Cannot reach ALB

**Check security groups:**
```bash
# ALB security group should allow inbound 80/443 from 0.0.0.0/0
aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=voting-app-cluster"
```

## Switching Between Ingress Types

### Use Path-based (Default)
```bash
kubectl delete ingress voting-app-ingress -n voting-app
# Keep voting-app-ingress-paths
```

### Use Host-based
```bash
kubectl delete ingress voting-app-ingress-paths -n voting-app
# Keep voting-app-ingress and configure DNS
```

Or deploy both and use different ALBs (will create 2 separate load balancers).

## Cost Considerations

**ALB Pricing:**
- ~$16-25/month per ALB
- Data transfer charges apply
- Use path-based routing (1 ALB) to minimize cost

**To delete ALB:**
```bash
kubectl delete ingress -n voting-app --all
# ALB will be automatically deleted by the controller
```

## Terraform Changes

The following Terraform resources were added:

**`terraform/alb-controller.tf`:**
- Downloads AWS Load Balancer Controller IAM policy
- Creates IAM policy
- Attaches policy to EKS node role

**Apply changes:**
```bash
cd terraform
terraform init -upgrade  # Download http provider
terraform plan
terraform apply
```
