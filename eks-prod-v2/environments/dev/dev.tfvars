# ═══════════════════════════════════════════════════════════════════════
# DEV ENVIRONMENT
#
# Philosophy:
#   - Smallest possible instances to save money
#   - Fewer nodes (1 is enough for dev testing)
#   - Same Kubernetes version as prod (catch issues early)
#   - Separate VPC CIDR so you can VPC peer if needed
#
# Usage:
#   terraform init
#   terraform workspace select dev   # or: terraform workspace new dev
#   terraform apply -var-file=environments/dev/dev.tfvars
# ═══════════════════════════════════════════════════════════════════════

aws_region   = "us-east-1"
environment  = "dev"
project_name = "myapp"

# Dev gets its own non-overlapping CIDR
# prod = 10.0.0.0/16 | staging = 10.1.0.0/16 | dev = 10.2.0.0/16
vpc_cidr = "10.2.0.0/16"

cluster_version = "1.33"

# t3.small is enough for running a few test pods
# In real orgs, dev often uses SPOT instances — if a node dies, re-run tests
node_instance_types = ["c7i-flex.large"]

# Keep it lean — Cluster Autoscaler will scale up if needed
node_desired_size = 1
node_min_size     = 1
node_max_size     = 3

tags = {
  Team        = "platform"
  CostCenter  = "engineering"
  AutoShutdown = "true"   # Tag used by Lambda to stop dev cluster at night
}
