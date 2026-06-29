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

# ----- EMPTY -----
FROM base AS blank
ENV ENV_STAGE=blank

RUN composer install

COPY blank.entrypoint /blank.entrypoint
RUN sed -i 's/\r//' /blank.entrypoint && chmod +x /blank.entrypoint
ENTRYPOINT ["/blank.entrypoint"]
CMD ["php-fpm"]

# ----- PROD -----
FROM base AS prod
ENV ENV_STAGE=prod

RUN composer install
RUN install-php-extensions opcache memcached

COPY backend.entrypoint /backend.entrypoint
RUN sed -i 's/\r//' /backend.entrypoint && chmod +x /backend.entrypoint
ENTRYPOINT ["/backend.entrypoint"]
CMD ["php-fpm"]

# ----- DEV -----
FROM base AS dev
ENV ENV_STAGE=dev

RUN install-php-extensions xdebug-3.4.7
RUN install-php-extensions curl

COPY backend.entrypoint /backend.entrypoint
RUN sed -i 's/\r//' /backend.entrypoint && chmod +x /backend.entrypoint
ENTRYPOINT ["/backend.entrypoint"]
CMD ["php-fpm"]

# ----- TEST -----
FROM base AS test
ENV ENV_STAGE=test

COPY backend.entrypoint /backend.entrypoint
RUN sed -i 's/\r//' /backend.entrypoint && chmod +x /backend.entrypoint
ENTRYPOINT ["/backend.entrypoint"]
CMD ["php-fpm"]

# ----- DEBUG -----
FROM base AS debug
ENV ENV_STAGE=debug

# Utils
RUN apt update && apt install -y mc

# Network utils
RUN apt update && apt install -y iproute2 iputils-ping lsof

COPY backend.entrypoint /backend.entrypoint
RUN sed -i 's/\r//' /backend.entrypoint && chmod +x /backend.entrypoint
ENTRYPOINT ["/backend.entrypoint"]
CMD ["php-fpm"]
