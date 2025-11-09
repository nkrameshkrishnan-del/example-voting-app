# Infrastructure and CI/CD Implementation Summary

This document summarizes the complete infrastructure and CI/CD pipeline implementation for the voting application on AWS EKS.

**Last Updated:** November 2025  
**Status:** Production-Ready with Known Limitations

## Infrastructure Overview

### AWS Services Deployed

1. **Amazon EKS 1.32**
   - Managed Kubernetes cluster
   - 2-4 node managed node group (t3.medium)
   - Public endpoint with private worker nodes
   - Cluster creator admin access enabled
   - IRSA disabled (uses node IAM role)

2. **Amazon RDS PostgreSQL 15**
   - db.t3.micro instance
   - 20GB encrypted storage
   - SSL/TLS required for connections
   - Single-AZ deployment (dev)
   - 1-day backup retention

3. **Amazon ElastiCache Redis 7.0**
   - cache.t3.micro node
   - Transit encryption enabled
   - AUTH token disabled
   - Single-node cluster (dev)

4. **Amazon ECR**
   - Repositories: vote, result, worker, seed-data
   - Force delete enabled
   - Lifecycle policies configured

5. **Networking**
   - VPC: 10.0.0.0/16
   - 3 private subnets (10.0.1-3.0/24)
   - 3 public subnets (10.0.101-103.0/24)
   - Single shared NAT gateway
   - Internet Gateway for public subnets

6. **AWS Secrets Manager**
   - Database credentials
   - Redis credentials
   - Immediate deletion on destroy (recovery_window=0)

## Terraform Infrastructure

### Files Created

1. **`terraform/main.tf`**
   - VPC configuration (using terraform-aws-modules/vpc)
   - EKS cluster (using terraform-aws-modules/eks)
   - RDS PostgreSQL instance with security groups
   - ElastiCache Redis with security groups
   - ECR repositories with lifecycle policies
   - AWS Secrets Manager secrets

2. **`terraform/alb-controller.tf`**
   - IAM policy for AWS Load Balancer Controller
   - Downloads policy from main branch (includes all required permissions)
   - Attaches policy to EKS node role

3. **`terraform/external-secrets.tf`**
   - IAM policy for External Secrets Operator
   - Allows reading secrets from AWS Secrets Manager
   - Attaches policy to EKS node role

4. **`terraform/variables.tf`**
   - Comprehensive variable definitions
   - Default values for dev environment
   - GitHub Actions user ARN configuration

5. **`terraform/outputs.tf`**
   - Cluster endpoints and names
   - Database and Redis endpoints
   - ECR repository URLs
   - IAM role ARNs

6. **`terraform/providers.tf`**
   - AWS provider configuration
   - Kubernetes provider (post-cluster creation)

7. **`terraform/versions.tf`**
   - Terraform version constraints (>= 1.6.0)
   - Required provider versions

8. **`terraform/README.md`**
   - Comprehensive deployment guide
   - SSL/TLS configuration notes
   - Troubleshooting section
   - Production readiness checklist

## GitHub Actions Workflows

1. **`.github/workflows/ci-build-push.yml`**
   - CI pipeline that builds Docker images and pushes to Amazon ECR
   - Triggered on push to main/develop branches and pull requests
   - Uses matrix strategy to build vote, result, and worker services in parallel
   - Implements secure AWS authentication with OIDC

2. **`.github/workflows/cd-deploy-eks.yml`**
   - CD pipeline that deploys application to Amazon EKS
   - Triggered automatically after successful CI pipeline or manually
   - Handles image replacement, deployment, and health checks
   - Provides deployment summary and service endpoints

3. **`.github/workflows/cd-deploy-eks.yml`**
   - CD pipeline that deploys application to Amazon EKS
   - Triggered automatically after successful CI pipeline or manually
   - Handles image replacement, deployment, and health checks
   - Feature flags for External Secrets, ALB Controller, and Ingress
   - Conditional rollout restart for latest image tags
   - ALB health probe after deployment
   - Provides deployment summary and service endpoints

4. **`.github/workflows/README.md`**
   - Documentation for the workflows
   - Configuration instructions
   - Troubleshooting guide
   - Security best practices

