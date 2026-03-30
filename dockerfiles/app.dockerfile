# syntax=docker/dockerfile:1


# ----- PROD -----
FROM php:8.4-fpm as prod

# Easy way to install extensions with all dependencies
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# APT. Common
# RUN apt update && apt install cron

# PECL. Common
RUN install-php-extensions opcache memcached mbstring zip intl redis pdo_mysql pdo_pgsql pdo_sqlite
RUN install-php-extensions @composer

# Composer. Symfony
RUN composer create-project symfony/skeleton:"8.0.*" /app

# RUN cd /app
# RUN php composer require
# RUN php /app/bin/console


# ----- DEV -----
FROM prod as dev
RUN uninstall-php-extension opcache
RUN install-php-extensions xdebug curl

# Crutch. Solution for composer execution problem
RUN echo "alias composer='php -d xdebug.mode=off /usr/local/bin/composer'" >> ~/.bashrc

# Composer. Symfony
RUN cd /app
RUN php composer require --dev symfony/maker-bundle

# NodeJS
# RUN curl -sSL https://deb.nodesource.com/setup_16.x | bash - && apt install -y nodejs


# ----- DEBUG -----
FROM dev as debug
# Utilits
# RUN apt update && apt install -y mc

# Network utilits
RUN apt update && apt install -y iproute2 iputils-ping lsof