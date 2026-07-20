terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # ── REMOTE STATE ─────────────────────────────────────────────────────
  # Update bucket/key before running terraform init
  backend "s3" {
    bucket         = "my-org-terraform-state-kcr"
    key            = "eks/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ── LOCALS ───────────────────────────────────────────────────────────────
locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}

# ── DATA SOURCES ─────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC ──────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name         = "${var.project_name}-${var.environment}"
  cidr         = var.vpc_cidr
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name = local.cluster_name
}

# ── EKS ──────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name        = local.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# ── IRSA ─────────────────────────────────────────────────────────────────
module "irsa" {
  source = "./modules/irsa"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_region        = var.aws_region
}

# ── EBS CSI DRIVER ADDON ────────────────────────────────────────────────
# Lives here (not inside the eks module) because it needs
# module.irsa.ebs_csi_driver_role_arn, and irsa needs module.eks's
# oidc outputs — putting it inside either module creates a cycle.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa.ebs_csi_driver_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [module.eks, module.irsa]
}
