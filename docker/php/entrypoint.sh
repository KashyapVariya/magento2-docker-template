#!/bin/sh
set -e

# Allow XDEBUG_MODE env var (from .env / docker-compose) to toggle xdebug at runtime
if [ -n "${XDEBUG_MODE}" ]; then
    echo "xdebug.mode = ${XDEBUG_MODE}" > /usr/local/etc/php/conf.d/zz-xdebug-mode.ini
fi

# Composer auth/cache lives on a host-persistent mount so Marketplace keys are
# only entered once, ever, across every project built from this template.
if [ -n "${COMPOSER_HOME}" ]; then
    mkdir -p "${COMPOSER_HOME}"
    chown -R www-data:www-data "${COMPOSER_HOME}"
fi

# Self-heal ownership of the directories Magento actually writes to at runtime.
# Nothing in this image sets a default container USER (php-fpm's master process
# has to start as root), so any `docker compose exec php <cmd>` run without an
# explicit `--user www-data` -- easy to do by habit instead of going through
# `./magento cli` -- silently creates root-owned files under generated/, var/,
# pub/static/, etc. www-data can then never write there again, which surfaces
# later as "permission denied" in generated/ during setup:upgrade/di:compile.
# Checking each directory's own ownership first (one stat call) keeps this
# cheap in the common case where everything is already correct -- the
# (possibly slow, for a big pub/static/) recursive chown only runs on whichever
# directory is actually wrong.
if [ -d /var/www/public_html ]; then
    www_data_uid="$(id -u www-data)"
    www_data_gid="$(id -g www-data)"
    for d in generated var pub/static pub/media app/etc; do
        path="/var/www/public_html/${d}"
        [ -e "$path" ] || continue
        owner="$(stat -c '%u:%g' "$path")"
        if [ "$owner" != "${www_data_uid}:${www_data_gid}" ]; then
            echo "entrypoint.sh: fixing ownership of ${path} (was ${owner}, expected ${www_data_uid}:${www_data_gid})"
            chown -R www-data:www-data "$path"
        fi
    done
fi

exec "$@"
