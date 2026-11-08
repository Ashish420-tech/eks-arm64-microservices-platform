#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="docker-compose.platform.yml"
PROJECT="eks-arm64-platform-local"

echo "================================================="
echo " ARM64 MICROSERVICES PLATFORM DEPLOYMENT"
echo "================================================="

# 1. Validate configuration and images
[[ -f .env ]] || { echo "ERROR: .env is missing"; exit 1; }

for service in api-gateway auth-service employee-service product-service order-service; do
  docker image inspect "${service}:dev-arm64" >/dev/null || {
    echo "ERROR: Missing image ${service}:dev-arm64"
    exit 1
  }

  arch="$(docker image inspect "${service}:dev-arm64" --format '{{.Os}}/{{.Architecture}}')"
  [[ "$arch" == "linux/arm64" ]] || {
    echo "ERROR: ${service} is ${arch}, expected linux/arm64"
    exit 1
  }
  echo "Verified ${service}: ${arch}"
done

# 2. Identify and preserve the existing PostgreSQL data volume
if ! docker inspect platform-postgres >/dev/null 2>&1; then
  echo "ERROR: Existing platform-postgres container not found."
  echo "Stopping deployment to avoid creating a fresh database."
  exit 1
fi

POSTGRES_VOLUME="$(
  docker inspect platform-postgres \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}'
)"

[[ -n "$POSTGRES_VOLUME" ]] || {
  echo "ERROR: Could not identify the existing PostgreSQL named volume."
  echo "No containers have been removed."
  exit 1
}

echo "Existing PostgreSQL volume: $POSTGRES_VOLUME"

# 3. Stop only this project's old host-port processes
echo "Stopping old local service processes on ports 3101-3105..."
for port in 3101 3102 3103 3104 3105; do
  sudo fuser -k "${port}/tcp" 2>/dev/null || true
done

# 4. Replace only the old PostgreSQL container.
#    The existing named volume is preserved.
docker rm -f platform-postgres >/dev/null

# 5. Create the dedicated Compose deployment
cat > "$COMPOSE_FILE" <<'COMPOSE'
name: eks-arm64-platform-local

services:
  postgres:
    image: postgres:17-alpine
    container_name: platform-postgres
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_DB: ${POSTGRES_DB:?POSTGRES_DB missing}
      POSTGRES_USER: ${POSTGRES_USER:?POSTGRES_USER missing}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD missing}
    ports:
      - "5433:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$${POSTGRES_USER}\" -d \"$${POSTGRES_DB}\""]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 15s
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  auth-service:
    image: auth-service:dev-arm64
    platform: linux/arm64
    container_name: platform-auth-service
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: "3000"
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET missing}
    ports:
      - "3102:3000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  employee-service:
    image: employee-service:dev-arm64
    platform: linux/arm64
    container_name: platform-employee-service
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: "3000"
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET missing}
    ports:
      - "3103:3000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  product-service:
    image: product-service:dev-arm64
    platform: linux/arm64
    container_name: platform-product-service
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: "3000"
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET missing}
    ports:
      - "3104:3000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  order-service:
    image: order-service:dev-arm64
    platform: linux/arm64
    container_name: platform-order-service
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: "3000"
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET missing}
    ports:
      - "3105:3000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  api-gateway:
    image: api-gateway:dev-arm64
    platform: linux/arm64
    container_name: platform-api-gateway
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: "3000"
      AUTH_SERVICE_URL: http://auth-service:3000
      EMPLOYEE_SERVICE_URL: http://employee-service:3000
      PRODUCT_SERVICE_URL: http://product-service:3000
      ORDER_SERVICE_URL: http://order-service:3000
    ports:
      - "3101:3000"
    depends_on:
      auth-service:
        condition: service_healthy
      employee-service:
        condition: service_healthy
      product-service:
        condition: service_healthy
      order-service:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 15s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  postgres_data:
    external: true
    name: __POSTGRES_VOLUME__
COMPOSE

sed -i "s|__POSTGRES_VOLUME__|${POSTGRES_VOLUME}|g" "$COMPOSE_FILE"

# 6. Validate Compose before starting anything
echo "Validating Docker Compose configuration..."
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" config --quiet

# 7. Start the platform
echo "Starting PostgreSQL and all five ARM64 services..."
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --wait --wait-timeout 240

# 8. Verify containers
echo
echo "===== CONTAINER STATUS ====="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" ps

echo
echo "===== API GATEWAY HEALTH ====="
curl -fsS http://localhost:3101/health
echo

echo
echo "===== SERVICE READINESS ====="
for port in 3102 3103 3104 3105; do
  echo -n "Port $port: "
  curl -fsS "http://localhost:${port}/ready"
  echo
done

echo
echo "================================================="
echo " PLATFORM DEPLOYMENT COMPLETED"
echo " API Gateway: http://localhost:3101"
echo " PostgreSQL:  localhost:5433"
echo "================================================="
