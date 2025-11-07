# AWS Infrastructure Setup for Voting App

This guide covers the setup of AWS infrastructure required to deploy the voting application on Amazon EKS with managed AWS services.

## Prerequisites

- AWS CLI installed and configured
- kubectl installed
- eksctl installed (recommended for EKS cluster creation)
- Docker installed
- GitHub repository with appropriate permissions

## Architecture Overview

The application uses the following AWS services:
- **Amazon EKS**: Kubernetes cluster for container orchestration
- **Amazon ECR**: Container registry for Docker images
- **Amazon ElastiCache (Redis)**: Managed Redis for vote queue
- **Amazon RDS (PostgreSQL)**: Managed database for storing votes
- **AWS IAM**: Identity and access management for OIDC authentication

## Step 1: Create ECR Repositories

Create three ECR repositories for the application components:

```bash
aws ecr create-repository --repository-name vote --region us-east-1
aws ecr create-repository --repository-name result --region us-east-1
aws ecr create-repository --repository-name worker --region us-east-1
```

Note the repository URIs from the output.

## Step 2: Create VPC and Security Groups

### Create VPC (or use existing)

```bash
# Create VPC with public and private subnets
aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=voting-app-vpc}]'
```

### Create Security Groups

```bash
# Security group for EKS nodes
aws ec2 create-security-group \
  --group-name eks-node-sg \
  --description "Security group for EKS worker nodes" \
  --vpc-id <VPC_ID>

# Security group for ElastiCache
aws ec2 create-security-group \
  --group-name elasticache-sg \
  --description "Security group for ElastiCache Redis" \
  --vpc-id <VPC_ID>

# Allow EKS nodes to access ElastiCache
aws ec2 authorize-security-group-ingress \
  --group-id <ELASTICACHE_SG_ID> \
  --protocol tcp \
  --port 6379 \
  --source-group <EKS_NODE_SG_ID>

# Security group for RDS
aws ec2 create-security-group \
  --group-name rds-sg \
  --description "Security group for RDS PostgreSQL" \
  --vpc-id <VPC_ID>

# Allow EKS nodes to access RDS
aws ec2 authorize-security-group-ingress \
  --group-id <RDS_SG_ID> \
  --protocol tcp \
  --port 5432 \
  --source-group <EKS_NODE_SG_ID>
```

## Step 3: Create EKS Cluster

### Using eksctl (Recommended)

Create a cluster configuration file `eks-cluster-config.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: voting-app-cluster
  region: us-east-1
  version: "1.28"

vpc:
  id: "<VPC_ID>"
  subnets:
    private:
      us-east-1a:
        id: "<PRIVATE_SUBNET_1_ID>"
      us-east-1b:
        id: "<PRIVATE_SUBNET_2_ID>"

managedNodeGroups:
  - name: voting-app-nodes
    instanceType: t3.medium
    desiredCapacity: 3
    minSize: 2
    maxSize: 5
    privateNetworking: true
    labels:
      role: worker
    tags:
      Environment: production
      Application: voting-app
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        cloudWatch: true

iam:
  withOIDC: true
```

Create the cluster:

```bash
eksctl create cluster -f eks-cluster-config.yaml
```

### Update kubeconfig

```bash
aws eks update-kubeconfig --name voting-app-cluster --region us-east-1
```

## Step 4: Create ElastiCache Redis Cluster

### Create Subnet Group

```bash
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name voting-app-redis-subnet \
  --cache-subnet-group-description "Subnet group for voting app Redis" \
  --subnet-ids <PRIVATE_SUBNET_1_ID> <PRIVATE_SUBNET_2_ID>
```

### Create Redis Cluster

```bash
aws elasticache create-cache-cluster \
  --cache-cluster-id voting-app-redis \
  --cache-node-type cache.t3.micro \
  --engine redis \
  --engine-version 7.0 \
  --num-cache-nodes 1 \
  --cache-subnet-group-name voting-app-redis-subnet \
  --security-group-ids <ELASTICACHE_SG_ID> \
  --preferred-availability-zone us-east-1a \
  --port 6379 \
  --transit-encryption-enabled \
  --auth-token "YourSecureAuthToken123!"
```

**Note:** For production, consider using ElastiCache Replication Group for high availability.

### Get Redis Endpoint

```bash
aws elasticache describe-cache-clusters \
  --cache-cluster-id voting-app-redis \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
  --output text
```

## Step 5: Create RDS PostgreSQL Database

### Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name voting-app-db-subnet \
  --db-subnet-group-description "Subnet group for voting app database" \
  --subnet-ids <PRIVATE_SUBNET_1_ID> <PRIVATE_SUBNET_2_ID>
```

### Create RDS Instance

```bash
aws rds create-db-instance \
  --db-instance-identifier voting-app-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15.4 \
  --master-username postgres \
  --master-user-password YourSecurePassword123! \
  --allocated-storage 20 \
  --db-subnet-group-name voting-app-db-subnet \
  --vpc-security-group-ids <RDS_SG_ID> \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "sun:04:00-sun:05:00" \
  --storage-encrypted \
  --no-publicly-accessible
```

### Get RDS Endpoint

```bash
aws rds describe-db-instances \
  --db-instance-identifier voting-app-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

## Step 6: Set Up IAM OIDC Provider for GitHub Actions

### Create OIDC Provider

```bash
# Get your EKS cluster OIDC issuer URL
OIDC_ISSUER=$(aws eks describe-cluster --name voting-app-cluster --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

# Create OIDC provider
aws iam create-open-id-connect-provider \
  --url "https://${OIDC_ISSUER}" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
```

### Create IAM Role for GitHub Actions

