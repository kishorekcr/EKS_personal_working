# ═══════════════════════════════════════════════════════════════════════
# STAGING ENVIRONMENT
#
# Philosophy:
#   - Mirror prod as closely as possible — catch infra bugs before prod
#   - Same instance family as prod but one size smaller (m5.large vs m5.xlarge)
#   - Same cluster version, same addons, same IRSA setup
#   - Load tests run here — so max_size matches prod
#
# Usage:
#   terraform workspace select staging
#   terraform apply -var-file=environments/staging/staging.tfvars
# ═══════════════════════════════════════════════════════════════════════

aws_region   = "us-east-1"
environment  = "staging"
project_name = "myapp"

vpc_cidr = "10.1.0.0/16"

# 1.33 exited standard support 29-Jul-2026 -> was silently costing extra
# EKS extended-support control-plane fee ($0.60/hr vs $0.10/hr standard).
# 1.36 is current and back on the $0.10/hr rate.
cluster_version = "1.36"

# Cost-conscious for cluster-creation/pipeline testing:
# t3.small nodes instead of c7i-flex.large — ~75% cheaper per instance,
# and 3-4 small nodes still gets you the multi-node scheduling behavior
# you actually need to test, without the compute-optimized price tag.
node_instance_types = ["c7i-flex.large"]

node_desired_size = 3
node_min_size     = 2
node_max_size     = 5

# 1 shared NAT Gateway instead of 1-per-AZ (saves ~66% of NAT cost).
# Fine for staging - if the single NAT's AZ goes down you lose egress,
# not the cluster itself. Keep this false in prod.tfvars.
single_nat_gateway = true

tags = {
  Team       = "platform"
  CostCenter = "engineering"
}
