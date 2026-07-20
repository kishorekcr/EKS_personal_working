variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "azs" {
  description = "List of availability zones to use"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet tags)"
  type        = string
}