Create a trust policy file `github-actions-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<REPO_NAME>:*"
        }
      }
    }
  ]
}
```

Create the role:

```bash
aws iam create-role \
  --role-name GitHubActionsVotingAppRole \
  --assume-role-policy-document file://github-actions-trust-policy.json
```

### Attach Policies to Role

```bash
# ECR permissions
aws iam attach-role-policy \
  --role-name GitHubActionsVotingAppRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

# EKS permissions
aws iam attach-role-policy \
  --role-name GitHubActionsVotingAppRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

Create a custom policy for EKS access `eks-deploy-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam create-policy \
  --policy-name EKSDeployPolicy \
  --policy-document file://eks-deploy-policy.json

aws iam attach-role-policy \
  --role-name GitHubActionsVotingAppRole \
  --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/EKSDeployPolicy
```

## Step 7: Configure Kubernetes RBAC for GitHub Actions

Create a ClusterRole and ClusterRoleBinding:

```bash
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: github-actions-deployer
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: github-actions-deployer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: github-actions-deployer
subjects:
- kind: User
  name: github-actions
  apiGroup: rbac.authorization.k8s.io
EOF
```

Map the IAM role to Kubernetes RBAC:

```bash
kubectl edit configmap aws-auth -n kube-system
```

Add the following under `mapRoles`:

```yaml
- rolearn: arn:aws:iam::<AWS_ACCOUNT_ID>:role/GitHubActionsVotingAppRole
  username: github-actions
  groups:
    - system:masters
```

## Step 8: Configure GitHub Secrets

Add the following secrets to your GitHub repository (Settings → Secrets and variables → Actions):

- `AWS_ACCOUNT_ID`: Your AWS account ID
- `AWS_ROLE_ARN`: ARN of the GitHubActionsVotingAppRole
- `REDIS_AUTH_TOKEN`: ElastiCache AUTH token (if enabled)
- `DB_PASSWORD`: RDS PostgreSQL password

## Step 9: Update Kubernetes ConfigMap

Update `k8s-specifications/configmap.yaml` with your actual endpoints:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  redis_host: "voting-app-redis.xxxxx.0001.use1.cache.amazonaws.com"
  redis_port: "6379"
  redis_ssl: "true"
  postgres_host: "voting-app-db.xxxxx.us-east-1.rds.amazonaws.com"
```

## Step 10: Create Kubernetes Secrets

```bash
kubectl create secret generic redis-secret \
  --from-literal=password='YourSecureAuthToken123!' \
  -n voting-app

kubectl create secret generic db-secret \
  --from-literal=username='postgres' \
  --from-literal=password='YourSecurePassword123!' \
  -n voting-app
```

**Better approach:** Use AWS Secrets Manager with External Secrets Operator:

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace
```

## Step 11: Deploy Application

Push code to the `main` branch to trigger the CI/CD pipeline:

```bash
git add .
git commit -m "Configure AWS infrastructure"
git push origin main
```

The GitHub Actions workflows will:
1. Build Docker images and push to ECR
2. Deploy to EKS cluster

## Step 12: Verify Deployment

```bash
# Check deployments
kubectl get deployments -n voting-app

# Check pods
kubectl get pods -n voting-app

# Check services
kubectl get services -n voting-app

# Get Load Balancer URLs
kubectl get service vote -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl get service result -n voting-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Step 13: Configure Service Exposure (Optional)

### Option 1: Using LoadBalancer Service (Default)

The services are already configured as LoadBalancer type.

### Option 2: Using Ingress with ALB

Install AWS Load Balancer Controller:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=voting-app-cluster
```

Create an Ingress resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: voting-app-ingress
  namespace: voting-app
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - host: vote.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vote
            port:
              number: 80
  - host: result.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: result
            port:
              number: 80
```

## Monitoring and Logging

### Install CloudWatch Container Insights

```bash
aws eks create-addon \
  --cluster-name voting-app-cluster \
  --addon-name amazon-cloudwatch-observability
```

### Install Prometheus and Grafana (Optional)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

## Cleanup

To avoid AWS charges, delete resources when no longer needed:

```bash
# Delete EKS cluster
eksctl delete cluster --name voting-app-cluster

# Delete RDS instance
aws rds delete-db-instance --db-instance-identifier voting-app-db --skip-final-snapshot

# Delete ElastiCache cluster
aws elasticache delete-cache-cluster --cache-cluster-id voting-app-redis

# Delete ECR repositories
aws ecr delete-repository --repository-name vote --force
aws ecr delete-repository --repository-name result --force
aws ecr delete-repository --repository-name worker --force

# Delete security groups, subnet groups, and VPC
```

## Troubleshooting

### Pods not starting
```bash
kubectl describe pod <pod-name> -n voting-app
kubectl logs <pod-name> -n voting-app
```

### Cannot connect to Redis/RDS
- Check security group rules
- Verify endpoints in ConfigMap
- Check secrets are created correctly

### GitHub Actions failing
- Verify AWS credentials and IAM role
- Check OIDC provider is configured correctly
- Ensure all required secrets are set in GitHub

## Cost Optimization

- Use Spot Instances for EKS node groups
- Enable Auto Scaling for node groups
- Use appropriate instance sizes (t3.micro/small for non-production)
- Set up cost alerts in AWS Cost Explorer
- Consider using Savings Plans or Reserved Instances

## Security Best Practices

1. Use AWS Secrets Manager for sensitive data
2. Enable encryption at rest for RDS and ElastiCache
3. Use VPC endpoints to avoid internet traffic
4. Implement network policies in Kubernetes
5. Regular security scanning of container images
6. Enable AWS GuardDuty for threat detection
7. Use IAM roles for service accounts (IRSA)
8. Implement Pod Security Standards
