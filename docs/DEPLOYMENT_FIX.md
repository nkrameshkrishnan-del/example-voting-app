# Deployment Fixes - Historical Reference

> **Note:** This document captures historical deployment issues and fixes. For current troubleshooting, see [TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md).

## Overview

This document tracks all deployment issues encountered and resolved during the voting app EKS deployment. The application is now successfully deployed with AWS managed services (RDS PostgreSQL, ElastiCache Redis) and path-based ALB ingress routing.

## Critical Issues Resolved

### 1. RDS SSL/TLS Requirement ⚠️ **CRITICAL**

**Problem:**
```
FATAL: no pg_hba.conf entry for host "10.0.x.x", user "postgres", database "postgres", no encryption
```

**Root Cause:**
- AWS RDS PostgreSQL requires SSL/TLS connections by default
- Application code was attempting unencrypted connections

**Solution:**

**Node.js (result/server.js):**
```javascript
var pool = new Pool({
  host: dbHost,
  port: dbPort,
  user: dbUser,
  password: dbPassword,
  database: dbName,
  ssl: {
    rejectUnauthorized: false  // Required for RDS SSL
  }
});
```

**C# (worker/Program.cs):**
```csharp
var connectionString = $"Host={dbHost};Port={dbPort};Username={dbUser};Password={dbPassword};Database={dbName};SslMode=Require;Trust Server Certificate=true";
```

### 2. ConfigMap Port Handling ⚠️ **CRITICAL**

**Problem:**
```
Connection string invalid: host:5432:5432/db
Port duplicated in connection string
```

**Root Cause:**
- `postgres_host` in ConfigMap included port (`:5432`)
- Application code also appended port, causing duplication

**Solution:**

**ConfigMap Structure:**
```yaml
data:
  postgres_host: "voting-app-dev-pg...rds.amazonaws.com"  # NO :5432
  postgres_port: "5432"  # Separate field
```

**Application Code:**
- Added `POSTGRES_PORT` environment variable
- Both result and worker services now read separate host and port fields

### 3. Redis AUTH Token Configuration

**Problem:**
```
Redis AuthenticationError: Client sent AUTH, but no password is set
```

**Root Cause:**
- ElastiCache has `transit_encryption_enabled=true` but `auth_token_enabled=false`
- Application was sending empty password causing AUTH command to be sent

**Solution:**
- Removed `REDIS_PASSWORD` environment variable from deployments
- Updated `vote/app.py` to strip empty passwords:
```python
password = os.getenv('REDIS_PASSWORD', '').strip()
if not password:
    # Connect without AUTH
```

### 4. Socket.IO WebSocket Failures

**Problem:**
```
WebSocket connection failed: 400 Bad Request
Socket.IO polling fallback failing
```

**Root Cause:**
- ALB doesn't support WebSocket without specific configuration
- Socket.IO default path conflicts with ALB path-based routing

**Solution:**

**Ingress Annotations:**
```yaml
alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=3600
alb.ingress.kubernetes.io/backend-protocol-version: HTTP1
```

**Socket.IO Configuration:**
```javascript
// Server (result/server.js)
const io = socketIO(server, { path: '/result/socket.io' });

// Client (result/views/app.js)
var socket = io({ path: '/result/socket.io' });
```

### 5. Static Asset 404 Errors

**Problem:**
```
GET /stylesheets/style.css 404
GET /socket.io.js 404
```

**Root Cause:**
- Express static middleware serving from root path
- ALB routes to `/result` but assets loaded from `/`

**Solution:**

**Express Static Configuration:**
```javascript
app.use('/result', express.static(__dirname + '/views'));
```

**HTML Base Tag:**
```html
<base href="/result/">
```

### 6. Architecture Mismatch

**Problem:**
```
exec /app/app: exec format error
standard_init_linux.go:228: exec user process caused: exec format error
```

**Root Cause:**
- Images built on ARM Mac (M1/M2) not compatible with AMD64 EKS nodes

**Solution:**
- Build with platform flag: `docker build --platform linux/amd64`
- GitHub Actions runners already use AMD64 (no change needed)

### 7. Database Table Creation Race Condition

**Problem:**
```
ERROR: relation "votes" does not exist
```

**Root Cause:**
- Result service starts before worker creates `votes` table
- Worker creates table on startup, but result connects earlier

**Solution:**
```bash
# Restart result pods after worker successfully connects
kubectl rollout restart deployment/result -n voting-app
```

**Future Enhancement:** Add init container to wait for table existence

### 8. Subnet Deletion Blocked (Terraform Destroy)

**Problem:**
```
DependencyViolation: The subnet 'subnet-xxx' has dependencies and cannot be deleted
```

**Root Cause:**
- ALB network interfaces attached to subnets
- Terraform can't delete subnets with active ENIs

**Solution:**
```bash
# 1. Delete ingress first (triggers ALB deletion)
kubectl delete ingress voting-app-ingress-simple -n voting-app

# 2. Wait for ENI release (30-60 seconds)
aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=subnet-xxx

# 3. Retry Terraform destroy
terraform destroy
```

## Original Issues (In-Cluster Deployment)

## Original Issues (In-Cluster Deployment)

These issues were encountered during initial in-cluster deployment before migrating to AWS managed services.

### 1. Hardcoded Database Connection
**File:** `result/server.js`
- Had hardcoded connection string: `postgres://postgres:postgres@db/postgres`
- Wasn't using environment variables passed from Kubernetes

