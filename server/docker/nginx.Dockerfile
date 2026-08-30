FROM nginx:alpine@sha256:1f25fedd50aec27413031afb3a4f8ee4effcc9d843f6a76e81bfa92245ac5c06

# Keep the web tier on the exact OpenSSL remediation used by the FPM image.
RUN apk add --no-cache --upgrade \
        libcrypto3=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        openssl=3.5.8-r0

COPY server/docker/nginx.conf.template /etc/nginx/openpay.conf.template
COPY server/docker/nginx-proxy-map.conf.template /etc/nginx/openpay-proxy-map.conf.template
COPY server/docker/10-openpay-proxies.sh /docker-entrypoint.d/10-openpay-proxies.sh
COPY server/public/ /var/www/html/public/

RUN chmod 0555 /docker-entrypoint.d/10-openpay-proxies.sh \
    && chown -R nginx:nginx /var/cache/nginx /var/www/html/public

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
