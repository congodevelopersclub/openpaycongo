FROM node:24.19.0-alpine@sha256:2a49bdf71e9fd965a58c1703fd9ddd205b34e5782b692a72dd1d248abb0beb43 AS test
WORKDIR /app
COPY node-reference/package.json node-reference/package-lock.json ./
RUN npm ci --ignore-scripts=false
RUN npm audit --omit=dev --audit-level=high
COPY node-reference/server.mjs node-reference/fixture-loader.mjs node-reference/server.test.mjs node-reference/pairing-repository.mjs node-reference/pairing-repository.test.mjs ./node-reference/
COPY docs/sales-analytics.vector.json docs/sales-analytics-response.valid.json ./docs/
RUN node --test node-reference/*.test.mjs
