# EKS Access Entry Management - Quick Reference

## Problem
When `enable_cluster_creator_admin_permissions = true`, Terraform automatically creates an access entry for the IAM principal running `terraform apply`. Attempting to add the same principal again via `access_entries` causes:

```
Error: creating EKS Access Entry: ResourceInUseException: 
The specified access entry resource is already in use on this cluster.
```

## Solution
Use the new `additional_access_entries` variable to add **only** IAM principals that are **different** from the cluster creator.

## Usage Examples

### Example 1: Cluster Creator Only (Default)
If you only need the person/role running Terraform to have access:

```hcl
# terraform.tfvars or command line
additional_access_entries = []
```

The cluster creator automatically gets admin access.

### Example 2: Add One Additional User
Add a separate CI/CD user while cluster creator retains admin access:

```hcl
additional_access_entries = [
  {
    principal_arn = "arn:aws:iam::703288805584:user/github-actions-ci"
  }
]
```

### Example 3: Multiple Users with Custom Permissions
```hcl
additional_access_entries = [
  {
    principal_arn = "arn:aws:iam::703288805584:user/ci-user"
    type          = "STANDARD"
  },
  {
    principal_arn     = "arn:aws:iam::703288805584:role/developer-role"
    kubernetes_groups = ["system:masters"]
  },
  {
    principal_arn     = "arn:aws:iam::703288805584:role/readonly-role"
    kubernetes_groups = ["viewers"]
  }
]
```

## Verification Commands

### List current access entries
```bash
aws eks list-access-entries \
  --cluster-name voting-app-cluster \
  --region us-east-1
```

### Describe specific access entry
```bash
aws eks describe-access-entry \
  --cluster-name voting-app-cluster \
  --principal-arn "arn:aws:iam::703288805584:user/root_admin" \
  --region us-east-1
```

### Check who you are (current IAM identity)
```bash
aws sts get-caller-identity
```

## Migration from Old Configuration

### Before (Caused Conflict)
```hcl
github_actions_user_arn = "arn:aws:iam::703288805584:user/root_admin"
# ^ This was the same as cluster creator, causing duplicate entry
```

### After (Fixed)
```hcl
# Cluster creator gets automatic access, no variable needed
additional_access_entries = []

# OR if you need a DIFFERENT user:
additional_access_entries = [
  {
    principal_arn = "arn:aws:iam::703288805584:user/github-ci"
  }
]
```

## Troubleshooting

### Error: 409 ResourceInUseException
**Cause**: Trying to add an access entry for a principal that already exists (likely the cluster creator).

**Fix**: Remove that principal from `additional_access_entries` or check existing entries with:
```bash
aws eks list-access-entries --cluster-name voting-app-cluster --region us-east-1
```

### Error: Cannot authenticate to cluster
**Cause**: Your IAM identity is not in the access entries.

**Fix**: 
1. Ensure you're running Terraform with the correct AWS credentials
2. Check caller identity: `aws sts get-caller-identity`
3. The principal in the output should match an entry in the cluster's access list

### Remove an incorrectly added entry
```bash
# Via AWS CLI (manual cleanup)
aws eks delete-access-entry \
  --cluster-name voting-app-cluster \
  --principal-arn "arn:aws:iam::ACCOUNT:user/USERNAME" \
  --region us-east-1

# Then run terraform apply again
```

## Best Practices

1. **Cluster Creator = Terraform Executor**: Let the automatic access entry handle the principal running Terraform
2. **Separate CI/CD Identities**: Use a dedicated IAM user/role for GitHub Actions, different from your admin user
3. **Document ARNs**: Keep a list of who has access and why in comments or a separate doc
4. **Least Privilege**: Use custom `kubernetes_groups` for fine-grained RBAC instead of giving everyone admin
5. **Regular Audits**: Periodically review access entries with `aws eks list-access-entries`

## Reference
- [AWS EKS Access Entries Documentation](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
- [EKS Cluster Access Policy ARNs](https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html)
