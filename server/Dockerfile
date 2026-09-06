FROM php:8.3-cli-alpine@sha256:afdf8b1fee58486ccc0dab5f30f634b86873d56dac985f71ba217945647c05ad AS php83-platform-check

RUN apk add --no-cache libpq=18.6-r0 icu-libs=78.1-r0 libzip=1.11.4-r2 \
    && apk add --no-cache --virtual .build-deps \
        autoconf=2.73-r0 \
        dpkg=1.23.7-r0 \
        dpkg-dev=1.23.7-r0 \
        file=5.47-r2 \
        g++=15.2.0-r5 \
        gcc=15.2.0-r5 \
        icu-dev=78.1-r0 \
        libzip-dev=1.11.4-r2 \
        make=4.4.1-r4 \
        musl-dev=1.2.6-r2 \
        pkgconf=2.5.1-r0 \
        postgresql18-dev=18.6-r0 \
        re2c=4.5.1-r0 \
    && docker-php-ext-install intl pdo_pgsql pdo_mysql zip \
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
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json docs/operations.md /docs/
COPY compose.yaml /compose.yaml
COPY .dockerignore /dockerignore
COPY .github/workflows/ci.yml /ci.yml
COPY scripts/ci/ /scripts/ci/
RUN composer dump-autoload --no-interaction --optimize \
    && composer run lint \
    && composer run analyse

FROM quality AS test

COPY --from=php83-platform-check /php83-platform-check /php83-platform-check
# This file exists only in the disposable test image. PHPUnit's explicit
# environment overrides in phpunit.xml remain authoritative.
RUN : > .env \
    && composer test

FROM dependencies AS focused

ARG TEST_FILTER
COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json docs/operations.md /docs/
COPY compose.yaml /compose.yaml
COPY .dockerignore /dockerignore
COPY .github/workflows/ci.yml /ci.yml
COPY scripts/ci/ /scripts/ci/
RUN test -n "$TEST_FILTER" \
    && : > .env \
    && composer dump-autoload --no-interaction --optimize \
    && composer test -- --fail-on-empty-test-suite --filter="$TEST_FILTER"

FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS assets

WORKDIR /app

COPY server/package.json server/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

COPY server/resources ./resources
COPY server/public ./public
COPY server/vite.config.js ./
RUN npm run build

FROM quality AS browser-app

COPY --from=assets /app/public/build ./public/build
RUN touch database/browser.sqlite

FROM php83-platform-check AS production-dependencies

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-scripts

COPY server/ ./
COPY --from=assets /app/public/build ./public/build
RUN composer dump-autoload --no-dev --classmap-authoritative --no-interaction

FROM php:8.3-fpm-alpine@sha256:958112faffb434ca47ac10e51ef40506af76505adac4b879f013540a91d32a67 AS production

RUN apk add --no-cache --upgrade \
        icu-libs=78.1-r0 \
        libzip=1.11.4-r2 \
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
        icu-dev=78.1-r0 \
        libzip-dev=1.11.4-r2 \
        linux-headers=7.0.0-r1 \
        make=4.4.1-r4 \
        musl-dev=1.2.6-r2 \
        pkgconf=2.5.1-r0 \
        postgresql18-dev=18.6-r0 \
        re2c=4.5.1-r0 \
        sqlite-dev=3.53.4-r0 \
    && docker-php-ext-install intl pdo_pgsql pdo_mysql pdo_sqlite pcntl zip \
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

RUN php -m | grep -qx sodium \
    && php -m | grep -qx pdo_pgsql \
    && php -m | grep -qx pdo_mysql \
    && php -m | grep -qx pdo_sqlite \
    && php -m | grep -qx pcntl \
    && test ! -e tests \
    && test ! -e phpunit.xml \
    && test ! -e phpstan.neon \
    && test ! -e pint.json \
    && test ! -e .env \
    && test ! -e .env.example \
    && test ! -e storage/oauth-private.key \
    && test ! -e storage/oauth-public.key \
    && test ! -e node_modules \
    && test ! -e vendor/.openpay-host-dependency-marker \
    && test -f composer.json \
    && test -f composer.lock \
    && test -f public/build/manifest.json \
    && test ! -w /var/www/html/vendor \
    && test -w /var/www/html/storage \
    && test -w /var/www/html/bootstrap/cache

# The fast gate builds the canonical `test` target first, so this audit cannot
# become a narrower replacement for the whole-tree Pint, Larastan, and test suite.
FROM php83-platform-check AS security

RUN composer audit --locked --no-interaction

FROM php83-platform-check AS security-composer-audit-proof

WORKDIR /app

COPY scripts/security/fixtures/vulnerable-composer/composer.lock ./composer.lock
RUN set -eu; printf '%s\n' '{"name":"openpaycongo/security-audit-proof","require":{"symfony/http-foundation":"2.7.0"}}' > composer.json; set +e; output="$(composer audit --locked --no-interaction 2>&1)"; status=$?; set -e; printf '%s\n' "$output"; test "$status" -ne 0 \
    && printf '%s\n' "$output" | grep -q 'CVE-2019-10913'

FROM dependencies AS security-php-static-proof

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN set -eu; composer dump-autoload --no-interaction --optimize; printf '%s\n' '<?php' '' 'declare(strict_types=1);' '' 'final class SecurityGateBrokenFixture' '{' '    public function run(): int' '    {' "        return 'not-an-int';" '    }' '}' > app/SecurityGateBrokenFixture.php; set +e; output="$(composer run analyse 2>&1)"; status=$?; set -e; printf '%s\n' "$output"; test "$status" -ne 0 \
    && printf '%s\n' "$output" | grep -q 'SecurityGateBrokenFixture.php'

FROM dependencies AS security-authorization-proof

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN set -eu; : > .env; composer dump-autoload --no-interaction --optimize; printf '%s\n' "Route::get('/security-gate-lookalike-fixture', static fn () => response()->noContent())->middleware('auth.optional');" >> routes/web.php; set +e; output="$(php artisan test --filter=AuthorizationBoundaryTest 2>&1)"; status=$?; set -e; printf '%s\n' "$output"; test "$status" -ne 0 \
    && printf '%s\n' "$output" | grep -q 'security-gate-lookalike-fixture'
