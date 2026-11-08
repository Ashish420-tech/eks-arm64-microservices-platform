#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# ARM64 EKS Microservices + PostgreSQL + Argo CD deployment
# Reuses existing EKS, Karpenter, PVC, ECR and Argo CD.
# ==========================================================

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

REGION="ap-south-1"
CLUSTER="eks-arm64-platform"
NAMESPACE="microservices"
ARGO_NAMESPACE="argocd"
APP_NAME="microservices-platform"

ECR="924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform"
IMAGE_TAG="${IMAGE_TAG:-dev-20261108-153841}"
CHART="helm/applications/microservices-platform"

SERVICES=(
  api-gateway
  auth-service
  employee-service
  product-service
  order-service
)

log() { printf '\n\033[1;32m==== %s ====\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

trap 'echo "FAILED at line $LINENO. Inspect the command above; existing PVC was not deleted."' ERR

# ----------------------------------------------------------
# 1. Prerequisites
# ----------------------------------------------------------
log "1. Checking prerequisites"

for cmd in aws kubectl helm git jq; do need "$cmd"; done

[[ -d "$CHART/templates" ]] || die "Helm chart not found: $CHART"
[[ -f "$CHART/Chart.yaml" ]] || die "Chart.yaml missing"
[[ -f ".env" ]] || die ".env missing. Create it with your existing DB/JWT settings."

aws sts get-caller-identity >/dev/null
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

kubectl get nodes
kubectl get ns "$NAMESPACE" >/dev/null
kubectl get ns "$ARGO_NAMESPACE" >/dev/null

kubectl get deployment argocd-server -n "$ARGO_NAMESPACE" >/dev/null
kubectl get pvc -n "$NAMESPACE"

# Never delete or recreate the database PVC.
PVC_STATUS="$(kubectl get pvc data-postgres-0 -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$PVC_STATUS" == "Bound" ]] || die "data-postgres-0 PVC is not Bound. Fix storage before proceeding."

# ----------------------------------------------------------
# 2. Verify required secrets
# ----------------------------------------------------------
log "2. Checking application secret"

kubectl get secret platform-secrets -n "$NAMESPACE" >/dev/null \
  || die "Secret platform-secrets is missing. Create it from your .env first."

for key in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD JWT_SECRET; do
  kubectl get secret platform-secrets -n "$NAMESPACE" \
    -o "jsonpath={.data.$key}" | grep -q . \
    || die "Secret key $key is missing."
done

# ----------------------------------------------------------
# 3. Patch PostgreSQL permissions
# ----------------------------------------------------------
log "3. Fixing PostgreSQL startup permissions"

POSTGRES_TEMPLATE="$CHART/templates/postgres.yaml"
[[ -f "$POSTGRES_TEMPLATE" ]] || die "Missing $POSTGRES_TEMPLATE"

python3 - "$POSTGRES_TEMPLATE" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# Patch the container-level securityContext for the official
# PostgreSQL entrypoint, which needs filesystem ownership changes.
pattern = r'(?m)^(\s*)securityContext:\n(?:\1  .*\n|\s*\n)*'
matches = list(re.finditer(pattern, s))

if not matches:
    raise SystemExit("Could not safely identify securityContext in postgres.yaml")

# Find the securityContext immediately under the postgres container.
# Keep the existing pod-level fsGroup/seccomp settings untouched.
container_marker = re.search(r'(?m)^\s*containers:\s*\n', s)
if not container_marker:
    raise SystemExit("Could not find containers section in postgres.yaml")

candidate = None
for m in matches:
    if m.start() > container_marker.start():
        candidate = m
        break

if candidate is None:
    raise SystemExit("Could not find container securityContext")

indent = re.match(r'\s*', candidate.group(0)).group(0)
replacement = (
    f"{indent}securityContext:\n"
    f"{indent}  runAsUser: 0\n"
    f"{indent}  allowPrivilegeEscalation: false\n"
    f"{indent}  capabilities:\n"
    f"{indent}    drop:\n"
    f"{indent}      - ALL\n"
    f"{indent}    add:\n"
    f"{indent}      - CHOWN\n"
    f"{indent}      - FOWNER\n"
    f"{indent}      - DAC_OVERRIDE\n"
)
s = s[:candidate.start()] + replacement + s[candidate.end():]
p.write_text(s)
print("PostgreSQL container securityContext updated.")
PY

# ----------------------------------------------------------
# 4. Configure immutable ARM64 image tag and node placement
# ----------------------------------------------------------
log "4. Configuring ARM64 images"

VALUES="$CHART/values.yaml"
[[ -f "$VALUES" ]] || die "Missing values.yaml"

# Use a dedicated deployment override file rather than changing
# unrelated chart defaults.
OVERRIDE="deployments/argocd-production-values.yaml"
mkdir -p deployments

cat > "$OVERRIDE" <<EOF
global:
  imageTag: "$IMAGE_TAG"

nodeSelector:
  kubernetes.io/arch: arm64
  workload-tier: application

EOF

