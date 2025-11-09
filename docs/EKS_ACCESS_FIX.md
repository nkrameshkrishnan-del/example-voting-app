# Fix EKS Cluster Access for GitHub Actions

## Problem
GitHub Actions CD workflow fails with authentication error:
```
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

This happens because the GitHub Actions IAM user/role isn't authorized to access the EKS cluster.

## Root Cause
- EKS cluster was created by IAM principal: `arn:aws:iam::703288805584:user/root_admin`
- GitHub Actions uses different IAM credentials (stored in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` secrets)
- EKS only grants automatic admin access to the cluster creator
- Additional IAM principals must be explicitly granted access

### Modern Access Model vs Legacy aws-auth
EKS (>=1.28) introduces *Access Entries* and *Access Policies* as a managed alternative to editing the `aws-auth` ConfigMap. This repository uses the modern Access Entries approach via Terraform. Avoid manual edits to `aws-auth` unless performing an emergency workaround.

| Method | Recommended | Risks |
|--------|-------------|-------|
| Access Entries (API) | Yes | None (managed by EKS) |
| aws-auth ConfigMap (legacy) | Only for migration | Drift, manual errors, unclear audit trail |

## Solution Steps

### Step 1: Identify GitHub Actions IAM User ARN

Run this command with the same credentials used in GitHub Actions:

```bash
aws sts get-caller-identity
```

This will return something like:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "703288805584",
    "Arn": "arn:aws:iam::703288805584:user/github-actions-user"
}
```

Copy the ARN value (e.g., `arn:aws:iam::703288805584:user/github-actions-user`).

### Step 2: Update Terraform with GitHub Actions ARN

There are two options:

#### Option A: Use terraform.tfvars (Recommended)

Create or edit `terraform/terraform.tfvars`:

```hcl
github_actions_user_arn = "arn:aws:iam::703288805584:user/YOUR_GITHUB_ACTIONS_USER"
```

#### Option B: Pass as command-line variable

```bash
cd terraform
terraform plan -var="github_actions_user_arn=arn:aws:iam::703288805584:user/YOUR_GITHUB_ACTIONS_USER"
terraform apply -var="github_actions_user_arn=arn:aws:iam::703288805584:user/YOUR_GITHUB_ACTIONS_USER"
```

### Step 3: Apply Terraform Changes

```bash
cd terraform
terraform plan
terraform apply
```

This will add the GitHub Actions IAM principal to the EKS cluster with admin permissions.

### Step 4: Verify Access

The GitHub Actions workflow should now be able to run kubectl commands successfully.

## Alternative: Quick Fix Using eksctl

If you need immediate access without running Terraform apply, you can manually add the IAM user:

```bash
# Get the GitHub Actions IAM ARN first
# Then run:
eksctl create iamidentitymapping \
  --cluster voting-app-cluster \
  --region us-east-1 \
  --arn arn:aws:iam::703288805584:user/YOUR_GITHUB_ACTIONS_USER \
  --username github-actions \
  --group system:masters
