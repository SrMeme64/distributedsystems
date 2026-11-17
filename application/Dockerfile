FROM node:22-alpine AS dependencies

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY --from=dependencies --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json index.js worker.js init-db.js init-db-users.js catalog-cache.js mongo-config.js redis-client.js instrumentation.js amqp.js review-queues.js review-publisher.js review-message.js ./

USER node

EXPOSE 8080

CMD ["node", "--import", "./instrumentation.js", "index.js"]