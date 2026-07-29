#!/bin/bash

set -e

# ===========================
# Configuration
# ===========================
DOMAIN="kkdev.in"
SUBDOMAIN="petclinic"
NAMESPACE="petclinic"
INGRESS_NAME="petclinic-ingress"
ALB_NAME="petclinic-alb"

echo "========================================"
echo "Fetching Route53 Hosted Zone ID..."
echo "========================================"

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN" \
  --query "HostedZones[0].Id" \
  --output text)

echo "Hosted Zone ID : $ZONE_ID"

echo ""
echo "========================================"
echo "Fetching ALB DNS Name from Ingress..."
echo "========================================"

ALB_DNS=$(kubectl get ingress "$INGRESS_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS : $ALB_DNS"

echo ""
echo "========================================"
echo "Fetching ALB Hosted Zone ID..."
echo "========================================"

ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].CanonicalHostedZoneId" \
  --output text)

echo "ALB Hosted Zone ID : $ALB_ZONE_ID"

echo ""
echo "========================================"
echo "Creating Route53 Change Batch..."
echo "========================================"

cat > /tmp/route53-change.json <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${SUBDOMAIN}.${DOMAIN}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "${ALB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

cat /tmp/route53-change.json

echo ""
echo "========================================"
echo "Updating Route53 Record..."
echo "========================================"

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/route53-change.json

echo ""
echo "========================================"
echo "Route53 record updated successfully!"
echo "========================================"

echo ""
echo "Application URL:"
echo "http://${SUBDOMAIN}.${DOMAIN}"