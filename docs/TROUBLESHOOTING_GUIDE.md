# Comprehensive Troubleshooting Guide

## Database Connection Issues

### Issue: "no pg_hba.conf entry... no encryption"

**Symptoms:**
```
Waiting for db - Error: no pg_hba.conf entry for host "10.0.x.x", user "postgres", database "postgres", no encryption
```

**Root Cause:** AWS RDS requires SSL/TLS connections for all PostgreSQL instances.

**Solution:**

**For Node.js (result service):**
```javascript
const pool = new Pool({
  connectionString: connectionString,
  ssl: {
    rejectUnauthorized: false
  }
});
```

**For C# (worker service):**
```csharp
var connString = $"Host={host};Port={port};Username={user};Password={pass};Database=postgres;SslMode=Require;Trust Server Certificate=true;";
```

### Issue: "relation votes does not exist"

**Symptoms:**
```
Error performing query: error: relation "votes" does not exist
```

**Root Cause:** The worker service creates the `votes` table on startup, but the result service connects before the table exists.

**Solution:**
```bash
# Restart result pods after worker has connected
kubectl rollout restart deployment/result -n voting-app
```

### Issue: Connection string includes port twice

**Symptoms:**
```
Invalid URL: postgres://user:pass@host:5432:5432/db
```

**Root Cause:** ConfigMap `postgres_host` field includes `:5432`, and application code also adds the port.

**Solution:** ConfigMap should separate host and port:
```yaml
data:
  postgres_host: "voting-app-dev-pg.curq228s8eze.us-east-1.rds.amazonaws.com"  # NO PORT
  postgres_port: "5432"  # Separate field
```

## Redis Connection Issues

### Issue: Redis AUTH errors

**Symptoms:**
```
Redis AuthenticationError: invalid password
```

**Root Cause:** ElastiCache has transit encryption enabled but AUTH token disabled.

**Solution:**
1. Remove `REDIS_PASSWORD` environment variable from deployment
2. Ensure `REDIS_SSL=true` is set
3. Application should NOT send AUTH password

**In vote deployment:**
```yaml
env:
  - name: REDIS_HOST
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: redis_host
  - name: REDIS_PORT
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: redis_port
  - name: REDIS_SSL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: redis_ssl
  # DO NOT include REDIS_PASSWORD
```

## Socket.IO / WebSocket Issues

### Issue: Socket.IO 400 Bad Request

**Symptoms:**
```
GET /result/socket.io/?EIO=4&transport=polling 400 Bad Request
WebSocket connection failed
```

**Root Cause:** ALB doesn't support WebSocket connections without proper configuration.

**Solution:** Add ALB annotations to ingress:
```yaml
annotations:
  alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=86400
  alb.ingress.kubernetes.io/backend-protocol-version: HTTP1
```

### Issue: Socket.IO path 404 errors

**Symptoms:**
```
GET /socket.io/ 404 Not Found
```

**Root Cause:** Socket.IO server and client paths don't match for sub-path deployment.

**Solution:** Configure matching paths:

**Server (result/server.js):**
```javascript
const io = require('socket.io')(server, {
  path: '/result/socket.io'
});
```

**Client (result/views/app.js):**
```javascript
var socket = io.connect({ path: '/result/socket.io' });
```

## Architecture / Platform Issues

### Issue: "exec format error"

**Symptoms:**
```
exec /usr/bin/tini: exec format error
```

**Root Cause:** Docker image built for wrong CPU architecture (ARM vs AMD64).

**Solution:**
```bash
# Build for AMD64 (EKS nodes are amd64)
docker build --platform linux/amd64 -t image:tag .

# GitHub Actions runners are already amd64, no changes needed
```

## Infrastructure Teardown Issues

### Issue: Subnet deletion blocked

**Symptoms:**
```
Error: deleting EC2 Subnet: DependencyViolation: The subnet has dependencies and cannot be deleted
```

**Root Cause:** ALB created by Kubernetes ingress controller has network interfaces in the subnets.

**Solution:**
```bash
# 1. Delete ingress first
kubectl delete ingress voting-app-ingress -n voting-app

# 2. Manually delete ALB if needed
aws elbv2 delete-load-balancer --load-balancer-arn $(aws elbv2 describe-load-balancers --names voting-app-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# 3. Wait for ENIs to be released
sleep 30

# 4. Retry Terraform destroy
terraform destroy -auto-approve
```

### Issue: Internet Gateway detachment fails

**Symptoms:**
```
Error: detaching EC2 Internet Gateway: DependencyViolation: Network has some mapped public address(es)
```

**Root Cause:** Elastic IPs or network interfaces still attached.

**Solution:** Ensure all load balancers are deleted before destroying infrastructure.

## EKS Access Issues

### Issue: GitHub Actions authentication failure

**Symptoms:**
```
error: You must be logged in to the server
```

