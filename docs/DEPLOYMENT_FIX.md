# Deployment Timeout Fix

## Problem Summary
The `result` deployment was timing out during rollout with the error:
```
Waiting for deployment "result" rollout to finish: 0 of 2 updated replicas are available...
error: timed out waiting for the condition
```

## Root Causes Identified

### 1. Hardcoded Database Connection
**File:** `result/server.js`
- Had hardcoded connection string: `postgres://postgres:postgres@db/postgres`
- Wasn't using environment variables passed from Kubernetes

### 2. Missing Environment Variables
**File:** `k8s-specifications/result-deployment.yaml`
- Missing `POSTGRES_PORT` and `POSTGRES_DB` environment variables
- Result pods couldn't establish database connection

### 3. Incorrect Service Configuration
**File:** `k8s-specifications/configmap.yaml`
- Configured for AWS services (ElastiCache/RDS) but not deployed
- Need local Redis and PostgreSQL services for testing

## Fixes Applied

### Fix 1: Update result/server.js
Changed from hardcoded connection to environment-variable based:
```javascript
var dbHost = process.env.POSTGRES_HOST || 'db';
var dbUser = process.env.POSTGRES_USER || 'postgres';
var dbPassword = process.env.POSTGRES_PASSWORD || 'postgres';
var dbName = process.env.POSTGRES_DB || 'postgres';
var dbPort = process.env.POSTGRES_PORT || '5432';

var pool = new Pool({
  host: dbHost,
  port: dbPort,
  user: dbUser,
  password: dbPassword,
  database: dbName
});
```

### Fix 2: Add Missing Environment Variables
Updated `result-deployment.yaml` to include:
- `POSTGRES_PORT`: 5432
- `POSTGRES_DB`: postgres

### Fix 3: Add Health Probes
Added readiness and liveness probes to detect connection issues faster:
```yaml
readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 30
  periodSeconds: 10
```

### Fix 4: Configure Local Services
Updated `configmap.yaml` for in-cluster deployment:
- `redis_host: "redis"` (instead of ElastiCache endpoint)
- `redis_ssl: "false"` (local Redis doesn't need SSL)
- `postgres_host: "db"` (instead of RDS endpoint)

### Fix 5: Deploy Required Services
Updated `cd-deploy-eks.yml` to deploy:
- In-cluster PostgreSQL (`db-deployment.yaml`)
- In-cluster Redis (`redis-deployment.yaml`)
- Wait for these services before deploying application

## Next Steps

### For Testing
The current configuration deploys everything in-cluster:
1. Push code changes to trigger CI/CD
2. Monitor deployment: `kubectl get pods -n voting-app --watch`
3. Check logs if issues: `kubectl logs -n voting-app deployment/result`

### For Production (AWS Services)
To use AWS ElastiCache and RDS:

1. **Create AWS Resources:**
   ```bash
   # Create RDS PostgreSQL
   aws rds create-db-instance \
     --db-instance-identifier voting-app-db \
     --db-instance-class db.t3.micro \
     --engine postgres \
     --master-username postgres \
     --master-user-password <secure-password> \
     --allocated-storage 20

   # Create ElastiCache Redis
   aws elasticache create-replication-group \
     --replication-group-id voting-app-redis \
     --replication-group-description "Voting app Redis" \
     --engine redis \
     --cache-node-type cache.t3.micro \
     --num-cache-clusters 1
   ```

2. **Update ConfigMap:**
   ```yaml
   redis_host: "<elasticache-endpoint>.cache.amazonaws.com"
   redis_ssl: "true"
   postgres_host: "<rds-endpoint>.rds.amazonaws.com"
   ```

3. **Update Secrets:**
   ```yaml
   # redis-secret
   password: "<elasticache-auth-token>"
   
   # db-secret
   username: "postgres"
   password: "<rds-master-password>"
   ```

4. **Update CD Workflow:**
   Comment out in-cluster database/redis deployment steps

## Verification Commands

```bash
# Check pod status
kubectl get pods -n voting-app

# Check pod logs
kubectl logs -n voting-app deployment/result
kubectl logs -n voting-app deployment/vote
kubectl logs -n voting-app deployment/worker

# Check services
kubectl get svc -n voting-app

# Test connectivity from result pod
kubectl exec -n voting-app deployment/result -- nc -zv db 5432
kubectl exec -n voting-app deployment/result -- nc -zv redis 6379

# Port forward to test locally
kubectl port-forward -n voting-app svc/vote 5000:80
kubectl port-forward -n voting-app svc/result 5001:80
```

## Files Modified

1. `result/server.js` - Database connection logic
2. `k8s-specifications/result-deployment.yaml` - Environment variables and probes
3. `k8s-specifications/configmap.yaml` - Service endpoints
4. `.github/workflows/cd-deploy-eks.yml` - Deployment order and service inclusion

## Architecture Decision

**Current (Testing):** In-cluster PostgreSQL and Redis
- ✅ Quick setup, no AWS costs
- ❌ Not production-ready, data lost on pod restart

**Future (Production):** AWS RDS and ElastiCache
- ✅ Managed, highly available, persistent
- ✅ Automatic backups, monitoring
- ❌ Additional AWS costs

## Troubleshooting

If deployment still fails:

1. **Check pod events:**
   ```bash
   kubectl describe pod -n voting-app -l app=result
   ```

2. **Check database connectivity:**
   ```bash
   kubectl exec -n voting-app deployment/db -- psql -U postgres -c '\l'
   ```

3. **Check Redis connectivity:**
   ```bash
   kubectl exec -n voting-app deployment/redis -- redis-cli ping
   ```

4. **Review configmap/secrets:**
   ```bash
   kubectl get configmap app-config -n voting-app -o yaml
   kubectl get secret db-secret -n voting-app -o yaml
   ```
