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
COPY .dockerignore /dockerignore
COPY .github/workflows/ci.yml /ci.yml
RUN composer dump-autoload --no-interaction --optimize \
    && composer run lint \
    && composer run analyse

FROM quality AS test

COPY --from=php83-platform-check /php83-platform-check /php83-platform-check
RUN composer test

FROM composer:2.9@sha256:b09bccd91a78fe8a9ab4b33d707b862e8fe54fec17782e32683ad2a69c46867d AS production-dependencies

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-scripts

COPY server/ ./
RUN composer dump-autoload --no-dev --classmap-authoritative --no-interaction

FROM php:8.3-fpm-alpine@sha256:958112faffb434ca47ac10e51ef40506af76505adac4b879f013540a91d32a67 AS production

RUN apk add --no-cache --upgrade \
        libcrypto3=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        openssl=3.5.8-r0 \
    && apk add --no-cache --virtual .build-deps \
        autoconf=2.73-r0 \
        dpkg=1.23.7-r0 \
        dpkg-dev=1.23.7-r0 \
        file=5.47-r2 \
        g++=15.2.0-r5 \
        gcc=15.2.0-r5 \
        linux-headers=7.0.0-r1 \
        make=4.4.1-r4 \
        musl-dev=1.2.6-r2 \
        pkgconf=2.5.1-r0 \
        postgresql18-dev=18.6-r0 \
        re2c=4.5.1-r0 \
        sqlite-dev=3.53.4-r0 \
    && docker-php-ext-install pdo_pgsql pdo_mysql pdo_sqlite pcntl \
    && apk del .build-deps \
    && apk add --no-cache libpq=18.6-r0 \
    && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

WORKDIR /var/www/html

COPY --from=production-dependencies /app ./

RUN mkdir -p bootstrap/cache storage/app storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs storage/home/.config/psysh \
    && chown -R www-data:www-data bootstrap/cache storage \
    && rm -rf tests phpunit.xml phpstan.neon pint.json .env .env.example

ENV APP_ENV=production \
    APP_DEBUG=false \
    HOME=/var/www/html/storage/home \
    LOG_CHANNEL=stderr \
    LOG_LEVEL=warning

USER www-data

EXPOSE 9000

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
    && test ! -e node_modules \
    && test ! -e vendor/.openpay-host-dependency-marker \
    && test -f composer.json \
    && test -f composer.lock \
    && test ! -w /var/www/html/vendor \
    && test -w /var/www/html/storage \
    && test -w /var/www/html/bootstrap/cache

# The fast gate builds the canonical `test` target first, so this audit cannot
# become a narrower replacement for the whole-tree Pint, Larastan, and test suite.
FROM php83-platform-check AS security

RUN composer audit --locked --no-interaction

FROM composer:2.9@sha256:b09bccd91a78fe8a9ab4b33d707b862e8fe54fec17782e32683ad2a69c46867d AS security-composer-audit-proof

WORKDIR /app

COPY scripts/security/fixtures/vulnerable-composer/composer.lock ./composer.lock
RUN printf '%s\n' '{"name":"openpaycongo/security-audit-proof","require":{"symfony/http-foundation":"2.7.0"}}' > composer.json \
    && if composer audit --locked --no-interaction; then echo 'Composer audit accepted the seeded vulnerable lockfile' >&2; exit 1; fi

FROM dependencies AS security-php-static-proof

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN composer dump-autoload --no-interaction --optimize \
    && printf '%s\n' '<?php' 'final class Broken {public function run(){}}' > app/SecurityGateBrokenFixture.php \
    && if composer run lint; then echo 'Canonical Pint accepted the seeded formatting violation' >&2; exit 1; fi

FROM dependencies AS security-authorization-proof

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN composer dump-autoload --no-interaction --optimize \
    && printf '%s\n' "Route::get('/security-gate-unprotected-fixture', static fn () => response()->noContent());" >> routes/web.php \
    && if php artisan test --filter=AuthorizationBoundaryTest; then echo 'Authorization route inventory accepted an unreviewed public application route' >&2; exit 1; fi