**Root Cause:** GitHub Actions IAM user not authorized to access EKS cluster.

**Solution:** Update Terraform variable:
```bash
terraform apply -var="github_actions_user_arn=arn:aws:iam::ACCOUNT:user/YOUR_USER"
```

### Issue: ALB Controller missing permissions

**Symptoms:**
```
Failed to describe listener attributes: AccessDenied
```

**Root Cause:** IAM policy version v2.7.0 missing `DescribeListenerAttributes` permission.

**Solution:** Use policy from main branch (already configured in `terraform/alb-controller.tf`):
```hcl
data "http" "aws_load_balancer_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}
```

## Application Deployment Issues

### Issue: Pods stuck in CrashLoopBackOff

**Diagnostic steps:**
```bash
# 1. Check pod status
kubectl get pods -n voting-app

# 2. Check pod events
kubectl describe pod <pod-name> -n voting-app

# 3. Check container logs
kubectl logs <pod-name> -n voting-app

# 4. Check previous container logs (if restarted)
kubectl logs <pod-name> -n voting-app --previous
```

**Common causes:**
- Database connection failure (check SSL configuration)
- Redis connection failure (check AUTH configuration)
- Missing environment variables
- Wrong image architecture
- Insufficient resources

### Issue: Service not accessible

**Check target health:**
```bash
# 1. Verify pods are running
kubectl get pods -n voting-app -l app=vote

# 2. Check service endpoints
kubectl get endpoints -n voting-app

# 3. Test from within cluster
kubectl run test --rm -it --image=busybox -- wget -O- http://vote.voting-app.svc.cluster.local

# 4. Check ingress
kubectl describe ingress -n voting-app
```

## Monitoring and Debugging Commands

### Check all resources
```bash
kubectl get all -n voting-app
```

### View pod logs (live)
```bash
kubectl logs -f deployment/vote -n voting-app
```

### Execute commands in pod
```bash
kubectl exec -it deployment/result -n voting-app -- sh
```

### Test database connection
```bash
kubectl exec -it deployment/result -n voting-app -- sh -c '
apt-get update && apt-get install -y postgresql-client &&
PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1;"
'
```

### Test Redis connection
```bash
kubectl exec -it deployment/vote -n voting-app -- sh -c '
python3 << EOF
import redis
import ssl
r = redis.Redis(
    host="$REDIS_HOST",
    port=int("$REDIS_PORT"),
    ssl=True if "$REDIS_SSL" == "true" else False,
    ssl_cert_reqs=None
)
print(r.ping())
EOF
'
```

### Check DNS resolution
```bash
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup voting-app-dev-pg.curq228s8eze.us-east-1.rds.amazonaws.com
```

### View ConfigMap
```bash
kubectl get configmap app-config -n voting-app -o yaml
```

### View Secrets (base64 decoded)
```bash
kubectl get secret db-secret -n voting-app -o json | jq -r '.data | map_values(@base64d)'
```

### Check ingress status
```bash
kubectl describe ingress voting-app-ingress -n voting-app
```

### View ALB target groups
```bash
aws elbv2 describe-target-groups --region us-east-1 | grep voting-app
```

### Check target health
```bash
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
```

## Performance Issues

### High CPU/Memory usage
```bash
# Check resource usage
kubectl top pods -n voting-app

# Check resource limits
kubectl describe pod <pod-name> -n voting-app | grep -A 5 "Limits"

# Adjust resources in deployment
kubectl set resources deployment vote -n voting-app \
  --limits=cpu=500m,memory=512Mi \
  --requests=cpu=250m,memory=256Mi
```

### Slow response times

**Check database performance:**
```bash
# RDS Performance Insights
aws rds describe-db-instances --db-instance-identifier voting-app-dev-pg

# Check connections
kubectl exec -it deployment/result -n voting-app -- sh -c '
psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB?sslmode=require" \
  -c "SELECT count(*) FROM pg_stat_activity;"
'
```

**Check Redis performance:**
```bash
# ElastiCache metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/ElastiCache \
  --metric-name CPUUtilization \
  --dimensions Name=CacheClusterId,Value=votingappdev-redis-001 \
  --start-time 2025-11-08T00:00:00Z \
  --end-time 2025-11-09T00:00:00Z \
  --period 3600 \
  --statistics Average
```

## Getting Help

If you're still stuck:

1. Check GitHub Actions logs for workflow errors
2. Review application logs: `kubectl logs -n voting-app deployment/<service>`
3. Check AWS CloudWatch Logs for RDS/ElastiCache issues
4. Review security group rules and network policies
5. Verify all environment variables are correctly set
6. Compare working configuration with Terraform outputs

**Useful Terraform outputs:**
```bash
cd terraform
terraform output
```

**Check Terraform state:**
```bash
terraform show
```
