# eks-prod-no-ingress — Production EKS with NLB (no Ingress)

Production-grade EKS cluster on AWS, fully managed by Terraform — cluster,
networking, IAM (via IRSA), and the workloads running on top of it
(Jenkins/kaniko access, ArgoCD, Prometheus + Grafana). This variant exposes
ArgoCD, Grafana, and Prometheus each via a plain Kubernetes
**`Service type=LoadBalancer`** — no Ingress resource at all — so each one
gets its own **Network Load Balancer (NLB)**, Layer 4, raw TCP passthrough.

If you wanted these behind a Kubernetes `Ingress` instead (gets you an ALB,
Layer 7, per-app routing rules, `inbound-cidrs` restriction support), use
the sibling repo `eks-prod-ingress`. Don't apply both against the same
cluster/state — pick one per environment.

---

## What's in here

```
eks-prod-no-ingress/
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
- AWS Load Balancer Controller (needs EC2/ELB permissions to provision NLBs)
- Cluster Autoscaler (needs ASG permissions)
- Jenkins/kaniko (`Jenkins-Kaniko-Role`) — scoped to ECR push/pull only,
  assumed by the `jenkins` ServiceAccount in the `jenkins-agents`
  namespace, which Terraform also creates and pre-annotates

**Add-ons (`addons.tf`)**
- AWS Load Balancer Controller (also provisions NLBs for plain
  `Service type=LoadBalancer` when it's managing the cluster)
- Cluster Autoscaler
- `jenkins-agents` namespace + `jenkins` ServiceAccount, pre-wired with the
  IRSA role — install Jenkins itself with `serviceAccount.create=false`,
  `serviceAccount.name=jenkins` so it reuses this SA instead of making its
  own (which would lose the annotation)
- ArgoCD (`argo-helm` chart) — `Service type=LoadBalancer`, keeps its own
  TLS (NLB passes raw TCP straight through, unlike an ALB, so no
  `server.insecure` needed here)
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
(NLB provisioning takes a couple of minutes — if the output says "not
ready yet," just re-run `terraform output` shortly after, or check
`kubectl get svc -A`.)

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
internet-facing NLB by default, which means anyone with the URL can see
every metric, target, and label. Unlike the ALB variant, there's no
`inbound-cidrs`-style annotation available for NLB traffic. Before using
this beyond a personal/learning environment:
- Restrict access at the security-group level on the NLB's target
  resources, or
- Put an authenticating reverse proxy in front, or
- Switch Prometheus back to `ClusterIP` and access it via
  `kubectl port-forward` only

Also worth knowing: this is exactly the config that broke silently the
first time around in this project — the NLB's default `scheme` is
`internal`, so without the explicit
`service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing`
annotation (already set for you in `addons.tf`), the load balancer gets
created but is only reachable from inside the VPC, which looks exactly
like a connection timeout from a browser outside it.

---

## Why NLB here specifically

A plain `Service type=LoadBalancer` (no Ingress) with AWS Load Balancer
Controller managing the cluster = a **Network Load Balancer** (Layer 4 —
raw TCP passthrough, no awareness of HTTP paths/hosts, generally lower
latency, no per-app routing rules). This is the simpler option when each
app just needs its own dedicated endpoint and you don't need path-based
routing or shared TLS termination. If you want several apps behind shared
Layer-7 routing logic or IP-based access restriction, that's what
`eks-prod-ingress` gives you (ALB) instead.
