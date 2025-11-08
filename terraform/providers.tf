provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.prefix
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Kubernetes provider removed - K8s resources managed via GitHub Actions kubectl/helm
# If you need to manage K8s resources with Terraform, uncomment and run terraform init -upgrade after cluster exists:
# provider "kubernetes" {
#   host                   = module.eks.cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
# 
#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
#   }
# }

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
