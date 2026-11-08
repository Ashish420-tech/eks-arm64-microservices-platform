#!/usr/bin/env bash
set -Eeuo pipefail

CHART="helm/applications/microservices-platform"
OUTPUT="/tmp/microservices-platform-rendered.yaml"

command -v helm >/dev/null || {
  echo "ERROR: Helm is not installed."
  exit 1
}

echo "===== HELM LINT ====="
helm lint "$CHART"

echo
echo "===== RENDERING KUBERNETES MANIFESTS ====="
helm template microservices-platform "$CHART" \
  --namespace microservices > "$OUTPUT"

echo "Rendered manifest: $OUTPUT"

echo
echo "===== RESOURCE COUNTS ====="
printf "Deployments: "
grep -c '^kind: Deployment$' "$OUTPUT"

printf "Services: "
grep -c '^kind: Service$' "$OUTPUT"

printf "StatefulSets: "
grep -c '^kind: StatefulSet$' "$OUTPUT"

printf "ARM64 node selectors: "
grep -c 'kubernetes.io/arch: arm64' "$OUTPUT"

echo
echo "===== EXPECTED SERVICE CHECK ====="
for service in api-gateway auth-service employee-service product-service order-service; do
  if grep -q "name: $service" "$OUTPUT"; then
    echo "OK: $service"
  else
    echo "ERROR: $service missing"
    exit 1
  fi
done

grep -q 'name: postgres' "$OUTPUT" || {
  echo "ERROR: PostgreSQL StatefulSet missing"
  exit 1
}

echo
echo "===== HELM VALIDATION PASSED ====="
