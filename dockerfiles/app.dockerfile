# syntax=docker/dockerfile:1
FROM php:8.3-fpm as test

# Easy way to install extensions with all dependencies
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# RUN apt update && apt install cron
RUN install-php-extensions curl opcache pdo_mysql redis sodium iconv mbstring zip fileinfo intl xdebug
RUN install-php-extensions @composer

# Solution for composer execution problem
RUN echo "alias composer='php -d xdebug.mode=off /usr/local/bin/composer'" >> ~/.bashrc
RUN source ~/.bashrc

# DEV
FROM test as dev
RUN install-php-extensions pdo_sqlite pdo_pgsql openssl imap


FROM dev as debug
# Utilits
# RUN apt update && apt install -y mc

# Network utilits
RUN apt update && apt install -y iproute2 iputils-ping lsof

# NodeJS
# RUN curl -sSL https://deb.nodesource.com/setup_16.x | bash - && apt-get install -y nodejs