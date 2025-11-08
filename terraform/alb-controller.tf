# AWS Load Balancer Controller for Ingress support

# IAM policy for AWS Load Balancer Controller
data "http" "aws_load_balancer_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${local.name_prefix}-aws-load-balancer-controller"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = data.http.aws_load_balancer_controller_policy.response_body
  tags        = var.tags
}

# Attach policy to EKS node group role (since IRSA/OIDC is disabled)
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = module.eks.eks_managed_node_groups["default"].iam_role_name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}
