FROM php:8.2-fpm

# Libs
#RUN apt-get update && apt-get install -y libfreetype6-dev
RUN	apt-get update && apt-get install -y libjpeg62-turbo-dev
RUN	apt-get update && apt-get install -y libpng-dev
RUN	apt-get update && apt-get install -y libonig-dev
RUN	apt-get update && apt-get install -y libmcrypt-dev
RUN	apt-get update && apt-get install -y zlib1g-dev
RUN	apt-get update && apt-get install -y libzip-dev
RUN apt-get update && apt-get install -y zlib1g
RUN apt-get update && apt-get install -y libcurl4-gnutls-dev
RUN apt-get update && apt-get install -y libevent-dev
RUN apt-get update && apt-get install -y libicu-dev
RUN apt-get update && apt-get install -y libidn2-dev
#RUN apt-get update && apt-get install -y libidnkit2
#RUN apt-get update && apt-get install -y libidnkit
#RUN apt-get update && apt-get install -y libidn11
#RUN apt-get update && apt-get install -y libgnutls28-dev

# Convenience utils
#RUN apt-get update && apt-get install -y iputils-ping
#RUN apt-get update && apt-get install -y iproute2
#RUN apt-get update && apt-get install -y mc

# Debug utilits
#RUN apt-get update && apt-get netcat -y mc
#RUN apt-get update && apt-get lsof -y mc

# Network apps
RUN	apt-get install -y curl
RUN	apt-get install -y wget

# PHP-extensions via Docker
#RUN docker-php-ext-install -j$(nproc) iconv
#RUN docker-php-ext-install -j$(nproc) mbstring
#RUN docker-php-ext-install -j$(nproc) pdo_mysql
#RUN docker-php-ext-install -j$(nproc) mysqli
#RUN docker-php-ext-install -j$(nproc) zip
#RUN docker-php-ext-configure gd && docker-php-ext-install -j$(nproc) gd 

# PHP-extensions via PECL
RUN yes "" | pecl install xdebug
#RUN pecl install propro && docker-php-ext-enable propro
#RUN pecl install raphf && docker-php-ext-enable raphf
#RUN pecl install mcrypt && docker-php-ext-enable mcrypt
#RUN pecl install redis && docker-php-ext-enable redis
#RUN yes "" | pecl install pecl_http && docker-php-ext-enable http
#RUN pecl install curl
#RUN pecl install fileinfo
#RUN pecl install ftp
#RUN pecl install mbstring
#RUN pecl install mysqli
#RUN pecl install openssl
#RUN pecl install yaml
#RUN pecl install pdo_mysql
#RUN pecl install pdo_oci
#RUN pecl install pdo_odbc
#RUN pecl install pdo_pgsql
#RUN pecl install pdo_sqlite

# Composer
#RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# NodeJS
# DISABLED
#RUN curl -sSL https://deb.nodesource.com/setup_16.x | bash - && apt-get install -y nodejs