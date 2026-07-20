#!/bin/bash
# ============================================================
# PetClinic K8s — Full Deploy Script
# Run from bastion host after kubectl is connected
# ============================================================

# -------------------------------------------------------
# STEP 0: Connect kubectl to your EKS cluster
# FIXED: region us-east-1, cluster name petclinic-eks
# -------------------------------------------------------
aws eks update-kubeconfig --region us-east-1 --name dev-PetClinic-eks-cluster

kubectl get nodes

# -------------------------------------------------------
# PRE-REQUISITES — run once before deploy
# -------------------------------------------------------

# A) metrics-server (needed for HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# B) EBS CSI Driver (needed for PV/PVC with EBS gp3)
kubectl get pods -n kube-system | grep ebs-csi
# If not installed:
aws eks create-addon \
  --cluster-name petclinic-eks \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1

# C) AWS Load Balancer Controller (needed for ALB Ingress)
curl -o alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://alb-iam-policy.json

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws eks describe-cluster --name petclinic-eks --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

eksctl create iamserviceaccount  --cluster=dev-PetClinic-eks-cluster --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=arn:aws:iam::316777658873:policy/AWSLoadBalancerControllerIAMPolicy --approve --region us-east-1

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=dev-Petclinic-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller\
  --set region=us-east-1 \
  --set vpcId=vpc-0103d7e538809c793

kubectl get pods -n kube-system | grep aws-load-balancer

# -------------------------------------------------------
# STEP 1: Namespace
# NOTE: All files are flat — same folder, no subfolders
# -------------------------------------------------------
kubectl apply -f namespace.yaml

# STEP 2: ConfigMap and Secret
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml

# STEP 3: Storage
kubectl apply -f pv-pvc.yaml
kubectl get pvc -n petclinic

# STEP 4: MySQL
kubectl apply -f mysql-deployment.yaml
echo "Waiting for MySQL..."
kubectl wait --for=condition=ready pod -l app=mysql -n petclinic --timeout=120s

# STEP 5: PetClinic App
kubectl apply -f petclinic-deployment.yaml

# STEP 6: Services
kubectl apply -f service.yaml

# STEP 7: ALB Ingress (update cert ARN in alb-ingress.yaml first!)
kubectl apply -f alb-ingress.yaml
kubectl get ingress -n petclinic -w

# STEP 8: HPA
kubectl apply -f hpa.yaml

# STEP 9: RBAC
kubectl apply -f rbac.yaml

# ============================================================
# VERIFY
# ============================================================
kubectl get all -n petclinic
kubectl get pv,pvc -n petclinic
kubectl get ingress -n petclinic
kubectl get hpa -n petclinic

echo "=== ALB DNS — use this for Route53 CNAME ==="
kubectl get ingress petclinic-ingress -n petclinic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo ""
