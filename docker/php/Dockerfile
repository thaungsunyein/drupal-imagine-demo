# PHP-FPM image for Drupal 10 and 11 (both support PHP 8.3). Debian 13 (trixie): Drupal 11.2+
# needs SQLite 3.45+ for the Kernel tests (SIMPLETEST_DB=sqlite); bookworm ships 3.40.
FROM php:8.3-fpm-trixie

# Run PHP as the same user id that owns the code on the host (1000 = azureuser on the VM),
# so files Drupal and Composer write are not owned by root.
ARG UID=1000
ARG GID=1000
RUN groupmod -o -g "${GID}" www-data && usermod -o -u "${UID}" -g "${GID}" www-data

# Extensions Drupal needs: gd (image styles, incl. WebP), pdo_mysql, opcache, zip, intl; apcu for caching.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git unzip mariadb-client \
      libpng-dev libjpeg62-turbo-dev libfreetype6-dev libwebp-dev libzip-dev libicu-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j"$(nproc)" gd pdo_mysql opcache zip intl \
 && pecl install apcu && docker-php-ext-enable apcu \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY php.ini /usr/local/etc/php/conf.d/zz-drupal.ini
COPY mariadb-client.cnf /etc/mysql/conf.d/zz-drupal-client.cnf

WORKDIR /var/www/html
# Lets you type `drush` instead of `vendor/bin/drush`.
ENV PATH="/var/www/html/vendor/bin:${PATH}" \
    COMPOSER_HOME=/tmp/composer
USER www-data
