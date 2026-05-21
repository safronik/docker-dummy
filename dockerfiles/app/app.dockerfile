# syntax=docker/dockerfile:1

# ----- BASE -----
FROM php:8.4-fpm AS base

# APT
RUN apt update -y && apt install -y cron

# Easy way to install and uninstall extensions with all dependencies
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN ln -s /usr/local/bin/install-php-extensions /usr/local/bin/uninstall-php-extensions

# PHP-modules
# PHP-modules
RUN install-php-extensions mbstring
RUN install-php-extensions zip
RUN install-php-extensions intl
RUN install-php-extensions redis
RUN install-php-extensions pdo_mysql
RUN install-php-extensions pdo_pgsql
RUN install-php-extensions pdo_sqlite
RUN install-php-extensions @composer

# Composer
# RUN php composer require
# RUN php /app/bin/console

# ----- PROD -----
FROM base AS prod
ENV APP_ENV=prod

RUN composer install
RUN install-php-extensions opcache memcached

COPY app.entrypoint /app.entrypoint
RUN sed -i 's/\r//' /app.entrypoint && chmod +x /app.entrypoint
ENTRYPOINT ["/app.entrypoint"]
CMD ["php-fpm"]

# ----- DEV -----
FROM base AS dev
ENV APP_ENV=dev

RUN install-php-extensions xdebug curl

COPY app.entrypoint /app.entrypoint
RUN sed -i 's/\r//' /app.entrypoint && chmod +x /app.entrypoint
ENTRYPOINT ["/app.entrypoint"]
CMD ["php-fpm"]

# ----- TEST -----
FROM base AS test
ENV APP_ENV=test

COPY app.entrypoint /app.entrypoint
RUN sed -i 's/\r//' /app.entrypoint && chmod +x /app.entrypoint
ENTRYPOINT ["/app.entrypoint"]
CMD ["php-fpm"]

# ----- DEBUG -----
FROM base AS debug
ENV APP_ENV=debug

# Utils
RUN apt update && apt install -y mc

# Network utils
RUN apt update && apt install -y iproute2 iputils-ping lsof

COPY app.entrypoint /app.entrypoint
RUN sed -i 's/\r//' /app.entrypoint && chmod +x /app.entrypoint
ENTRYPOINT ["/app.entrypoint"]
CMD ["php-fpm"]
