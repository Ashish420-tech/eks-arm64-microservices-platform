#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

SERVICES=(
  api-gateway
  auth-service
  employee-service
  product-service
  order-service
)

for SERVICE in "${SERVICES[@]}"; do
  echo
  echo "Building ARM64 image: $SERVICE"

  docker buildx build \
    --platform linux/arm64 \
    --load \
    -t "$SERVICE:dev-arm64" \
    -f "services/$SERVICE/Dockerfile" \
    .
done

echo
echo "===== VERIFY IMAGE ARCHITECTURES ====="

for SERVICE in "${SERVICES[@]}"; do
  docker image inspect "$SERVICE:dev-arm64" \
    --format '{{.RepoTags}} -> {{.Os}}/{{.Architecture}}'
done

echo
echo "All ARM64 images built."
