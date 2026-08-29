FROM php:8.3-cli-alpine AS php83-platform-check

COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --dry-run --no-interaction --prefer-dist --no-scripts \
    && touch /php83-platform-check

FROM composer:2.8 AS dependencies

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --no-interaction --prefer-dist --no-scripts

FROM dependencies AS quality

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN composer dump-autoload --no-interaction --optimize \
    && composer run lint \
    && composer run analyse

FROM quality AS test

COPY --from=php83-platform-check /php83-platform-check /php83-platform-check
RUN composer test