## Application Code Changes

### Critical Fixes Applied

1. **SSL/TLS for PostgreSQL (result/server.js)**
   ```javascript
   const pool = new Pool({
     connectionString: connectionString,
     ssl: {
       rejectUnauthorized: false
     }
   });
   ```

2. **SSL/TLS for PostgreSQL (worker/Program.cs)**
   ```csharp
   var pgConnString = $"Host={pgHost};Port={pgPort};Username={pgUser};Password={pgPassword};Database=postgres;SslMode=Require;Trust Server Certificate=true;";
   ```

3. **Port Handling (result/server.js)**
   ```javascript
   var POSTGRES_PORT = process.env.POSTGRES_PORT || '5432';
   var connectionString = `postgres://${USER}:${PASS}@${HOST}:${PORT}/${DB}`;
   ```

4. **Port Handling (worker/Program.cs)**
   ```csharp
   var pgPort = Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432";
   ```

5. **Redis AUTH Removal (vote/app.py)**
   - Added logic to strip empty/whitespace passwords
   - ElastiCache has transit encryption but no AUTH token

6. **Socket.IO Path Configuration (result/server.js)**
   ```javascript
   const io = require('socket.io')(server, {
     path: '/result/socket.io'
   });
   ```

7. **Socket.IO Client Configuration (result/views/app.js)**
   ```javascript
   var socket = io.connect({ path: '/result/socket.io' });
   ```

8. **Static Asset Serving (result/server.js)**
   ```javascript
   app.use('/result/stylesheets', express.static(path.join(__dirname, 'views', 'stylesheets')));
   app.use('/result', express.static(path.join(__dirname, 'views'), { index: false }));
   ```

9. **Base HREF (result/views/index.html)**
   ```html
   <base href="/result/">
   ```

## Kubernetes Manifests

4. **`k8s-specifications/configmap.yaml`**
   - ConfigMap for application configuration
   - Separate host and port fields for PostgreSQL
   - Redis SSL configuration
   - **Critical**: postgres_host should NOT include port

5. **`k8s-specifications/ingress-simple.yaml`** (Created)
   - Path-based routing (/vote, /result, /static, /)
   - ALB annotations for WebSocket support
   - Sticky sessions for Socket.IO
   - Single ALB for cost optimization

6. **`k8s-specifications/external-secrets/`** (Created)
   - ClusterSecretStore for AWS Secrets Manager
   - ExternalSecret definitions for db-secret and redis-secret
   - Automatic sync from AWS to Kubernetes

### Modified Kubernetes Deployments

7. **`k8s-specifications/vote-deployment.yaml`** (Modified)
   - Updated to use ECR images
   - Added environment variables for AWS ElastiCache
   - Removed REDIS_PASSWORD (AUTH disabled)
   - imagePullPolicy: Always
   - Increased replicas to 2

8. **`k8s-specifications/result-deployment.yaml`** (Modified)
   - Updated to use ECR images
   - Added POSTGRES_PORT environment variable
   - Added POSTGRES_DB environment variable
   - imagePullPolicy: Always
   - Increased replicas to 2

9. **`k8s-specifications/worker-deployment.yaml`** (Modified)
   - Updated to use ECR images
   - Added POSTGRES_PORT environment variable
   - Removed REDIS_PASSWORD
   - Single replica (stateless background worker)

## Documentation Files

9. **`docs/AWS_SETUP.md`**
   - Comprehensive AWS infrastructure setup guide (legacy, now using Terraform)
   - Manual setup instructions for reference
   - Troubleshooting section

10. **`docs/CI_CD_QUICKSTART.md`**
    - Quick start guide for CI/CD pipeline
    - Prerequisites checklist
    - GitHub secrets configuration
    - Pipeline workflow explanation

11. **`docs/DEPLOYMENT_CHECKLIST.md`**
    - Comprehensive deployment checklist
    - Phase-by-phase deployment guide
    - Verification steps

12. **`docs/DEPLOYMENT_FIX.md`**
    - Documents historical deployment issues and fixes
    - Database connection troubleshooting
    - Environment variable configuration

13. **`docs/EKS_ACCESS_FIX.md`**
    - EKS cluster access configuration
    - GitHub Actions IAM setup
    - Access entry configuration

14. **`docs/INGRESS_SETUP.md`**
    - ALB ingress configuration guide
    - Path-based vs host-based routing
    - SSL/HTTPS setup instructions
    - WebSocket configuration

15. **`docs/EXTERNAL_SECRETS.md`**
    - External Secrets Operator integration
    - AWS Secrets Manager configuration
    - Secret synchronization setup

16. **`docs/MANUAL_DEPLOYMENT.md`**
    - Step-by-step manual deployment instructions
    - Alternative to CI/CD pipeline
    - Useful for troubleshooting

17. **`docs/TROUBLESHOOTING_GUIDE.md`** (New)
    - Comprehensive troubleshooting guide
    - Database, Redis, Socket.IO issues
    - Architecture and infrastructure problems
    - Debugging commands and diagnostics

18. **`terraform/README.md`**
    - Terraform usage guide
    - Configuration details for all services
    - SSL requirements documentation
    - Cleanup procedures
    - Production readiness checklist

## File Structure

```
example-voting-app/
├── .github/
│   └── workflows/
│       ├── ci-build-push.yml          # CI workflow
│       ├── cd-deploy-eks.yml          # CD workflow
│       └── README.md                  # Workflows documentation
├── docs/
│   ├── AWS_SETUP.md                   # AWS infrastructure guide
│   └── CI_CD_QUICKSTART.md            # Quick start guide
├── k8s-specifications/
│   ├── configmap.yaml                 # Application ConfigMap
│   ├── secrets.yaml                   # Secrets template
│   ├── vote-deployment.yaml           # Modified
│   ├── result-deployment.yaml         # Modified
│   ├── worker-deployment.yaml         # Modified
│   ├── db-deployment.yaml             # Existing (optional for AWS RDS)
│   ├── db-service.yaml                # Existing
│   ├── redis-deployment.yaml          # Existing (optional for ElastiCache)
│   ├── redis-service.yaml             # Existing
│   ├── vote-service.yaml              # Existing
│   └── result-service.yaml            # Existing
├── vote/                              # Existing
├── result/                            # Existing
├── worker/                            # Existing
└── README.md                          # Modified

