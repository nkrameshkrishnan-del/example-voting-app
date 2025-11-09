# Ingress Setup Guide

## Overview

The voting app uses AWS Application Load Balancer (ALB) for ingress traffic routing via the AWS Load Balancer Controller. Path-based routing is used to serve both the vote and result applications from a single ALB.

## Architecture

```
Internet
    ↓
AWS ALB (Application Load Balancer)
    ↓
Kubernetes Ingress Resource (with WebSocket support)
    ↓
┌─────────────────┬─────────────────┐
│  /vote path     │  /result path   │
└─────────────────┴─────────────────┘
    ↓                   ↓
Vote Service        Result Service
    ↓                   ↓
Vote Pods           Result Pods (Socket.IO WebSocket)
```

## Key Features

✅ **Path-based routing** - Single ALB serves both apps  
✅ **WebSocket support** - Sticky sessions for Socket.IO  
✅ **No DNS required** - Uses ALB DNS directly  
✅ **Auto-provisioned** - ALB created automatically by controller

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

The ingress configuration is in `k8s-specifications/ingress-simple.yaml`:

#### Path-based Routing with WebSocket Support
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: voting-app-ingress-simple
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    # WebSocket support annotations
    alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=3600
    alb.ingress.kubernetes.io/backend-protocol-version: HTTP1
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /vote
            pathType: Prefix
            backend:
              service:
                name: vote
                port:
                  number: 80
          - path: /result
            pathType: Prefix
            backend:
              service:
                name: result
                port:
                  number: 80
```

**Key Annotations:**
- `stickiness.enabled=true` - Required for Socket.IO session persistence
- `stickiness.lb_cookie.duration_seconds=3600` - 1-hour sticky session
- `backend-protocol-version: HTTP1` - Required for WebSocket upgrade support

**Routing:**
```
http://ALB_DNS/vote   → Vote Service (HTTP)
http://ALB_DNS/result → Result Service (HTTP + WebSocket)
```

#### Socket.IO WebSocket Configuration

The result service uses Socket.IO for real-time updates. Configuration requirements:

**Server Side (result/server.js):**
```javascript
const io = socketIO(server, { 
  path: '/result/socket.io'  // Custom path for ALB routing
});
```

**Client Side (result/views/app.js):**
```javascript
var socket = io({ 
  path: '/result/socket.io'  // Must match server path
});
```

**Why This Is Needed:**
- Default Socket.IO path is `/socket.io/`
- ALB strips path prefix before forwarding
- Custom path `/result/socket.io` ensures routing works correctly
- Sticky sessions ensure WebSocket stays on same backend pod

## WebSocket Troubleshooting

## WebSocket Troubleshooting

### Socket.IO Connection Failures

**Symptom:** 400 Bad Request or WebSocket connection refused

**Causes and Solutions:**

1. **Missing Sticky Sessions**
   ```bash
   # Check ingress annotations
   kubectl describe ingress voting-app-ingress-simple -n voting-app | grep sticky
   ```
   
   **Fix:** Ensure `stickiness.enabled=true` in target-group-attributes

2. **HTTP/2 Protocol Conflicts**
   ```bash
   # Check backend protocol version
   kubectl describe ingress voting-app-ingress-simple -n voting-app | grep protocol
   ```
   
   **Fix:** Set `backend-protocol-version: HTTP1`

3. **Path Mismatch**
   - Server and client Socket.IO paths must match
   - Check browser console for connection errors
   - Verify path is `/result/socket.io` in both server and client code

4. **ALB Health Check Failures**
   ```bash
   # Check target health in AWS Console
   aws elbv2 describe-target-health \
     --target-group-arn $(aws elbv2 describe-target-groups \
     --query 'TargetGroups[?contains(TargetGroupName,`result`)].TargetGroupArn' \
     --output text)
   ```
   
   **Fix:** Ensure result pods are healthy and responding to HTTP requests

### Testing WebSocket Connection

```bash
# 1. Get ALB DNS
export ALB_DNS=$(kubectl get ingress voting-app-ingress-simple -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 2. Test HTTP endpoint
curl -I http://${ALB_DNS}/result

# 3. Test Socket.IO endpoint in browser console
# Open http://${ALB_DNS}/result in browser
# Open Developer Tools > Console
# Check for "connected" message or connection errors

# 4. Monitor Socket.IO connections in pod logs
kubectl logs -f deployment/result -n voting-app | grep socket.io
```

### Common Socket.IO Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `400 Bad Request` | ALB rejecting WebSocket upgrade | Add HTTP1 protocol annotation |
| `WebSocket connection failed` | No sticky sessions | Enable sticky sessions in target group |
| `404 /socket.io/` | Path mismatch | Configure custom path `/result/socket.io` |
| `Connection timeout` | Pod not ready | Check pod health and logs |
| `Transport error` | Network/firewall issue | Check security groups |

## Accessing the Application

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

### Via GitHub Actions CD Pipeline (Recommended)

The CD workflow automatically displays access URLs in the deployment summary:

```bash
# Workflow output includes:
Vote App: http://<ALB_DNS>/vote
Result App: http://<ALB_DNS>/result
```

### Manual Access

### Manual Access

Get the ALB DNS name:

```bash
export ALB_DNS=$(kubectl get ingress voting-app-ingress-simple -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Vote app: http://${ALB_DNS}/vote"
echo "Result app: http://${ALB_DNS}/result"
```

Access in browser:
- **Vote:** `http://<ALB_DNS>/vote` - Submit votes for Cats or Dogs
- **Result:** `http://<ALB_DNS>/result` - Real-time results with Socket.IO updates

### Host-based Routing (Optional - Not Configured)

If you want to use custom domains (vote.example.com, result.example.com):

1. Create a separate ingress with host-based rules
2. Request ACM certificate for your domain
3. Create DNS CNAME records pointing to ALB
4. Update ingress with certificate ARN and host rules

See **SSL/HTTPS Setup** section below for ACM integration.

## Deployment

### Via GitHub Actions CD Pipeline (Recommended)

The CD workflow automatically:
1. Installs AWS Load Balancer Controller via Helm
2. Deploys application services
3. Applies Ingress resource
4. Waits for ALB provisioning (2-3 minutes)
5. Displays ALB DNS and access URLs in deployment summary

**No manual steps required** - just push to main branch or trigger workflow manually.

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
