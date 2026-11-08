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

echo "Generating production Dockerfiles..."

for SERVICE in "${SERVICES[@]}"; do
  DIR="services/$SERVICE"
  mkdir -p "$DIR"

  cat > "$DIR/Dockerfile" <<'EOF'
# Stage 1: Install dependencies
FROM node:24-alpine AS dependencies

WORKDIR /app

COPY package*.json ./

RUN npm install --omit=dev --ignore-scripts

# Stage 2: Production image
FROM node:24-alpine AS production

ENV NODE_ENV=production

WORKDIR /app

RUN addgroup -S appgroup && \
    adduser -S appuser -G appgroup

COPY --from=dependencies --chown=appuser:appgroup \
    /app/node_modules ./node_modules

COPY --chown=appuser:appgroup \
    services/shared ./services/shared

COPY --chown=appuser:appgroup \
    services/${SERVICE}/package.json ./package.json

COPY --chown=appuser:appgroup \
    services/${SERVICE}/src ./src

USER appuser

EXPOSE 3000

CMD ["node", "src/server.js"]
EOF

  cat > "$DIR/.dockerignore" <<'EOF'
node_modules
coverage
.env
.env.*
*.log
*.pid
EOF

  echo "Created $DIR/Dockerfile"
done

echo
echo "Checking Dockerfiles..."
for SERVICE in "${SERVICES[@]}"; do
  test -s "services/$SERVICE/Dockerfile"
done

echo
echo "All five Dockerfiles created."
