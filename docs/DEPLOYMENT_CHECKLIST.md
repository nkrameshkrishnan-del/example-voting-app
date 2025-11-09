# Deployment Checklist

Use this checklist to ensure all steps are completed before deploying the Voting App to AWS EKS.

## Terraform Coverage Summary

| Section | Terraform Coverage | Manual Items Remaining |
|---------|--------------------|------------------------|
| ECR Repositories | Full (repos created) | Verify URIs, permissions |
| Networking (VPC, Subnets, SGs) | Full | Review CIDRs & SG rules |
| EKS Cluster | Core cluster provisioned | OIDC provider, ALB Controller install, Metrics Server |
| ElastiCache (Redis) | Cluster + SG if enabled | AUTH decision, connectivity test |
| RDS (PostgreSQL) | Instance + SG if enabled | Password rotation, connectivity & SSL verify |
| IAM (GitHub Actions Role) | None | Create role, trust policy, RBAC mapping |
| GitHub Repo Secrets | None | Add secrets to repository |
| Kubernetes Manifests | None | Apply ConfigMap, Secrets, Deployments, Ingress |
| Ingress / ALB | Part (IAM for controller) | Helm install controller, apply ingress YAML |
| Monitoring Stack | None | Install Prometheus/Grafana/CloudWatch setup |

Badge Legend:
`(Skip if Terraform)` – Step fully handled by Terraform.
`(Partial Terraform)` – Some resources created; complete remaining manual tasks.
`(Manual)` – Fully manual.

## Phase 1: Prerequisites

- [ ] AWS Account with appropriate permissions
- [ ] AWS CLI installed and configured
- [ ] kubectl installed (v1.28+)
- [ ] eksctl installed (optional but recommended)
- [ ] Docker installed locally
- [ ] GitHub repository with admin access
- [ ] Domain name (optional, for ingress)

## Phase 2: AWS Infrastructure Setup

### ECR Repositories (Skip if Terraform)
- [ ] Create ECR repository for `vote` service
- [ ] Create ECR repository for `result` service
- [ ] Create ECR repository for `worker` service
- [ ] Note down ECR repository URIs

### Networking (Skip if Terraform)
- [ ] Create or identify VPC for EKS
- [ ] Create or identify private subnets (minimum 2 AZs)
- [ ] Create or identify public subnets (minimum 2 AZs)
- [ ] Create security group for EKS nodes
- [ ] Create security group for ElastiCache
- [ ] Create security group for RDS
- [ ] Configure security group rules (ingress/egress)

### EKS Cluster (Partial Terraform)
- [ ] (Optional) Create EKS cluster manually with eksctl (Skip if Terraform):
  ```bash
  eksctl create cluster \
    --name voting-app-cluster \
    --region us-east-1 \
    --version 1.32 \
    --nodes 3 \
    --node-type t3.medium \
    --with-oidc
  ```
- [ ] Verify cluster creation: `kubectl get nodes`
- [ ] Enable OIDC provider for the cluster (Manual)
- [ ] Install AWS Load Balancer Controller (Manual)
- [ ] Install Metrics Server (Manual)

### ElastiCache (Redis) (Partial Terraform)
- [ ] Create ElastiCache subnet group
- [ ] Create Redis cluster or replication group
- [ ] Enable AUTH token (recommended for production)
- [ ] Enable encryption in transit
- [ ] Note down Redis endpoint
- [ ] Test connectivity from EKS nodes

### RDS (PostgreSQL) (Partial Terraform)
- [ ] Create RDS subnet group
- [ ] Create PostgreSQL instance
- [ ] Configure master username and password
- [ ] Enable encryption at rest
- [ ] Configure backup retention
- [ ] Note down RDS endpoint
- [ ] Test connectivity from EKS nodes

## Phase 3: IAM Configuration

### OIDC Provider for GitHub Actions (Manual)
- [ ] Create OIDC provider for GitHub Actions
- [ ] Note down OIDC provider ARN

### IAM Role for GitHub Actions (Manual)
- [ ] Create trust policy JSON file
- [ ] Update trust policy with your GitHub org/repo
- [ ] Create IAM role: `GitHubActionsVotingAppRole`
- [ ] Attach `AmazonEC2ContainerRegistryPowerUser` policy
- [ ] Attach `AmazonEKSClusterPolicy` policy
- [ ] Create and attach custom EKS deploy policy
- [ ] Note down role ARN

