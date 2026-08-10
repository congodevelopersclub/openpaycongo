FROM node:24.19.0-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts && npm audit --audit-level=high
COPY . .
RUN npm run test && npm run build

FROM nginxinc/nginx-unprivileged:1.31.3-alpine@sha256:a6c3ec0c0d249d68b0682df854d4a9e222b90fb607dc3fcf2f1d2fcbc85d347e
ENV NGINX_ENVSUBST_FILTER=^BACKEND_ORIGIN$
COPY nginx.template.conf /etc/nginx/templates/default.conf.template
COPY nginx-security-headers.conf /etc/nginx/openpay-security-headers.conf
COPY nginx-proxy.conf /etc/nginx/openpay-proxy.conf
COPY --from=build /src/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD wget -q -O - http://127.0.0.1:8080/ui-healthz || exit 1
