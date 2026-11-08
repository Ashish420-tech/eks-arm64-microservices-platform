#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p logs

# Stop the existing gateway listener on port 3101.
PID="$(sudo fuser -n tcp 3101 2>/dev/null || true)"

if [[ -n "$PID" ]]; then
  echo "Stopping existing API Gateway: $PID"
  sudo kill $PID
  sleep 2
fi

# Start gateway with correct backend URLs.
nohup env \
  PORT=3101 \
  AUTH_SERVICE_URL=http://localhost:3102 \
  EMPLOYEE_SERVICE_URL=http://localhost:3103 \
  PRODUCT_SERVICE_URL=http://localhost:3104 \
  ORDER_SERVICE_URL=http://localhost:3105 \
  npm run start --workspace=api-gateway \
  > logs/api-gateway.log 2>&1 &

echo $! > logs/api-gateway.pid

echo "Waiting for API Gateway..."
for i in $(seq 1 20); do
  if curl -fsS http://localhost:3101/health >/dev/null; then
    echo "API Gateway is ready."
    break
  fi
  sleep 1
done

echo
echo "===== SERVICE HEALTH CHECKS ====="

for port in 3101 3102 3103 3104 3105; do
  printf "Port %s: " "$port"
  curl -sS --max-time 3 "http://localhost:$port/health" || true
  echo
done
