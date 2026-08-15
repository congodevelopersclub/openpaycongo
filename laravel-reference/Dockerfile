FROM composer:2.8 AS test

WORKDIR /app

COPY laravel-reference/composer.json laravel-reference/composer.lock ./
RUN composer install --no-interaction --prefer-dist --no-scripts

COPY laravel-reference/ ./
COPY docs/sales-analytics-response.valid.json /docs/sales-analytics-response.valid.json
RUN composer dump-autoload --no-interaction --optimize && php artisan test
