#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE="docker-compose.platform.yml"
PROJECT="eks-arm64-platform-local"

echo "===== BACKING UP COMPOSE CONFIGURATION ====="
cp "$COMPOSE" "${COMPOSE}.backup"

echo "===== INCREASING HEALTH CHECK TOLERANCE ====="

python3 - <<'PY'
from pathlib import Path

path = Path("docker-compose.platform.yml")
content = path.read_text()

content = content.replace("timeout: 5s", "timeout: 15s")
content = content.replace("interval: 10s", "interval: 20s")
content = content.replace("start_period: 20s", "start_period: 60s")

path.write_text(content)
print("Updated health-check timeouts, intervals and startup grace periods.")
PY

echo "===== VALIDATING COMPOSE ====="
docker compose -p "$PROJECT" -f "$COMPOSE" config --quiet

echo "===== RECREATING ONLY THREE BACKEND SERVICES ====="
docker compose -p "$PROJECT" -f "$COMPOSE" \
  up -d --no-deps --force-recreate --wait --wait-timeout 240 \
  employee-service product-service order-service

echo "===== STARTING API GATEWAY ====="
docker compose -p "$PROJECT" -f "$COMPOSE" \
  up -d --wait --wait-timeout 240 api-gateway

echo "===== FINAL CONTAINER STATUS ====="
docker compose -p "$PROJECT" -f "$COMPOSE" ps

echo "===== API HEALTH TEST ====="
curl -fsS http://localhost:3101/health
echo

echo "===== BACKEND READINESS TESTS ====="
for port in 3102 3103 3104 3105; do
  echo "Port $port:"
  curl -fsS --max-time 20 "http://localhost:$port/ready"
  echo
done

echo "===== DEPLOYMENT FIX COMPLETED ====="
