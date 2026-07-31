# ═══════════════════════════════════════════════════════════════════════
# ADDONS — installed via Terraform's kubernetes + helm providers instead
# of manual kubectl/helm CLI commands.
#
# These providers authenticate to the EKS cluster using a short-lived
# token from `aws eks get-token`-equivalent (aws_eks_cluster_auth data
# source), so no kubeconfig file is needed for terraform apply to work.
# ═══════════════════════════════════════════════════════════════════════



# Short-lived auth token for the cluster this config just created
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# ── ServiceAccount, linked to the IRSA role Terraform already created ──
resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa.alb_controller_role_arn
    }
  }

  # Cluster + node group must exist before we can talk to the API server
  depends_on = [module.eks]
}

# ── Helm release for the controller itself ─────────────────────────────
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false" # we already created it above
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    kubernetes_service_account.alb_controller
  ]
}
