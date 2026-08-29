FROM composer:2.8 AS test

WORKDIR /app

COPY server/composer.json server/composer.lock ./
RUN composer install --no-interaction --prefer-dist --no-scripts

COPY server/ ./
COPY docs/sales-analytics-response.valid.json docs/sales-analytics.vector.json /docs/
RUN composer dump-autoload --no-interaction --optimize && php artisan test
