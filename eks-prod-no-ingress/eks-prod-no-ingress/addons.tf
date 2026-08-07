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
# Terraform creates the namespace + ServiceAccount itself (instead of
# waiting for Jenkins's Helm chart to make it) — same pattern as
# alb_controller/cluster_autoscaler above. When you later install Jenkins
# via Helm, set serviceAccount.create=false and
# serviceAccount.name=jenkins so it reuses this SA instead of making
# its own (which would strip the annotation).
resource "kubernetes_namespace" "jenkins_agents" {
  metadata {
    name = "jenkins-agents"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account" "jenkins_kaniko" {
  metadata {
    name      = "jenkins"
    namespace = kubernetes_namespace.jenkins_agents.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa.jenkins_kaniko_role_arn
    }
  }

  depends_on = [module.eks, module.irsa, kubernetes_namespace.jenkins_agents]
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

  # Plain Service type=LoadBalancer, no Ingress — AWS Load Balancer
  # Controller provisions an NLB for this. NLB does raw TCP passthrough,
  # so argocd-server keeps its own TLS (no server.insecure needed here,
  # unlike the ALB variant).
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  # Default scheme for controller-managed NLBs is "internal" — this makes
  # it internet-facing (this is what silently broke it the first time).
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  depends_on = [kubernetes_namespace.argocd, helm_release.alb_controller]
}

# So you don't have to run `kubectl get svc -n argocd` for the URL
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
  depends_on = [helm_release.argocd]
}

# ── PROMETHEUS + GRAFANA ──────────────────────────────────────────────────
# kube-prometheus-stack bundles Prometheus, Grafana, Alertmanager, and
# kube-state-metrics in one chart. Everything except node-exporter is
# pinned to the tainted monitoring node group (node-exporter is a
# DaemonStat that must run on every node to collect its metrics, so it
# gets a blanket toleration instead of nodeSelector — it needs to be
# EVERYWHERE, not just the monitoring node).
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Pin deliberately — check latest at
  # https://github.com/prometheus-community/helm-charts/releases
  version = "65.5.1"

  values = [<<-EOT
    grafana:
      nodeSelector:
        role: monitoring
      tolerations:
        - key: dedicated
          operator: Equal
          value: monitoring
          effect: NoSchedule
      service:
        type: LoadBalancer
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing

    alertmanager:
      alertmanagerSpec:
        nodeSelector:
          role: monitoring
        tolerations:
          - key: dedicated
            operator: Equal
            value: monitoring
            effect: NoSchedule

    prometheusOperator:
      nodeSelector:
        role: monitoring
      tolerations:
        - key: dedicated
          operator: Equal
          value: monitoring
          effect: NoSchedule

    # SECURITY WARNING: Prometheus has NO built-in authentication. An
    # internet-facing NLB here means anyone with the URL sees every
    # metric, target, and label. There's no ALB-style inbound-cidrs
    # annotation for NLB — if you need to restrict source IPs, do it via
    # a security group on the NLB's target/backing resources instead.
    prometheus:
      prometheusSpec:
        nodeSelector:
          role: monitoring
        tolerations:
          - key: dedicated
            operator: Equal
            value: monitoring
            effect: NoSchedule
        retention: 15d
      service:
        type: LoadBalancer
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing

    # DaemonSet — deliberately NOT nodeSelector-pinned, it must run on
    # every node (including the monitoring one) to scrape host metrics.
    prometheus-node-exporter:
      tolerations:
        - key: dedicated
          operator: Equal
          value: monitoring
          effect: NoSchedule
  EOT
  ]

  depends_on = [module.eks, kubernetes_namespace.monitoring, helm_release.alb_controller]
}

data "kubernetes_service" "grafana" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  depends_on = [helm_release.kube_prometheus_stack]
}

data "kubernetes_service" "prometheus" {
  metadata {
    name      = "kube-prometheus-stack-prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  depends_on = [helm_release.kube_prometheus_stack]
}
