#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p logs

start_service() {
  local name="$1"
  local port="$2"

  if curl -fsS "http://localhost:${port}/health" >/dev/null 2>&1; then
    echo "$name already running on port $port"
    return
  fi

  if ss -ltn | grep -q ":${port} "; then
    echo "ERROR: Port $port is occupied."
    exit 1
  fi

  nohup env PORT="$port" npm run start \
    --workspace="$name" > "logs/${name}.log" 2>&1 &

  echo "$!" > "logs/${name}.pid"
  echo "Started $name on port $port"
}

start_service employee-service 3103
start_service product-service 3104
start_service order-service 3105

echo
echo "Waiting for services..."

for port in 3103 3104 3105; do
  for attempt in $(seq 1 20); do
    if curl -fsS "http://localhost:${port}/ready" >/dev/null 2>&1; then
      echo "Port $port: READY"
      break
    fi

    if [[ "$attempt" -eq 20 ]]; then
      echo "Port $port: FAILED"
      exit 1
    fi

    sleep 1
  done
done

echo
echo "All three services are running."