### 2. Missing Environment Variables
**File:** `k8s-specifications/result-deployment.yaml`
- Missing `POSTGRES_PORT` and `POSTGRES_DB` environment variables
- Result pods couldn't establish database connection

## Current Production Configuration

## Current Production Configuration

**Infrastructure:** All AWS managed services via Terraform
- **RDS PostgreSQL 15:** db.t3.micro, 20GB, encrypted, **SSL required**
- **ElastiCache Redis 7.0:** cache.t3.micro, transit encryption enabled, **no AUTH token**
- **EKS 1.32:** t3.medium nodes, AMD64 architecture
- **ALB:** Internet-facing, path-based routing (/vote, /result), WebSocket support

**Application Configuration:**
- ConfigMap: Separate `postgres_host` and `postgres_port` fields
- SSL enabled for RDS connections (Node.js and C#)
- No REDIS_PASSWORD environment variable
- Socket.IO path: `/result/socket.io`
- Static assets served under `/result` path
- Images built for `linux/amd64` platform

**Key Files Modified:**
1. `result/server.js` - SSL config, port handling, Socket.IO path, static serving
2. `worker/Program.cs` - SSL config, port handling
3. `vote/app.py` - Empty password handling
4. `k8s-specifications/configmap.yaml` - Separate host/port fields
5. `k8s-specifications/ingress-simple.yaml` - WebSocket annotations
6. `k8s-specifications/*-deployment.yaml` - Environment variables, imagePullPolicy

## Verification Commands

```bash
# Check all pods running
kubectl get pods -n voting-app

# Check database connectivity
kubectl exec -it deployment/worker -n voting-app -- nc -zv <postgres_host> 5432

# Check Redis connectivity
kubectl exec -it deployment/vote -n voting-app -- nc -zv <redis_host> 6379

# View logs
kubectl logs -f deployment/result -n voting-app
kubectl logs -f deployment/vote -n voting-app
kubectl logs -f deployment/worker -n voting-app

# Check ingress and ALB
kubectl get ingress -n voting-app
kubectl describe ingress voting-app-ingress-simple -n voting-app

# Get ALB DNS
kubectl get ingress voting-app-ingress-simple -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Test application
export ALB_DNS=$(kubectl get ingress voting-app-ingress-simple -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I http://${ALB_DNS}/vote
curl -I http://${ALB_DNS}/result

# Check ALB target health
aws elbv2 describe-target-health --target-group-arn <target-group-arn>
```

## Files Modified Summary

### Application Code
1. **result/server.js**
   - Added SSL configuration: `ssl: {rejectUnauthorized: false}`
   - Added POSTGRES_PORT environment variable handling
   - Configured Socket.IO path: `/result/socket.io`
   - Configured express.static under `/result` path
   - Enhanced error logging in async.retry

2. **worker/Program.cs**
   - Added SSL configuration: `SslMode=Require;Trust Server Certificate=true`
   - Added POSTGRES_PORT environment variable handling
   - Creates `votes` table on startup

3. **vote/app.py**
   - Added empty password handling for ElastiCache (strips whitespace)

### Kubernetes Manifests
4. **k8s-specifications/configmap.yaml**
   - Separated `postgres_host` (without port) and `postgres_port` fields
   - Set `redis_ssl: "true"` for ElastiCache

5. **k8s-specifications/ingress-simple.yaml**
   - Added sticky session annotation
   - Added HTTP1 protocol annotation for WebSocket support

6. **k8s-specifications/result-deployment.yaml**
   - Added `POSTGRES_PORT` and `POSTGRES_DB` env vars
   - Removed `REDIS_PASSWORD` env var
   - Set `imagePullPolicy: Always`

7. **k8s-specifications/worker-deployment.yaml**
   - Added `POSTGRES_PORT` env var
   - Removed `REDIS_PASSWORD` env var

8. **k8s-specifications/vote-deployment.yaml**
   - Removed `REDIS_PASSWORD` env var
   - Set `imagePullPolicy: Always`

### CI/CD
9. **.github/workflows/cd-deploy-eks.yml**
   - Added documentation notes about SSL requirements
   - Added note about ConfigMap structure (no port in postgres_host)

## Troubleshooting Reference

For comprehensive troubleshooting, see:
- **[TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md)** - All issues and solutions
- **[terraform/README.md](../terraform/README.md)** - Infrastructure troubleshooting
- **[IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md)** - Complete implementation overview

### Quick Fixes

**"no pg_hba.conf entry... no encryption"**
→ Add SSL configuration to database connection code

**"Invalid URL: host:5432:5432"**
→ Separate postgres_host and postgres_port in ConfigMap

**"Redis AuthenticationError"**
→ Remove REDIS_PASSWORD from deployment

**"WebSocket 400 Bad Request"**
→ Add ALB sticky sessions and HTTP1 protocol annotations

**"Socket.IO 404 errors"**
→ Configure Socket.IO path to `/result/socket.io` on both server and client

**"Static assets 404"**
→ Serve static files under `/result` path, add `<base href="/result/">`

**"exec format error"**
→ Build images with `--platform linux/amd64`

**"relation votes does not exist"**
→ Restart result pods after worker connects: `kubectl rollout restart deployment/result -n voting-app`

---

*This document is historical reference. For current issues, see [TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md)*
