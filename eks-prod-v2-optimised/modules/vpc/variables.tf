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

variable "single_nat_gateway" {
  description = "If true, create only 1 NAT Gateway (shared by all AZs) instead of 1-per-AZ. Saves ~66% of NAT cost. Use false only for prod HA."
  type        = bool
  default     = false
}
