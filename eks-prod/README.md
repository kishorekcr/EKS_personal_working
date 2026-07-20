# Production EKS Cluster — Terraform

Clean, production-grade EKS setup. Three environments, modular structure,
IRSA for secure AWS access from pods. The kind of setup real orgs actually use.

---

## Folder Structure

```
eks-prod/
├── main.tf                          # Root: wires all modules together
├── variables.tf                     # Input variable declarations
├── outputs.tf                       # What Terraform prints after apply
│
├── modules/
│   ├── vpc/
│   │   ├── main.tf                  # VPC, subnets, NAT GW, route tables
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── eks/
│   │   ├── main.tf                  # Cluster, node group, SGs, addons, OIDC
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── irsa/
│       ├── main.tf                  # IAM roles for ALB controller + Autoscaler
│       ├── variables.tf
│       └── outputs.tf
│
└── environments/
    ├── dev/
    │   └── dev.tfvars               # Small instances, 1 node, cheap
    ├── staging/
    │   └── staging.tfvars           # Mid-sized, mirrors prod shape
    └── prod/
        └── prod.tfvars              # Production-sized, strict tags
```

---

## Architecture

```
                VPC (10.0.0.0/16)
                ┌──────────────────────────────────────┐
                │  Public Subnets  (us-east-1a/b/c)    │
                │  ┌─────┐  ┌─────┐  ┌─────┐          │
  Internet ─────┤  │ NAT │  │ NAT │  │ NAT │          │
  Gateway       │  └──┬──┘  └──┬──┘  └──┬──┘          │
                │     │        │        │               │
                │  Private Subnets                      │
                │  ┌──────────────────────────────┐    │
                │  │   EKS Worker Nodes            │    │
                │  │   (Managed Node Group)        │    │
                │  └──────────────┬───────────────┘    │
                │                 │ private API         │
                │  ┌──────────────┴───────────────┐    │
                │  │   EKS Control Plane           │    │
                │  │   (AWS Managed)               │    │
                │  └───────────────────────────────┘    │
                └──────────────────────────────────────┘
```

---

## Prerequisites

```bash
# 1. Tools
brew install terraform awscli kubectl helm

# 2. AWS auth
aws configure
# or: export AWS_PROFILE=myprofile

# 3. S3 bucket for remote state (one-time setup)
aws s3 mb s3://my-org-terraform-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket my-org-terraform-state \
  --versioning-configuration Status=Enabled

# 4. DynamoDB table for state locking (one-time setup)
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

---

## Deploy

```bash
# Step 1: Update the backend block in main.tf with your S3 bucket name

# Step 2: Init (downloads providers, sets up backend)
terraform init

# Step 3: Plan — see what will be created
terraform plan -var-file=environments/prod/prod.tfvars

# Step 4: Apply
terraform apply -var-file=environments/prod/prod.tfvars

# Step 5: Connect kubectl
aws eks update-kubeconfig --region us-east-1 --name myapp-prod-eks

# Step 6: Verify
kubectl get nodes
kubectl get pods -A
```

### Deploying dev / staging

```bash
# Dev
terraform plan  -var-file=environments/dev/dev.tfvars
terraform apply -var-file=environments/dev/dev.tfvars

# Staging
terraform plan  -var-file=environments/staging/staging.tfvars
terraform apply -var-file=environments/staging/staging.tfvars
```

> TIP: Use `terraform workspace` to keep separate state per env,
> or separate S3 keys per env (already done in the backend config).

---

## Do Real Orgs Use tfvars?

YES — tfvars is the standard in every real org. Here's how it's used:

| Pattern | How |
|---|---|
| Per-environment values | `dev.tfvars`, `staging.tfvars`, `prod.tfvars` |
| Secrets (DB passwords etc) | `-var` flag or `TF_VAR_` env vars — never commit to git |
| CI/CD pipelines | GitHub Actions passes `--var-file` based on branch |
| Sensitive tfvars | Stored in AWS Secrets Manager or Vault, not in repo |

**What goes in tfvars:** instance sizes, node counts, CIDRs, tags, feature flags

**What does NOT go in tfvars:** passwords, API keys, certificates — use `TF_VAR_` env vars or a secrets manager

---

## Post-Deploy: Install ALB Controller

```bash
ALB_ROLE=$(terraform output -raw alb_controller_role_arn)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=myapp-prod-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"
```

## Post-Deploy: Install Cluster Autoscaler

```bash
CA_ROLE=$(terraform output -raw cluster_autoscaler_role_arn)

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=myapp-prod-eks \
  --set awsRegion=us-east-1 \
  --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$CA_ROLE"
```

---

## Production Hardening (do these before go-live)

- [ ] Restrict `public_access_cidrs` in `modules/eks/main.tf` to your office/VPN IP
- [ ] Pin addon versions — avoid `LATEST` in production
- [ ] Add a dedicated SPOT node group for batch/background workloads
- [ ] Configure HPA on your Deployments
- [ ] Set up Prometheus + Grafana (kube-prometheus-stack Helm chart)
- [ ] Enable AWS GuardDuty EKS runtime threat detection
- [ ] Review and tighten IRSA IAM policies to least privilege

---

## Destroy

```bash
# Always uninstall Helm releases first — they create AWS resources (ALBs, SGs)
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall cluster-autoscaler -n kube-system

# Then destroy infra
terraform destroy -var-file=environments/prod/prod.tfvars
```
