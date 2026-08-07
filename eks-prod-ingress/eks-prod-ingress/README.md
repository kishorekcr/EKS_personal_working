# eks-prod-ingress — Production EKS with ALB Ingress

Production-grade EKS cluster on AWS, fully managed by Terraform — cluster,
networking, IAM (via IRSA), and the workloads running on top of it
(Jenkins/kaniko access, ArgoCD, Prometheus + Grafana). This variant exposes
ArgoCD, Grafana, and Prometheus each through a **Kubernetes Ingress**
(`ingressClassName: alb`), so each one gets its own **Application Load
Balancer (ALB)** — Layer 7, HTTP/HTTPS.

If you want these apps reachable via `Service type=LoadBalancer` instead
(no Ingress, gets you an NLB instead of an ALB), use the sibling repo
`eks-prod-no-ingress`. Don't apply both against the same cluster/state —
pick one per environment.

---

## What's in here

```
eks-prod-ingress/
├── main.tf                    # Root: wires vpc / eks / irsa modules together
├── variables.tf                # Root input variables
├── outputs.tf                  # Cluster info + app URLs after apply
├── addons.tf                   # Everything installed via helm/kubernetes providers
│
├── modules/
│   ├── vpc/                    # VPC, public + private subnets, NAT, route tables
│   ├── eks/                    # Cluster, 2 node groups, security groups, OIDC provider
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
- EKS cluster with its own OIDC provider (needed for IRSA — no manual
  `eksctl utils associate-iam-oidc-provider` step required, Terraform
  creates it directly)
- **Two managed node groups:**
  - `main` — general workloads, sized by `node_desired_size` /
    `node_min_size` / `node_max_size` in your `.tfvars`
  - `monitoring` — a single dedicated node, tainted
    `dedicated=monitoring:NoSchedule`, so only Prometheus/Grafana
    (which explicitly tolerate that taint) land there. Regular app pods
    won't get scheduled on it.

**IAM / IRSA (`modules/irsa`)** — one IAM role per workload, each scoped
to only what that workload needs, granted via OIDC federation:
- AWS Load Balancer Controller (needs EC2/ELB permissions to provision ALBs)
- Cluster Autoscaler (needs ASG permissions)
- Jenkins/kaniko (`Jenkins-Kaniko-Role`) — scoped to ECR push/pull only,
  assumed by the `jenkins` ServiceAccount in the `jenkins-agents`
  namespace, which Terraform also creates and pre-annotates

**Add-ons (`addons.tf`)**
- AWS Load Balancer Controller (provisions the ALBs for the Ingresses below)
- Cluster Autoscaler
- `jenkins-agents` namespace + `jenkins` ServiceAccount, pre-wired with the
  IRSA role — install Jenkins itself with `serviceAccount.create=false`,
  `serviceAccount.name=jenkins` so it reuses this SA instead of making its
  own (which would lose the annotation)
- ArgoCD (`argo-helm` chart) — `ClusterIP` service + ALB Ingress, TLS
  terminated at the ALB (`server.insecure=true` internally)
- `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager +
  node-exporter) — Prometheus/Grafana/Alertmanager/operator all pinned to
  the `monitoring` node via `nodeSelector` + toleration; node-exporter
  (a DaemonSet) deliberately has no `nodeSelector`, since it needs to run
  on every node including `main`, to actually collect their metrics

---

## Usage

```bash
terraform init
terraform plan  -var-file="environments/staging/staging.tfvars"
terraform apply -var-file="environments/staging/staging.tfvars"
```

After apply, get the URLs:
```bash
terraform output argocd_url
terraform output grafana_url
terraform output prometheus_url
```
(ALB provisioning takes a couple of minutes — if the output says "not
ready yet," just re-run `terraform output` shortly after, or check
`kubectl get ingress -A`.)

ArgoCD admin password:
```bash
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Grafana admin password:
```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```
(username `admin` for both)

---

## Security note — read before exposing Prometheus publicly

Prometheus has **no built-in authentication**. This repo puts it behind an
internet-facing ALB by default, which means anyone with the URL can see
every metric, target, and label. Before using this in anything beyond a
personal/learning environment:
- Uncomment `alb.ingress.kubernetes.io/inbound-cidrs` in `addons.tf` and
  restrict it to your office/VPN CIDR, or
- Put an authenticating reverse proxy in front, or
- Switch Prometheus back to `ClusterIP` and access it via
  `kubectl port-forward` only

---

## Why ALB here specifically

Kubernetes `Ingress` + AWS Load Balancer Controller with
`ingressClassName: alb` = an **Application Load Balancer** (Layer 7 —
understands HTTP paths/hosts, can do path-based routing, supports
`inbound-cidrs` restriction). This is the right choice when you want
several apps sharing routing logic, TLS termination at the edge, or
finer-grained access control. If you just want a plain Layer-4 pass-through
load balancer per service with less to configure, that's what
`eks-prod-no-ingress` gives you (NLB) instead.
