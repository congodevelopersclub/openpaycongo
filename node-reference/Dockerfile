FROM node:24.19.0-alpine@sha256:2a49bdf71e9fd965a58c1703fd9ddd205b34e5782b692a72dd1d248abb0beb43 AS test
WORKDIR /app
COPY node-reference/package.json node-reference/package-lock.json ./
RUN npm ci --ignore-scripts=false
RUN npm audit --omit=dev --audit-level=high
COPY node-reference/server.mjs node-reference/server.test.mjs node-reference/analytics-parity.test.mjs ./
COPY docs/parity-harness.mjs docs/sales-analytics.vector.json docs/sales-analytics-response.valid.json ./docs/
RUN npm test
