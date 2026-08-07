# eks-prod-v2-optimized

Production-grade EKS cluster on AWS, fully managed by Terraform — networking,
the cluster itself, IAM (via IRSA), and every workload running on top of it
(Jenkins/kaniko access, ArgoCD, Prometheus + Grafana). This is the **private
access** version: nothing here is exposed to the internet by default — every
app is reached via `kubectl port-forward`, no ALB, no NLB, no Ingress, no
extra AWS load balancer cost.

---

## Folder structure

```
eks-prod-v2-optimized/
├── main.tf                    # Root: wires vpc / eks / irsa modules together
├── variables.tf                # Root input variables
├── outputs.tf                  # Cluster info + how to reach ArgoCD
├── addons.tf                   # Everything installed via helm/kubernetes providers
│
├── modules/
│   ├── vpc/                    # VPC, public + private subnets, NAT, route tables
│   ├── eks/                    # Cluster, node groups, security groups, OIDC provider
│   └── irsa/                   # IAM roles for pods (IRSA) — one per workload
│
└── environments/
    ├── dev/dev.tfvars
    ├── staging/staging.tfvars
    └── prod/prod.tfvars
```

## What gets created

**Networking & cluster (`modules/vpc`, `modules/eks`)**
- VPC with public + private subnets across 3 AZs, NAT gateways
- EKS cluster with its own IAM OIDC provider — created directly by
  Terraform (`aws_iam_openid_connect_provider`), so the manual
  `aws eks describe-cluster` / `eksctl utils associate-iam-oidc-provider`
  check-and-create steps aren't needed; it's guaranteed to exist after apply
- One managed node group (`main`), sized by `node_desired_size` /
  `node_min_size` / `node_max_size` in your `.tfvars`
- `aws-ebs-csi-driver` EKS addon, wired to its own IRSA role

**IAM / IRSA (`modules/irsa`)** — one IAM role per workload, each scoped to
only what that workload needs, granted via OIDC federation (no static
credentials anywhere):
- AWS Load Balancer Controller
- Cluster Autoscaler
- EBS CSI Driver
- Jenkins/kaniko (`Jenkins-Kaniko-Role` + `Jenkins-Kaniko-ECR-Policy`) —
  scoped to ECR push/pull only, assumed by the `jenkins` ServiceAccount in
  the `jenkins-agents` namespace

**Add-ons (`addons.tf`)**
- AWS Load Balancer Controller (installed and ready, even though nothing
  currently uses it to expose a public endpoint — see below)
- Cluster Autoscaler (auto-discovers the node group's ASG via tags EKS
  already applies, no manual ASG tagging step needed)
- `jenkins-agents` namespace + `jenkins` ServiceAccount, pre-created and
  pre-annotated with the IRSA role ARN. When you install Jenkins itself via
  Helm, set `serviceAccount.create=false` and `serviceAccount.name=jenkins`
  so it reuses this SA instead of creating its own (which would strip the
  annotation and break kaniko's ECR push)
- ArgoCD (`argo-helm` chart), `server.service.type = ClusterIP`
- `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager +
  node-exporter + kube-state-metrics), also `ClusterIP`

---

## Access — everything is private by design

No app in this repo has a public URL. Reach each one with a
`kubectl port-forward` in a separate terminal:

**ArgoCD**
```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
```
Open `https://localhost:8080` (self-signed cert — click through the browser
warning). Admin password:
```bash
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**Grafana**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```
Open `http://localhost:3000`. Username `admin`, password:
```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

**Prometheus**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```
Open `http://localhost:9090`. No login — Prometheus has no built-in
authentication, which is exactly why it isn't exposed publicly here.

If you're SSH'd into a bastion and want these in your **local** browser
(not the bastion's), forward the ports over SSH too:
```bash
ssh -L 8080:localhost:8080 -L 3000:localhost:3000 -L 9090:localhost:9090 ubuntu@<bastion-ip>
```
then run the three `kubectl port-forward` commands inside that session.

---

## Usage

```bash
terraform init
terraform plan  -var-file="environments/staging/staging.tfvars"
terraform apply -var-file="environments/staging/staging.tfvars"
```

Connect `kubectl` to the cluster:
```bash
aws eks update-kubeconfig --region <your-region> --name <cluster-name>
```
(also printed as `terraform output kubeconfig_command`)

---

## Going public later

If you ever want ArgoCD/Grafana/Prometheus reachable outside the cluster
without `kubectl`, there are two paths, both straightforward extensions of
what's already here since the ALB Load Balancer Controller is already
installed:

- **Ingress → ALB** (Layer 7, HTTP/HTTPS-aware, supports path-based routing
  and IP-restriction annotations)
- **`Service type=LoadBalancer` → NLB** (Layer 4, raw TCP passthrough,
  simpler but less configurable)

Either way, if you expose Prometheus specifically, lock it down — it has
no authentication of its own.
