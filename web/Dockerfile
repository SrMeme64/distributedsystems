FROM node:22-alpine AS web-build

WORKDIR /web
COPY package.json package-lock.json ./
RUN npm ci
COPY telemetry.js ./
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.28-alpine

COPY nginx.k8s.conf /etc/nginx/conf.d/default.conf
COPY site1/ /usr/share/nginx/html/
COPY catalog.js /usr/share/nginx/html/catalog.js
COPY catalog.css /usr/share/nginx/html/catalog.css
COPY --from=web-build /web/dist/telemetry.js /usr/share/nginx/html/telemetry.js

EXPOSE 8080
