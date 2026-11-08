FROM node:24-alpine AS dependencies

WORKDIR /app

COPY services/order-service/package.json ./package.json

RUN npm install --omit=dev

FROM node:24-alpine AS production

ENV NODE_ENV=production

WORKDIR /app

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=dependencies /app/node_modules ./node_modules

COPY --chown=appuser:appgroup services/shared ./services/shared

COPY --chown=appuser:appgroup services/order-service/src ./services/order-service/src

USER appuser

EXPOSE 3000

CMD ["node", "services/order-service/src/server.js"]
