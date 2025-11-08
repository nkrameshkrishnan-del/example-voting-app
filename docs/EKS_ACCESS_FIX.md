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
