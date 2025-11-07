# GitHub Actions Workflows

This directory contains the CI/CD workflows for the Voting App.

## Workflows

### 1. CI - Build and Push to ECR (`ci-build-push.yml`)

Builds Docker images for all application components and pushes them to Amazon ECR.

**Triggers:**
- Push to `main` or `develop` branches
- Pull requests to `main` branch

**Jobs:**
- `build-and-push`: Builds and pushes Docker images using a matrix strategy for:
  - vote service
  - result service
  - worker service

**Features:**
- Uses GitHub OIDC for secure AWS authentication (no long-lived credentials)
- Multi-arch support with Docker Buildx
- Layer caching for faster builds
- Multiple image tags (branch name, git SHA, latest)

**Required Secrets:**
- `AWS_ROLE_ARN`: IAM role ARN for GitHub Actions
- `AWS_ACCOUNT_ID`: Your AWS account ID

---

### 2. CD - Deploy to EKS (`cd-deploy-eks.yml`)

Deploys the application to Amazon EKS cluster.

**Triggers:**
- Automatic: After successful completion of CI workflow (main branch only)
- Manual: Via `workflow_dispatch` with environment selection

**Jobs:**
- `deploy`: Deploys all Kubernetes resources to EKS

**Features:**
- Dynamic image tag replacement
- Namespace management
- Service health checks
- Deployment status reporting

**Required Secrets:**
- `AWS_ROLE_ARN`: IAM role ARN for GitHub Actions

**Environment Variables:**
- `AWS_REGION`: AWS region (default: us-east-1)
- `EKS_CLUSTER_NAME`: Name of the EKS cluster

---

## Configuration

### AWS Authentication

Both workflows use OpenID Connect (OIDC) to authenticate with AWS. This is more secure than storing AWS access keys.

Setup:
1. Create an OIDC provider in AWS IAM for GitHub Actions
2. Create an IAM role with trust policy allowing GitHub Actions
3. Attach necessary policies to the role (ECR, EKS access)
4. Store the role ARN in GitHub secrets

### Image Tags

Images are tagged with multiple tags:
- `latest`: Only on main branch
- `<branch-name>`: Current branch (e.g., `main`, `develop`)
- `<branch-name>-<git-sha>`: Branch + commit SHA (e.g., `main-abc1234`)

### Deployment Strategy

The CD workflow uses a rolling update strategy:
1. Apply ConfigMap and Secrets
2. Deploy database and Redis services (if needed)
3. Deploy application services (vote, result, worker)
4. Wait for rollout to complete
5. Display service endpoints

## Usage

### Automatic Deployment

1. Make changes to your code
2. Commit and push to `main` or `develop` branch
3. CI workflow builds and pushes images
4. CD workflow deploys to EKS (main branch only)

### Manual Deployment

Go to Actions tab → CD - Deploy to EKS → Run workflow

Select environment and trigger deployment.

### Monitoring Workflow Runs

1. Navigate to the "Actions" tab in GitHub
2. Select the workflow run
3. View logs for each job and step
4. Check the deployment summary at the end

## Customization

### Change AWS Region

Edit both workflow files and update:
```yaml
env:
  AWS_REGION: us-west-2  # Change to your region
```

### Change EKS Cluster Name

Edit `cd-deploy-eks.yml`:
```yaml
env:
  EKS_CLUSTER_NAME: your-cluster-name
```

### Add More Environments

Modify the `workflow_dispatch` input in `cd-deploy-eks.yml`:
```yaml
inputs:
  environment:
    type: choice
    options:
      - production
      - staging
      - development  # Add new environment
```

### Build Arguments

Add build arguments in `ci-build-push.yml`:
```yaml
- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    build-args: |
      NODE_ENV=production
      VERSION=${{ github.sha }}
```

### Deploy to Multiple Clusters

Use a matrix strategy in the CD workflow:
```yaml
strategy:
  matrix:
    cluster:
      - name: cluster-1
        region: us-east-1
      - name: cluster-2
        region: us-west-2
```

## Troubleshooting

### Workflow Not Triggering

- Check branch protection rules
- Verify workflow file syntax (use `yamllint`)
- Check if workflows are enabled in repository settings

### Authentication Failures

- Verify OIDC provider is configured correctly
- Check IAM role trust policy
- Ensure role has necessary permissions
- Verify AWS account ID matches

### Build Failures

- Check Dockerfile syntax
- Verify build context path
- Check for missing dependencies
- Review build logs for specific errors

### Deployment Failures

- Verify EKS cluster exists and is accessible
- Check Kubernetes RBAC permissions
- Ensure ConfigMap and Secrets exist
- Review pod events: `kubectl describe pod <name>`

## Security Best Practices

1. **Never commit secrets**: Use GitHub Secrets for sensitive data
2. **Use OIDC**: Avoid long-lived AWS access keys
3. **Least privilege**: Grant minimal required IAM permissions
4. **Scan images**: Add container scanning step
5. **Review permissions**: Regularly audit workflow permissions
6. **Protected branches**: Enable branch protection for main/production
7. **Required reviews**: Require PR reviews before merge

## Performance Optimization

1. **Layer caching**: Already enabled with GitHub Actions cache
2. **Parallel builds**: Matrix strategy builds services in parallel
3. **Multi-stage builds**: Use in Dockerfiles to reduce image size
4. **Conditional steps**: Skip unnecessary steps based on conditions

## Advanced Features

### Add Testing

```yaml
- name: Run tests
  run: |
    docker run --rm ${{ steps.meta.outputs.tags }} npm test
```

### Add Security Scanning

```yaml
- name: Scan image
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ steps.meta.outputs.tags }}
    format: 'sarif'
    output: 'trivy-results.sarif'
```

### Add Notifications

```yaml
- name: Notify Slack
  uses: slackapi/slack-github-action@v1
  with:
    webhook: ${{ secrets.SLACK_WEBHOOK }}
    payload: |
      {
        "text": "Deployment completed: ${{ github.sha }}"
      }
```

## Migration from Other CI/CD

### From Jenkins

- Replace Jenkinsfile with GitHub Actions workflows
- Convert pipeline stages to workflow jobs
- Use GitHub Secrets instead of Jenkins credentials
- Migrate build scripts to workflow steps

### From GitLab CI

- Convert `.gitlab-ci.yml` to workflow files
- Replace `stages` with `jobs`
- Update secret variable references
- Adapt artifact handling 

## Related Documentation

- [Quick Start Guide](../docs/CI_CD_QUICKSTART.md)
- [AWS Setup Guide](../docs/AWS_SETUP.md)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [AWS IAM OIDC Guide](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
