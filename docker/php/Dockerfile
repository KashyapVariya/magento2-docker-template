# BuildKit doesn't support ARG expansion directly inside `COPY --from=<image>:<tag>`
# ("variable expansion is not supported for --from, define a new stage with FROM
# using ARG from global scope as a workaround" -- straight from its own error
# message). So COMPOSER_VERSION picks the Composer binary via a tiny extra build
# stage instead, where ARG expansion in FROM is fully supported.
ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2

FROM composer:${COMPOSER_VERSION} AS composer_bin

FROM php:${PHP_VERSION}-fpm

ARG UID=1000
ARG GID=1000

# ---- System dependencies required to build the PHP extensions Magento needs ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        cron \
        nano \
        wget \
        msmtp \
        msmtp-mta \
        default-mysql-client \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libicu-dev \
        libxslt1-dev \
        libzip-dev \
        libonig-dev \
        libxml2-dev \
        libssl-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# The mysql/mariadb client pulled in above defaults to requiring TLS (changed
# upstream in recent MariaDB client releases), but the `db` service has no TLS
# configured -- it's local dev traffic on a private compose network. Disable it
# client-side globally, and default the connecting user to "root" (the container
# user is www-data, not a valid db user), so a bare `mysql`/`mariadb` (host/password
# come from MYSQL_HOST/MYSQL_PWD in docker-compose.yml) works out of the box.
RUN printf '[client]\nssl=0\nuser=root\n' > /etc/mysql/conf.d/no-ssl.cnf \
    && printf 'defaults\nauth off\ntls off\n\naccount default\nhost mailpit\nport 1025\nfrom magento@localhost\n\naccount mailpit : default\n' > /etc/msmtprc \
    && chmod 644 /etc/msmtprc

# ---- PHP extensions required by Magento (see lib/versions.tsv for supported versions) ----
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        gd \
        intl \
        pdo_mysql \
        mysqli \
        soap \
        sockets \
        xsl \
        zip \
        exif \
        pcntl \
        ftp \
        opcache

# ---- PECL extensions ----
RUN pecl install redis xdebug \
    && docker-php-ext-enable redis \
    && docker-php-ext-enable xdebug

# ---- Composer (version pinned per Magento version -- see lib/versions.tsv) ----
COPY --from=composer_bin /usr/bin/composer /usr/bin/composer

# ---- n98-magerun2 (github.com/netz98/n98-magerun2): a popular third-party
#      Magento CLI covering things bin/magento doesn't -- db:console, dev:console,
#      sys:check, cache:report, etc. Used via `./magento n98 <args>`. ----
RUN wget -q https://files.magerun.net/n98-magerun2.phar -O /usr/local/bin/n98-magerun2.phar \
    && chmod +x /usr/local/bin/n98-magerun2.phar

# ---- Match container user to host user so bind-mounted files keep sane ownership ----
RUN usermod -u "${UID}" www-data \
    && groupmod -g "${GID}" www-data \
    && mkdir -p /var/www/public_html \
    && chown -R www-data:www-data /var/www/public_html

COPY php.ini /usr/local/etc/php/conf.d/zz-magento.ini
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /var/www/public_html

# Lets you run `magento <command>` directly from ./magento shell, no `php` prefix or `bin/` path needed.
ENV PATH="/var/www/public_html/bin:${PATH}"

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]