```

**Note**: If you use eksctl, Terraform may try to revert the change on next apply unless you also update the Terraform configuration.

## How It Works

The Terraform configuration now uses EKS Access Entries (the modern way to manage cluster access):

```hcl
access_entries = {
  github_actions = {
    principal_arn = var.github_actions_user_arn
    type          = "STANDARD"
    policy_associations = {
      admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  }
}
```

This grants the specified IAM principal cluster admin permissions, allowing it to:
- Run kubectl commands
- Deploy workloads
- Manage cluster resources
- Install Helm charts

## Using an IAM Role with OIDC (Recommended for GitHub Actions)

Instead of long-lived IAM user credentials, create an IAM role trusted by GitHub's OIDC provider.

1. Create IAM role trust policy (`github-oidc-trust.json`):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:ref:refs/heads/main"
        }
      }
    }
  ]
}
```
2. Create role (example):
```bash
aws iam create-role --role-name GitHubActionsVotingAppRole \
  --assume-role-policy-document file://github-oidc-trust.json
```
3. Attach minimal policies (avoid full admin):
```bash
aws iam attach-role-policy --role-name GitHubActionsVotingAppRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam attach-role-policy --role-name GitHubActionsVotingAppRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```
4. Add role ARN to Terraform variable `github_actions_user_arn` (even though name implies user it can be a role).
5. Terraform creates access entry mapping the role to cluster permissions.
6. In GitHub Actions workflow set:
```yaml
permissions:
  id-token: write
  contents: read
steps:
  - name: Configure AWS credentials
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsVotingAppRole
      aws-region: us-east-1
```

## Listing and Managing Access Entries

Commands to inspect current access configuration:
```bash
aws eks list-access-entries --cluster-name voting-app-cluster
aws eks describe-access-entry --cluster-name voting-app-cluster --principal-arn <PRINCIPAL_ARN>
aws eks list-access-policies
```
Associate a read-only policy to a principal (namespace scoped):
```bash
aws eks associate-access-policy \
  --cluster-name voting-app-cluster \
  --principal-arn <PRINCIPAL_ARN> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespace=voting-app
```
Detach a policy:
```bash
aws eks disassociate-access-policy --cluster-name voting-app-cluster --principal-arn <PRINCIPAL_ARN> --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy
```

## Enabling IRSA (Currently Disabled)

IRSA (IAM Roles for Service Accounts) allows pods to assume IAM roles without node-wide privileges.

Terraform currently sets `enable_irsa = false` for the EKS module. To enable:
1. Edit `terraform/main.tf` module "eks": set `enable_irsa = true`.
2. `terraform apply`.
3. Create service account with role annotation (example for AWS Load Balancer Controller):
```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/AWSLoadBalancerControllerRole
```
4. Reinstall controller Helm chart referencing that service account.

Benefits of IRSA:
- Eliminates need for broad node instance profile permissions.
- Supports fine-grained least-privilege per component.
- Improves auditability and reduces blast radius.

## Migrating from aws-auth to Access Entries

If legacy `aws-auth` mappings exist:
1. List current config: `kubectl get configmap aws-auth -n kube-system -o yaml`
2. Replicate each mapping with `aws eks create-access-entry` and `associate-access-policy`.
3. Remove legacy mapRoles/mapUsers entries one at a time, verifying access persists.
4. Keep a backup: `kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth-backup.yaml`.

## Extended Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| 403 Forbidden on kubectl | Principal lacks access policy | Add/associate access policy via EKS API |
| 401 Unauthorized | Expired or wrong AWS credentials | Reissue OIDC token / rotate secrets |
| "You must be logged in" | Missing access entry | Create access entry for principal ARN |
| sts get-caller-identity returns different ARN | Wrong credentials in workflow | Update GitHub Actions secrets or role-to-assume |
| Access entry exists but no permissions | Policy not associated | Associate cluster or namespace scope policy |
| Helm install fails with IAM errors | IRSA not enabled for pod | Enable IRSA or attach node role permissions |

Quick verification script:
```bash
aws sts get-caller-identity
aws eks describe-cluster --name voting-app-cluster --query 'cluster.status'
aws eks list-access-entries --cluster-name voting-app-cluster | jq '.accessEntries[] | {principalArn, accessPolicies}'
kubectl auth can-i list pods -n voting-app
```

## Least Privilege Example

For CI that only deploys to namespace `voting-app`:
```bash
aws eks associate-access-policy \
  --cluster-name voting-app-cluster \
  --principal-arn <PRINCIPAL_ARN> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSDeveloperPolicy \
  --access-scope type=namespace,namespace=voting-app
```
Then test:
```bash
kubectl auth can-i create deployment -n voting-app
kubectl auth can-i create namespace other-namespace  # should be denied
```

## Summary
- Prefer Access Entries over legacy `aws-auth` edits.
- Use an OIDC-backed IAM role for GitHub Actions.
- Enable IRSA for pod-level least privilege when needed.
- Regularly audit access with `list-access-entries`.

## Security Note

The GitHub Actions user is granted `AmazonEKSClusterAdminPolicy` which provides full cluster admin access. For production environments, consider:
- Creating a dedicated IAM role with least-privilege permissions
- Using namespace-scoped access instead of cluster-wide admin
- Implementing additional audit logging for the GitHub Actions principal

## Troubleshooting

### Error: "AccessDeniedException when calling AssumeRole"
The IAM user/role lacks permission to access EKS. Verify:
- The ARN is correct
- The principal has `eks:DescribeCluster` permission
- AWS credentials in GitHub secrets match the ARN

### Error: "UnsupportedAvailabilityZoneException"
Wrong region specified. Ensure `AWS_REGION=us-east-1` in the workflow.

### Still getting authentication errors
1. Verify the cluster name matches: `voting-app-cluster`
2. Check the kubeconfig was updated correctly
3. Run `kubectl config view` to verify context
4. Ensure AWS credentials in GitHub Actions are valid and not expired