```

## Key Features Implemented

### 1. Infrastructure as Code
- ✅ Complete Terraform automation for all AWS resources
- ✅ Modular VPC and EKS configuration
- ✅ Automated security group and IAM policy management
- ✅ Secrets stored in AWS Secrets Manager
- ✅ ECR lifecycle policies for image management

### 2. Continuous Integration (CI)
- ✅ Automated Docker image builds for AMD64 architecture
- ✅ Push to Amazon ECR
- ✅ Multi-service matrix build strategy
- ✅ Image tagging (latest, branch, SHA)
- ✅ Build caching for faster builds
- ✅ Secure AWS authentication

### 3. Continuous Deployment (CD)
- ✅ Automated EKS deployment
- ✅ Dynamic image tag replacement
- ✅ Namespace management
- ✅ ConfigMap and Secret application via External Secrets
- ✅ Rolling updates with health checks
- ✅ Feature flags (External Secrets, ALB Controller, Ingress)
- ✅ Conditional rollout restart for latest tags
- ✅ ALB health probes
- ✅ Deployment status reporting
- ✅ Service endpoint discovery

### 4. AWS Integration
- ✅ Amazon ECR for container registry
- ✅ Amazon EKS for Kubernetes orchestration
- ✅ Amazon ElastiCache (Redis) with SSL
- ✅ Amazon RDS (PostgreSQL) with SSL
- ✅ AWS Secrets Manager integration
- ✅ VPC and security group configuration
- ✅ Application Load Balancer with path-based routing

### 5. Security
- ✅ SSL/TLS required for RDS connections
- ✅ Transit encryption for ElastiCache
- ✅ Kubernetes Secrets synced from AWS Secrets Manager
- ✅ Private subnets for databases
- ✅ Security group restrictions
- ✅ Encryption at rest for RDS/ElastiCache
- ✅ IAM policies with least privilege (per service)
- ⚠️ IRSA disabled (manual override - uses node IAM role)

### 6. High Availability
- ✅ Multiple replicas for vote and result services
- ✅ Auto-scaling ready (HPA configurable)
- ✅ Multi-AZ subnet deployment
- ✅ Application Load Balancer with health checks
- ✅ RDS automated backups (1 day retention)
- ⚠️ Single NAT gateway (cost optimization, not HA)

### 7. Monitoring and Operations
- ✅ Deployment status reporting in GitHub Actions
- ✅ GitHub Actions workflow logs
- ✅ CloudWatch integration ready
- ✅ Kubernetes events and logs
- ✅ Service endpoint display
- ✅ ALB health probe validation

### 8. Application Features
- ✅ Real-time vote updates via Socket.IO
- ✅ WebSocket support through ALB
- ✅ Sticky sessions for Socket.IO
- ✅ Path-based routing (/vote, /result)
- ✅ Static asset serving under /result path
- ✅ Persistent vote storage in PostgreSQL
- ✅ Vote queue in Redis

## Critical Issues Resolved

### 1. RDS SSL/TLS Requirement
**Problem:** Pods couldn't connect to RDS - "no pg_hba.conf entry... no encryption"  
**Solution:** Added SSL configuration to Node.js (pg library) and C# (Npgsql) connection strings

### 2. Redis AUTH Token Configuration
**Problem:** Redis AuthenticationError with empty password  
**Solution:** ElastiCache has transit encryption but no AUTH token - removed REDIS_PASSWORD env var

### 3. ConfigMap Port Handling
**Problem:** Connection string included port twice (host:5432:5432)  
**Solution:** Separated postgres_host and postgres_port in ConfigMap

### 4. Socket.IO WebSocket Failures
**Problem:** 400 Bad Request on Socket.IO, WebSocket connection failures  
**Solution:** Added ALB sticky sessions and HTTP1 protocol annotations

### 5. Socket.IO Path Routing
**Problem:** 404 errors on /socket.io/ path  
**Solution:** Configured Socket.IO server and client with /result/socket.io path

### 6. Static Asset 404 Errors
**Problem:** CSS and JS files returning 404  
**Solution:** Configured express.static to serve under /result path, added base href

### 7. Architecture Mismatch
**Problem:** "exec format error" on ARM-built images  
**Solution:** Build images with --platform linux/amd64 for EKS nodes

### 8. Votes Table Missing
**Problem:** Result service "relation votes does not exist"  
**Solution:** Worker creates table; restart result pods after worker connects

### 9. ALB Controller Permissions
**Problem:** AccessDenied on DescribeListenerAttributes  
**Solution:** Use IAM policy from main branch instead of v2.7.0

### 10. Subnet Deletion Blocked
**Problem:** DependencyViolation on subnet deletion during terraform destroy  
**Solution:** Delete ingress/ALB first, wait for ENI release, then destroy

## Next Steps

### Completed ✅
1. ✅ Create AWS Infrastructure via Terraform
2. ✅ Configure GitHub Secrets for CI/CD
3. ✅ Deploy External Secrets Operator
4. ✅ Deploy AWS Load Balancer Controller
5. ✅ Configure application for SSL/TLS connections
6. ✅ Set up path-based ALB ingress
7. ✅ Configure Socket.IO for WebSocket support
8. ✅ Fix all connectivity and routing issues
9. ✅ Document all configurations and troubleshooting

### Recommended for Production

1. **Enable IRSA**
   - Re-enable OIDC provider in EKS
   - Create pod-level IAM roles
   - Implement least privilege access per service

2. **High Availability**
   - Enable multi-AZ NAT gateways
   - Configure RDS Multi-AZ
   - Add ElastiCache replica nodes
   - Implement cluster autoscaler

3. **Monitoring and Alerting**
   - Install Prometheus and Grafana
   - Set up CloudWatch Container Insights
   - Configure PagerDuty/SNS alerts
   - Enable EKS audit logging

4. **Security Hardening**
   - Implement pod security policies/standards
   - Add network policies
   - Enable AWS WAF for ALB
   - Rotate secrets regularly
   - Use private EKS endpoint
   - Implement AWS Shield for DDoS protection

5. **Cost Optimization**
   - Implement cluster autoscaler
   - Use Spot instances for non-critical workloads
   - Right-size instance types
   - Set up cost alerts and budgets
   - Review and optimize resource requests/limits

6. **Testing and Quality**
   - Add unit tests in CI pipeline
   - Implement integration tests
   - Add security scanning (Trivy, Snyk)
   - Implement smoke tests post-deployment
   - Add load testing

7. **GitOps Implementation**
   - Set up ArgoCD or Flux
   - Implement pull-based deployments
   - Add drift detection
   - Automate configuration sync

8. **Backup and Disaster Recovery**
   - Configure automated RDS snapshots
   - Implement cross-region backups
   - Document and test DR procedures
   - Set up cross-region replication
   - Create restore runbooks

## Support and Troubleshooting

For comprehensive troubleshooting guidance, see:
- **[TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md)** - Complete guide covering all common issues
- **[terraform/README.md](../terraform/README.md)** - Infrastructure-specific troubleshooting

### Quick Reference

**Database Connection Issues:**
```bash
# Check RDS connectivity
kubectl exec -it <worker-pod> -- sh
nc -zv <postgres_host> 5432

