#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/eks-arm64-microservices-platform"
CHART="$ROOT/helm/applications/microservices-platform"

cd "$ROOT"

echo "================================================"
echo " ARM64 EKS PLATFORM - PRE-DEPLOYMENT CHECK"
echo "================================================"

echo "[1/8] Checking required tools..."
for cmd in aws kubectl helm docker; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is missing"
    exit 1
  }
done

echo "[2/8] Checking AWS identity and EKS..."
aws sts get-caller-identity --query Account --output text
kubectl cluster-info
kubectl get nodes -L kubernetes.io/arch,workload-tier

echo "[3/8] Checking EBS CSI..."
kubectl get csidriver ebs.csi.aws.com
kubectl get pods -n kube-system | grep ebs-csi || true

echo "[4/8] Checking gp3 StorageClass..."
if ! kubectl get storageclass gp3 >/dev/null 2>&1; then
  cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
EOF
else
  echo "gp3 StorageClass already exists."
fi
kubectl get storageclass

echo "[5/8] Checking ARM64 ECR images..."
BUILD_TAG="dev-20261108-153841"
ECR="924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform"

for SERVICE in api-gateway auth-service employee-service product-service order-service; do
  IMAGE="${ECR}/${SERVICE}:${BUILD_TAG}"
  ARCH=$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)

  if [[ "$ARCH" != "linux/arm64" ]]; then
    echo "ERROR: Local image $SERVICE is not verified as linux/arm64."
    echo "Run: docker pull --platform linux/arm64 $IMAGE"
    exit 1
  fi

  echo "OK: $SERVICE ($ARCH)"
done

echo "[6/8] Checking SQL migrations..."
for SERVICE in auth employee product order; do
  FILE="services/${SERVICE}-service/migrations/001_create_${SERVICE}.sql"
  if [[ ! -f "$FILE" ]]; then
    echo "WARNING: Expected migration not found: $FILE"
  else
    echo "OK: $FILE"
  fi
done

echo "[7/8] Validating Helm chart..."
helm lint "$CHART"
helm template microservices-platform "$CHART" \
  --set-string image.tag="$BUILD_TAG" \
  >/tmp/microservices-platform-rendered.yaml

echo "Rendered manifests: /tmp/microservices-platform-rendered.yaml"

echo "[8/8] Checking environment variables without displaying secrets..."
if [[ ! -f .env ]]; then
  echo "ERROR: .env file not found."
  exit 1
fi

for KEY in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD JWT_SECRET; do
  if ! grep -qE "^${KEY}=.+" .env; then
    echo "ERROR: Missing or empty $KEY in .env"
    exit 1
  fi
  echo "OK: $KEY configured"
done

echo
echo "================================================"
echo " PRE-DEPLOYMENT CHECK COMPLETED"
echo "================================================"
echo "Image tag: $BUILD_TAG"
echo "Next: review chart configuration and deploy."
