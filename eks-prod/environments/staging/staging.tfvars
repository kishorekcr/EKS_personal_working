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

cluster_version = "1.33"

# One step below prod — validates app runs on same instance family
# Real orgs sometimes use SPOT here: ["m5.large", "m5.xlarge"] with mixed instances
node_instance_types = ["c7i-flex.large"]

# 2 nodes by default — enough to test HA behavior (pod scheduling across nodes)
node_desired_size = 2
node_min_size     = 1
node_max_size     = 5

tags = {
  Team       = "platform"
  CostCenter = "engineering"
}