# Verify that all five immutable image tags exist in ECR.
for service in "${SERVICES[@]}"; do
  aws ecr describe-images \
    --region "$REGION" \
    --repository-name "eks-arm64-platform/$service" \
    --image-ids imageTag="$IMAGE_TAG" >/dev/null \
    || die "Image missing in ECR: $service:$IMAGE_TAG"
done

# Confirm the chart has the expected service image configuration.
helm lint "$CHART"

# ----------------------------------------------------------
# 5. Deploy PostgreSQL first, retaining existing PVC
# ----------------------------------------------------------
log "5. Deploying PostgreSQL"

helm upgrade --install "$APP_NAME" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$OVERRIDE" \
  --set postgres.enabled=true \
  --wait --timeout 10m

kubectl rollout status statefulset/postgres \
  -n "$NAMESPACE" --timeout=10m

kubectl get pvc -n "$NAMESPACE"

# ----------------------------------------------------------
# 6. Apply database migrations
# ----------------------------------------------------------
log "6. Applying database migrations"

kubectl get configmap postgres-migrations -n "$NAMESPACE" >/dev/null \
  || die "ConfigMap postgres-migrations missing."

kubectl delete job postgres-migrations -n "$NAMESPACE" \
  --ignore-not-found --wait=true

cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: postgres-migrations
  namespace: microservices
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/arch: arm64
        workload-tier: application
      containers:
        - name: migrate
          image: postgres:17-alpine
          command:
            - /bin/sh
            - -ec
            - |
              until pg_isready -h postgres -p 5432 \
                -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do
                sleep 5
              done
              for f in /migrations/*.sql; do
                echo "Applying $f"
                PGPASSWORD="$PGPASSWORD" psql \
                  -v ON_ERROR_STOP=1 \
                  -h postgres -U "$POSTGRES_USER" \
                  -d "$POSTGRES_DB" -f "$f"
              done
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: platform-secrets
                  key: POSTGRES_USER
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: platform-secrets
                  key: POSTGRES_DB
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: platform-secrets
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: migrations
              mountPath: /migrations
              readOnly: true
      volumes:
        - name: migrations
          configMap:
            name: postgres-migrations
YAML

kubectl wait --for=condition=complete job/postgres-migrations \
  -n "$NAMESPACE" --timeout=10m

kubectl logs job/postgres-migrations -n "$NAMESPACE"

# ----------------------------------------------------------
# 7. Git checks and push chart changes for Argo CD
# ----------------------------------------------------------
log "7. Preparing Git source for Argo CD"

BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || die "Detached HEAD. Switch to your deployment branch."

REMOTE="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$REMOTE" ]] || die "Git remote origin is not configured."

# Do not accidentally commit secrets or Terraform state.
if git check-ignore -q .env; then
  echo ".env is ignored."
else
  die ".env is NOT ignored. Fix .gitignore before pushing."
fi

git check-ignore -q terraform/terraform.tfvars \
  || die "terraform/terraform.tfvars is not ignored. Fix .gitignore."

# Commit only deployment-related files changed/created by this script.
git add "$POSTGRES_TEMPLATE" "$OVERRIDE"

if ! git diff --cached --quiet; then
  git commit -m "Fix PostgreSQL and configure ARM64 Argo CD deployment"
fi

git push -u origin "$BRANCH"

# ----------------------------------------------------------
# 8. Create Argo CD Application
# ----------------------------------------------------------
log "8. Creating Argo CD Application"

cat > /tmp/microservices-platform-application.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_NAME
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: "$REMOTE"
    targetRevision: "$BRANCH"
    path: "$CHART"
    helm:
      valueFiles:
        - ../../deployments/argocd-production-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
EOF

kubectl apply -f /tmp/microservices-platform-application.yaml

# ----------------------------------------------------------
# 9. Wait for Argo CD sync and workloads
# ----------------------------------------------------------
log "9. Waiting for Argo CD"

for i in $(seq 1 30); do
  SYNC="$(kubectl get application "$APP_NAME" -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(kubectl get application "$APP_NAME" -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  echo "Argo CD: sync=${SYNC:-Pending}, health=${HEALTH:-Pending}"

  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    break
  fi
  sleep 10
done

kubectl get application "$APP_NAME" -n "$ARGO_NAMESPACE" -o wide

# ----------------------------------------------------------
# 10. Final validation
# ----------------------------------------------------------
log "10. Validating deployment"

kubectl get pods -n "$NAMESPACE" -o wide
kubectl get services -n "$NAMESPACE"
kubectl get pvc -n "$NAMESPACE"

for deployment in "${SERVICES[@]}"; do
  kubectl rollout status "deployment/$deployment" \
    -n "$NAMESPACE" --timeout=5m
done

kubectl get nodes -L kubernetes.io/arch,workload-tier
kubectl get application "$APP_NAME" -n "$ARGO_NAMESPACE"

echo
echo "=========================================================="
echo "DEPLOYMENT VALIDATION FINISHED"
echo "Argo CD Application: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo "Image tag: $IMAGE_TAG"
echo "=========================================================="
