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

# ── CLUSTER AUTOSCALER ───────────────────────────────────────────────────
# IAM role already created by module.irsa (cluster_autoscaler_role_arn).
# EKS managed node groups auto-tag their underlying ASG with
# k8s.io/cluster-autoscaler/enabled + k8s.io/cluster-autoscaler/<cluster-name>
# so no manual ASG tagging step is needed — auto-discovery just works.
resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name" = "cluster-autoscaler"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa.cluster_autoscaler_role_arn
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "false" # we already created it above
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = kubernetes_service_account.cluster_autoscaler.metadata[0].name
  }

  # Match your cluster's k8s minor version so CA uses the compatible image
  set {
    name  = "image.tag"
    value = "v1.36.0" # keep in sync with cluster_version in tfvars
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  depends_on = [
    kubernetes_service_account.cluster_autoscaler
  ]
}

# ── JENKINS / KANIKO ──────────────────────────────────────────────────────
# The "jenkins" ServiceAccount in "jenkins-agents" is created by your
# Jenkins Helm chart / JCasC, not by this repo — so unlike alb_controller
# and cluster_autoscaler above, we don't use kubernetes_service_account
# (that would try to CREATE it and fail with "already exists"). Instead
# kubernetes_annotations adopts just the annotation on the existing object,
# replacing the manual `kubectl annotate serviceaccount jenkins ...` step.
resource "kubernetes_annotations" "jenkins_kaniko" {
  api_version = "v1"
  kind        = "ServiceAccount"

  metadata {
    name      = "jenkins"
    namespace = "jenkins-agents"
  }

  annotations = {
    "eks.amazonaws.com/role-arn" = module.irsa.jenkins_kaniko_role_arn
  }

  force = true

  # The SA must already exist in the cluster (Helm/JCasC creates it) before
  # Terraform can annotate it, and the IAM role must exist first too.
  depends_on = [module.eks, module.irsa]
}

# ── ARGO CD ───────────────────────────────────────────────────────────────
# Replaces: kubectl create ns -> kubectl apply install.yaml -> kubectl patch
# svc to LoadBalancer. Namespace + install become one helm_release; the
# LoadBalancer exposure is a chart value instead of a separate patch step.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Pin this — argo-helm ships breaking changes across majors. Bump
  # deliberately, not on every apply. Check latest at
  # https://github.com/argoproj/argo-helm/releases
  version = "7.7.11"

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  depends_on = [kubernetes_namespace.argocd]
}

# So you don't have to run `kubectl get svc -n argocd` just to find the URL
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  depends_on = [helm_release.argocd]
}