### Kubernetes RBAC (Manual)
- [ ] Create ClusterRole for GitHub Actions
- [ ] Create ClusterRoleBinding
- [ ] Update `aws-auth` ConfigMap with IAM role mapping
- [ ] Test RBAC: `kubectl auth can-i get pods --as=github-actions`

## Phase 4: GitHub Configuration

### Repository Secrets (Manual)
- [ ] Add `AWS_ACCOUNT_ID` secret
- [ ] Add `AWS_ROLE_ARN` secret
- [ ] Add `REDIS_AUTH_TOKEN` secret (if using AUTH)
- [ ] Add `DB_PASSWORD` secret

### Workflow Files (Manual)
- [ ] Review `.github/workflows/ci-build-push.yml`
- [ ] Update AWS region if needed
- [ ] Review `.github/workflows/cd-deploy-eks.yml`
- [ ] Update EKS cluster name if needed
- [ ] Update AWS region if needed

## Phase 5: Kubernetes Configuration

### Namespace (Manual)
- [ ] Create namespace: `kubectl create namespace voting-app`
- [ ] Set as default (optional): `kubectl config set-context --current --namespace=voting-app`

### ConfigMap (Manual)
- [ ] Update `k8s-specifications/configmap.yaml` with actual endpoints
  - [ ] Redis endpoint
  - [ ] Redis port
  - [ ] Redis SSL setting
  - [ ] PostgreSQL endpoint
- [ ] Apply ConfigMap: `kubectl apply -f k8s-specifications/configmap.yaml -n voting-app`
- [ ] Verify: `kubectl get configmap app-config -n voting-app -o yaml`

### Secrets (Manual)
- [ ] Create Redis secret:
  ```bash
  kubectl create secret generic redis-secret \
    --from-literal=password='YOUR_REDIS_PASSWORD' \
    -n voting-app
  ```
- [ ] Create DB secret:
  ```bash
  kubectl create secret generic db-secret \
    --from-literal=username='postgres' \
    --from-literal=password='YOUR_DB_PASSWORD' \
    -n voting-app
  ```
- [ ] Verify secrets created: `kubectl get secrets -n voting-app`

### Service Configuration (Optional, Manual)
- [ ] Review `k8s-specifications/vote-service.yaml`
- [ ] Review `k8s-specifications/result-service.yaml`
- [ ] Update service types if needed (LoadBalancer/NodePort/ClusterIP)
- [ ] Configure ingress if using ALB (optional)

## Phase 6: Initial Deployment

### Manual Build and Push (Optional, Manual)
- [ ] Test build locally for vote service
- [ ] Test build locally for result service
- [ ] Test build locally for worker service
- [ ] Manually push to ECR (optional, for testing)

### Trigger CI/CD Pipeline (Manual)
- [ ] Commit all changes
- [ ] Push to feature branch for testing
- [ ] Create pull request to main
- [ ] Review and merge to main
- [ ] Monitor GitHub Actions workflow
- [ ] Check CI pipeline completion
- [ ] Check CD pipeline completion

## Phase 7: Verification

### Deployment Status
- [ ] Check deployments: `kubectl get deployments -n voting-app`
- [ ] Check pods: `kubectl get pods -n voting-app`
- [ ] Check services: `kubectl get services -n voting-app`
- [ ] Check pod logs: `kubectl logs -f deployment/vote -n voting-app`
- [ ] Verify all pods are running
- [ ] Verify no CrashLoopBackOff errors

### Application Testing
- [ ] Get vote service URL/IP
- [ ] Access vote application in browser
- [ ] Test voting functionality
- [ ] Get result service URL/IP
- [ ] Access result application in browser
- [ ] Verify votes are recorded
- [ ] Test with multiple browsers/clients

### Redis Connectivity
- [ ] Verify vote app can connect to Redis
- [ ] Verify worker can connect to Redis
- [ ] Check Redis logs if using in-cluster Redis
- [ ] Verify votes are queued

