output "alb_controller_role_arn" {
  description = "Annotate the ALB Controller ServiceAccount with this ARN"
  value       = aws_iam_role.alb_controller.arn
}

output "cluster_autoscaler_role_arn" {
  description = "Annotate the Cluster Autoscaler ServiceAccount with this ARN"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "ebs_csi_driver_role_arn" {
  description = "Passed to the aws-ebs-csi-driver EKS addon as service_account_role_arn"
  value       = aws_iam_role.ebs_csi_driver.arn
}
