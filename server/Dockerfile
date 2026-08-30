FROM php:8.3-cli-alpine@sha256:afdf8b1fee58486ccc0dab5f30f634b86873d56dac985f71ba217945647c05ad AS php83-platform-check

RUN apk add --no-cache libpq=18.6-r0 \
    && apk add --no-cache --virtual .build-deps \
        autoconf=2.73-r0 \
        dpkg=1.23.7-r0 \
        dpkg-dev=1.23.7-r0 \
        file=5.47-r2 \
        g++=15.2.0-r5 \
        gcc=15.2.0-r5 \
        make=4.4.1-r4 \
        musl-dev=1.2.6-r2 \
        pkgconf=2.5.1-r0 \
        postgresql18-dev=18.6-r0 \
        re2c=4.5.1-r0 \
    && docker-php-ext-install pdo_pgsql pdo_mysql \
    && apk del .build-deps

RUN echo 'memory_limit=512M' > "$PHP_INI_DIR/conf.d/zz-quality-memory-limit.ini"

COPY --from=composer:2.9@sha256:b09bccd91a78fe8a9ab4b33d707b862e8fe54fec17782e32683ad2a69c46867d /usr/bin/composer /usr/bin/composer

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --dry-run --no-interaction --prefer-dist --no-scripts \
    && touch /php83-platform-check

FROM php83-platform-check AS dependencies

RUN composer install --no-interaction --prefer-dist --no-scripts

FROM dependencies AS quality

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
COPY compose.yaml /compose.yaml
COPY .github/workflows/ci.yml /ci.yml
RUN composer dump-autoload --no-interaction --optimize \
    && composer run lint \
    && composer run analyse

FROM quality AS test

COPY --from=php83-platform-check /php83-platform-check /php83-platform-check
RUN composer test

FROM composer:2.8@sha256:5248900ab8b5f7f880c2d62180e40960cd87f60149ec9a1abfd62ac72a02577c AS production-dependencies

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-scripts

COPY server/ ./
RUN composer dump-autoload --no-dev --classmap-authoritative --no-interaction

FROM dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3 AS production

RUN install-php-extensions pdo_pgsql pdo_mysql pdo_sqlite pcntl \
    && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && addgroup -S -g 10001 openpay \
    && adduser -S -D -H -u 10001 -G openpay openpay

WORKDIR /var/www/html

COPY --chown=openpay:openpay --from=production-dependencies /app ./
COPY server/docker/Caddyfile /etc/frankenphp/Caddyfile

RUN mkdir -p /config/caddy /data/caddy bootstrap/cache storage/app storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs storage/home/.config/psysh \
    && chown -R openpay:openpay /config/caddy /data/caddy bootstrap/cache storage

RUN rm -rf tests phpunit.xml phpstan.neon pint.json .env .env.example

ENV APP_ENV=production \
    APP_DEBUG=false \
    HOME=/var/www/html/storage/home \
    SERVER_NAME=:8080 \
    LOG_CHANNEL=stderr \
    LOG_LEVEL=warning

USER openpay

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD php -r '$headers = @get_headers("http://127.0.0.1:8080/healthz"); exit(($headers[0] ?? "") === "HTTP/1.1 200 OK" ? 0 : 1);'

FROM production AS production-contract

RUN php -m | grep -qx pdo_pgsql \
    && php -m | grep -qx pdo_mysql \
    && php -m | grep -qx pdo_sqlite \
    && php -m | grep -qx pcntl \
    && test ! -e tests \
    && test ! -e phpunit.xml \
    && test ! -e phpstan.neon \
    && test ! -e pint.json \
    && test ! -e .env \
    && test ! -e .env.example \
    && test -f composer.json \
    && test -f composer.lock
