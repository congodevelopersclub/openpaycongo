FROM node:24.19.0-alpine@sha256:2a49bdf71e9fd965a58c1703fd9ddd205b34e5782b692a72dd1d248abb0beb43 AS test
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts=false
COPY server.mjs server.test.mjs ./
RUN npm test
