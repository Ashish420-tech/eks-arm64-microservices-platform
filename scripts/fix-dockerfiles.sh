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
  cat > "services/$SERVICE/Dockerfile" <<EOF
FROM node:24-alpine AS dependencies

WORKDIR /app

COPY services/$SERVICE/package.json ./package.json

RUN npm install --omit=dev

FROM node:24-alpine AS production

ENV NODE_ENV=production

WORKDIR /app

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=dependencies /app/node_modules ./node_modules

COPY --chown=appuser:appgroup services/shared ./services/shared

COPY --chown=appuser:appgroup services/$SERVICE/src ./services/$SERVICE/src

USER appuser

EXPOSE 3000

CMD ["node", "services/$SERVICE/src/server.js"]
EOF

  cat > "services/$SERVICE/.dockerignore" <<'EOF'
node_modules
.env
.env.*
coverage
*.log
*.pid
EOF

  echo "Fixed: $SERVICE"
done

echo "All five Dockerfiles regenerated."
