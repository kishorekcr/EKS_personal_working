output "cluster_name" {
  description = "EKS Cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded CA data for kubeconfig"
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where worker nodes live"
  value       = module.vpc.private_subnet_ids
}

output "oidc_provider_arn" {
  description = "OIDC Provider ARN — used for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "alb_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller (annotate the ServiceAccount)"
  value       = module.irsa.alb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM Role ARN for Cluster Autoscaler (annotate the ServiceAccount)"
  value       = module.irsa.cluster_autoscaler_role_arn
}

output "jenkins_kaniko_role_arn" {
  description = "IAM Role ARN for Jenkins/kaniko (annotated onto jenkins-agents/jenkins SA automatically)"
  value       = module.irsa.jenkins_kaniko_role_arn
}

output "argocd_url" {
  description = "NLB hostname for ArgoCD (may take a few minutes after apply)"
  value       = try("https://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname}", "not ready yet - check kubectl get svc -n argocd")
}

output "grafana_url" {
  description = "NLB hostname for Grafana (may take a few minutes after apply)"
  value       = try("http://${data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname}", "not ready yet - check kubectl get svc -n monitoring")
}

output "prometheus_url" {
  description = "NLB hostname for Prometheus - NO AUTH, see security warning in addons.tf (may take a few minutes after apply)"
  value       = try("http://${data.kubernetes_service.prometheus.status[0].load_balancer[0].ingress[0].hostname}:9090", "not ready yet - check kubectl get svc -n monitoring")
}

output "kubeconfig_command" {
  description = "Run this to connect kubectl to your cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
