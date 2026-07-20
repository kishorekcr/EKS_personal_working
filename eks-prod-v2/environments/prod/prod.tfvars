# ═══════════════════════════════════════════════════════════════════════
# PRODUCTION ENVIRONMENT
#
# Philosophy:
#   - Right-sized instances for real traffic (not over-provisioned)
#   - ON_DEMAND nodes for reliability (no SPOT interruptions in prod)
#   - Higher min_size so the cluster isn't scrambling when traffic spikes
#   - Strict tagging for cost allocation and compliance
#
# Usage:
#   terraform workspace select prod
#   terraform apply -var-file=environments/prod/prod.tfvars
# ═══════════════════════════════════════════════════════════════════════

aws_region   = "us-east-1"
environment  = "prod"
project_name = "myapp"

vpc_cidr = "10.0.0.0/16"

cluster_version = "1.29"

# t3.medium for general workloads
# Upgrade to m5.large or m5.xlarge if you have memory-heavy workloads (Java apps)
# Real orgs often define multiple node groups: one for apps, one for monitoring
node_instance_types = ["c7i-flex.large"]

# Start with 3 nodes in prod — one per AZ for proper HA
# Cluster Autoscaler scales up to 10 during traffic peaks
node_desired_size = 2
node_min_size     = 1
node_max_size     = 4

tags = {
  Team        = "platform"
  CostCenter  = "engineering"
  Compliance  = "SOC2"          # Picked up by AWS Config rules
  DataClass   = "confidential"  # Used by security team for audits
}
