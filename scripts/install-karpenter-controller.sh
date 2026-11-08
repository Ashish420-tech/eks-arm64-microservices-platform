#!/usr/bin/env bash
set -Eeuo pipefail

REGION="ap-south-1"
CLUSTER="eks-arm64-platform"
VERSION="1.15.1"
NAMESPACE="kube-system"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CONTROLLER_ROLE="${CLUSTER}-karpenter"

echo "=========================================="
echo " INSTALLING KARPENTER CONTROLLER"
echo "=========================================="

# 1. Verify controller ServiceAccount
kubectl get serviceaccount karpenter -n "$NAMESPACE"

# 2. Verify Pod Identity association
ASSOCIATION_ID="$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --query "associations[?namespace=='kube-system' && serviceAccount=='karpenter'].associationId | [0]" \
  --output text)"

if [[ -z "$ASSOCIATION_ID" || "$ASSOCIATION_ID" == "None" ]]; then
  echo "ERROR: Karpenter Pod Identity association missing."
  exit 1
fi

aws eks describe-pod-identity-association \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --association-id "$ASSOCIATION_ID" \
  --query 'association.{Role:roleArn,Namespace:namespace,ServiceAccount:serviceAccount}' \
  --output table

# 3. Verify controller IAM role
aws iam get-role \
  --role-name "$CONTROLLER_ROLE" \
  --query 'Role.Arn' --output text

# 4. Retrieve EKS interruption queue
QUEUE="$(aws sqs get-queue-url \
  --queue-name "$CLUSTER" \
  --region "$REGION" \
  --query QueueUrl --output text)"

echo "Interruption queue: $QUEUE"

# 5. Save constrained lab configuration
mkdir -p terraform/karpenter

cat > terraform/karpenter/controller-values.yaml <<'EOF'
replicas: 1

serviceAccount:
  create: false
  name: karpenter

nodeSelector:
  kubernetes.io/os: linux
  kubernetes.io/arch: arm64

controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 768Mi

settings:
  enableZonalShift: false
EOF

# 6. Set dynamic cluster settings
cat >> terraform/karpenter/controller-values.yaml <<EOF
  clusterName: ${CLUSTER}
  interruptionQueue: ${CLUSTER}
EOF

# 7. Verify chart is available
helm registry logout public.ecr.aws >/dev/null 2>&1 || true

echo "Pulling Karpenter Helm chart ${VERSION}..."
helm pull oci://public.ecr.aws/karpenter/karpenter \
  --version "$VERSION" \
  --destination /tmp

# 8. Install controller
echo "Installing Karpenter controller..."

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "$VERSION" \
  --namespace "$NAMESPACE" \
  --values terraform/karpenter/controller-values.yaml \
  --wait \
  --timeout 5m

# 9. Verify rollout
echo "Waiting for controller deployment..."

kubectl rollout status deployment/karpenter \
  -n "$NAMESPACE" \
  --timeout=300s

echo
echo "===== HELM RELEASE ====="
helm list -n "$NAMESPACE" --filter '^karpenter$'

echo
echo "===== KARPENTER POD ====="
kubectl get pods -n "$NAMESPACE" -o wide | grep karpenter

echo
echo "===== KARPENTER LOGS ====="
kubectl logs deployment/karpenter \
  -n "$NAMESPACE" --tail=40

echo
echo "===== KARPENTER CRDS ====="
kubectl get crds | grep karpenter

echo
echo "===== KARPENTER CONTROLLER INSTALLATION COMPLETE ====="
echo "No additional EC2 worker nodes were requested."