### Database Connectivity
- [ ] Verify worker can connect to PostgreSQL
- [ ] Verify result app can connect to PostgreSQL
- [ ] Check database for vote records
- [ ] Verify vote updates in real-time

## Phase 8: Monitoring Setup (Optional)

### CloudWatch
- [ ] Enable Container Insights
- [ ] Create CloudWatch dashboard
- [ ] Set up log groups
- [ ] Configure metric alarms

### Prometheus/Grafana (Optional)
- [ ] Install Prometheus
- [ ] Install Grafana
- [ ] Import Kubernetes dashboards
- [ ] Configure alerts

## Phase 9: Post-Deployment

### Documentation
- [ ] Update internal documentation with endpoints
- [ ] Document any customizations made
- [ ] Create runbook for common operations
- [ ] Document rollback procedures

### Security Hardening
- [ ] Review security group rules
- [ ] Enable network policies in Kubernetes
- [ ] Set up Pod Security Standards
- [ ] Enable audit logging
- [ ] Run security scan on images
- [ ] Review IAM policies (least privilege)

### Backup and DR
- [ ] Configure RDS automated backups
- [ ] Test RDS snapshot restore
- [ ] Document disaster recovery plan
- [ ] Test rollback procedure
- [ ] Set up cross-region replication (optional)

### Cost Optimization
- [ ] Review resource requests/limits
- [ ] Set up cluster autoscaler
- [ ] Consider spot instances for non-critical workloads
- [ ] Set up AWS Cost Explorer
- [ ] Create cost alerts
- [ ] Review and optimize instance types

## Phase 10: Ongoing Operations

### Regular Tasks
- [ ] Monitor application health weekly
- [ ] Review logs for errors
- [ ] Check AWS costs
- [ ] Update dependencies monthly
- [ ] Patch security vulnerabilities
- [ ] Review and update documentation

### Scaling
- [ ] Configure Horizontal Pod Autoscaler
- [ ] Configure Cluster Autoscaler
- [ ] Test auto-scaling behavior
- [ ] Review and adjust resource limits

### Updates and Maintenance
- [ ] Plan for EKS version upgrades
- [ ] Plan for application updates
- [ ] Schedule maintenance windows
- [ ] Test updates in staging first

## Troubleshooting Checklist

If deployment fails, check:
- [ ] GitHub Actions logs for errors
- [ ] Pod status and events: `kubectl describe pod <name> -n voting-app`
- [ ] Pod logs: `kubectl logs <pod-name> -n voting-app`
- [ ] ConfigMap values: `kubectl get configmap app-config -n voting-app -o yaml`
- [ ] Secrets exist: `kubectl get secrets -n voting-app`
- [ ] Security group rules allow traffic
- [ ] IAM roles and policies are correct
- [ ] OIDC provider is configured
- [ ] ECR images exist and are accessible
- [ ] Redis endpoint is correct and reachable
- [ ] RDS endpoint is correct and reachable

## Success Criteria

Deployment is successful when:
- ✅ All pods are in Running state
- ✅ Vote application is accessible and functional
- ✅ Result application is accessible and shows votes
- ✅ Votes are persisted in database
- ✅ Real-time updates work in result app
- ✅ GitHub Actions workflows run successfully
- ✅ No errors in application logs
- ✅ All health checks pass

## Notes

- Keep this checklist updated as you make changes
- Check off items as you complete them
- Document any issues or deviations
- Share learnings with your team

## Quick Reference

### Useful Commands

```bash
# View all resources
kubectl get all -n voting-app

# Check pod logs
kubectl logs -f <pod-name> -n voting-app

# Describe pod
kubectl describe pod <pod-name> -n voting-app

# Get service endpoints
kubectl get svc -n voting-app

# Port forward for testing
kubectl port-forward svc/vote 8080:80 -n voting-app

# Execute command in pod
kubectl exec -it <pod-name> -n voting-app -- /bin/sh

# View recent events
kubectl get events -n voting-app --sort-by='.lastTimestamp'

# Check deployment status
kubectl rollout status deployment/vote -n voting-app

# Scale deployment
kubectl scale deployment vote --replicas=3 -n voting-app
```

---

**Last Updated:** 2025-11-06
**Version:** 1.0