# Verify SSL configuration in code
# Node.js: Pool config must include ssl: {rejectUnauthorized: false}
# C#: Connection string must include SslMode=Require;Trust Server Certificate=true
```

**Redis Connection Issues:**
```bash
# ElastiCache requires transit encryption but NO AUTH token
# Remove REDIS_PASSWORD from environment variables
# Python: Handle empty password with strip() logic
```

**Socket.IO WebSocket Failures:**
```bash
# Verify ALB annotations in ingress
alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true
alb.ingress.kubernetes.io/backend-protocol-version: HTTP1

# Check Socket.IO path configuration (server and client must match)
# Server: io(server, { path: '/result/socket.io' })
# Client: io({ path: '/result/socket.io' })
```

**Pod Debugging:**
```bash
# View logs
kubectl logs -f <pod-name>

# Check environment variables
kubectl exec <pod-name> -- env | grep POSTGRES

# Verify ConfigMap
kubectl describe configmap app-config

# Test DNS resolution
kubectl exec <pod-name> -- nslookup <postgres_host>
```

**ALB Health Checks:**
```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
  --query 'TargetGroups[?TargetGroupName==`<name>`].TargetGroupArn' \
  --output text)

# View ingress status
kubectl describe ingress voting-app-ingress
```

See [TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md) for complete diagnostic procedures and solutions.

## Contributing

When making changes to the infrastructure or CI/CD pipeline:

1. Test changes in a feature branch
2. Update documentation if needed
3. Verify workflow syntax and Terraform plans
4. Test deployment in a non-production environment
5. Create pull request with detailed description
6. Update TROUBLESHOOTING_GUIDE.md if encountering new issues

## Version History

### November 2025 - Production Deployment ✅
- ✅ Complete AWS infrastructure deployed via Terraform
- ✅ CI/CD pipeline operational with GitHub Actions
- ✅ All services connected to AWS managed services (RDS, ElastiCache)
- ✅ SSL/TLS connections configured for RDS
- ✅ Socket.IO WebSocket support with ALB sticky sessions
- ✅ Path-based routing operational (/vote, /result)
- ✅ Comprehensive documentation and troubleshooting guides

### October 2025 - Initial Implementation
- Infrastructure as Code (Terraform)
- GitHub Actions CI/CD pipeline
- Kubernetes manifests
- AWS integration planning

### Key Milestones
- **Infrastructure:** VPC, EKS 1.32, RDS PostgreSQL 15, ElastiCache Redis 7.0, ALB, ECR
- **Application:** SSL fixes, ConfigMap restructuring, WebSocket configuration
- **Documentation:** 18 comprehensive guides including troubleshooting and deployment procedures
- **Known Limitations:** IRSA disabled, single NAT gateway, external-dns not configured

---

*For questions or issues, consult [TROUBLESHOOTING_GUIDE.md](TROUBLESHOOTING_GUIDE.md) or check pod logs with `kubectl logs -f <pod-name>`*
