# drupal-railway: production-oriented Drupal 11 for Railway.
# Base: official Drupal 11.4.4 / PHP 8.5 Apache image. The multi-architecture
# digest prevents an upstream tag mutation from silently changing a build.
FROM drupal:11.4.5-php8.5-apache-bookworm@sha256:c9bd9eba8d5c95044ac4fb6e7dd66579f0d5dae401c9f203211ac3084f32852d

# Composer runs as root during the build and needs generous memory for
# dependency resolution.
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1

# Use the committed dependency lock instead of resolving packages during every
# image build. The lock includes Drush and Guzzle >=7.15.3; the latter patches
# the 2026 host/cookie/redirect advisories present in the upstream image lock.
WORKDIR /opt/drupal
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-progress --optimize-autoloader \
    && composer validate --strict --no-check-publish \
    && composer audit --locked --no-dev \
    && composer clear-cache

ENV PATH="/opt/drupal/vendor/bin:${PATH}" \
    RAILWAY_DIR="/opt/drupal-railway" \
    DRUPAL_PERSISTENT_ROOT="/data"

# Production PHP settings (memory, uploads, opcache, errors hidden).
COPY drupal/php.ini /usr/local/etc/php/conf.d/30-drupal-railway.ini

# Trust Railway's edge proxy so Drupal generates https:// URLs.
COPY drupal/apache-https.conf /etc/apache2/conf-available/drupal-railway-https.conf
RUN a2enconf drupal-railway-https

# Runtime helpers live OUTSIDE the web root so they are never served.
COPY drupal/env.inc.php drupal/check-db.php drupal/installer.php preflight.sh /opt/drupal-railway/
RUN chmod +x /opt/drupal-railway/preflight.sh

# Drupal overlay: env-driven settings + lightweight health endpoint.
COPY drupal/settings.php /opt/drupal/web/sites/default/settings.php
COPY drupal/health.php /opt/drupal/web/health.php

# Entrypoint: DB wait -> idempotent install -> Apache.
COPY docker/entrypoint.sh /usr/local/bin/drupal-railway-entrypoint
RUN chmod +x /usr/local/bin/drupal-railway-entrypoint \
    && mkdir -p /data/files \
    && ln -s /data/files /opt/drupal/web/sites/default/files

# Persistent user content and private operational state. Public files are
# exposed through the web-root symlink; salt/config state stays outside it.
# NOTE: no Dockerfile VOLUME here — Railway rejects that instruction; the
# volume is attached via Railway (see railway.toml/README).

EXPOSE 80

ENTRYPOINT ["drupal-railway-entrypoint"]
CMD ["apache2-foreground"]
