#!/bin/sh
# drupal-railway entrypoint.
#
# Order of operations (all before Apache starts):
#   1. Create persistent directories (files, config sync) and protect config.
#   2. Wait for PostgreSQL to become reachable (DB_WAIT_TIMEOUT, default 120s).
#   3. Idempotently install Drupal (concurrency-safe via advisory lock).
#   4. Hand sites/default to www-data (Apache runs as www-data).
#   5. Point Apache at Railway's PORT if provided, then start the server.
#
# Escape hatches: DRUPAL_SKIP_DB_WAIT=1, DRUPAL_SKIP_INSTALL=1,
# DRUPAL_SKIP_CHOWN=1. See README for the full variable reference.
set -eu

RAILWAY_DIR="${RAILWAY_DIR:-/opt/drupal-railway}"
WEBROOT="${DRUPAL_WEBROOT:-/opt/drupal/web}"
PERSISTENT_ROOT="${DRUPAL_PERSISTENT_ROOT:-/data}"
FILES_DIR="$PERSISTENT_ROOT/files"
CONFIG_SYNC_DIR="$PERSISTENT_ROOT/config/sync"
STATE_DIR="$PERSISTENT_ROOT/state"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-120}"

log() { echo "[drupal-railway] $*"; }

# --- 1. directories -----------------------------------------------------------
mkdir -p "$FILES_DIR" "$CONFIG_SYNC_DIR" "$STATE_DIR"

# --- 2. database wait ----------------------------------------------------------
if [ "${DRUPAL_SKIP_DB_WAIT:-0}" = "1" ]; then
  log "DRUPAL_SKIP_DB_WAIT set; skipping database wait"
else
  waited=0
  while ! php "$RAILWAY_DIR/check-db.php"; do
    waited=$((waited + 2))
    if [ "$waited" -ge "$DB_WAIT_TIMEOUT" ]; then
      log "database not reachable after ${DB_WAIT_TIMEOUT}s; giving up"
      exit 1
    fi
    log "waiting for database (${waited}s/${DB_WAIT_TIMEOUT}s)..."
    sleep 2
  done
  log "database reachable"
fi

# --- 3. idempotent install ------------------------------------------------------
if [ "${DRUPAL_SKIP_INSTALL:-0}" = "1" ]; then
  log "DRUPAL_SKIP_INSTALL set; skipping install"
else
  log "checking Drupal installation state"
  php "$RAILWAY_DIR/installer.php"
fi

# --- 4. ownership ----------------------------------------------------------------
# The installer runs as root; Apache runs as www-data. Reapplying ownership on
# every boot is cheap for typical sites and heals root-owned files created by
# one-off provisioning (e.g. `docker compose run ... drush`).
if [ "${DRUPAL_SKIP_CHOWN:-0}" != "1" ] && [ "$(id -u)" = "0" ]; then
  chown -R www-data:www-data "$WEBROOT/sites/default" "$PERSISTENT_ROOT" 2>/dev/null || true
fi

# --- 5. port + start ----------------------------------------------------------------
# Railway injects PORT and healthchecks whatever port the app listens on.
if [ -n "${PORT:-}" ] && [ "$PORT" != "80" ]; then
  case "$PORT" in
    *[!0-9]*)
      log "ignoring non-numeric PORT=$PORT"
      ;;
    *)
      log "configuring Apache to listen on PORT=$PORT"
      sed -E -i "s/^Listen [0-9]+$/Listen ${PORT}/" /etc/apache2/ports.conf
      sed -E -i "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-available/000-default.conf
      ;;
  esac
fi

# --- 6. Apache MPM hygiene ----------------------------------------------------------
# Railway's base images can leave multiple MPM modules enabled; Apache aborts
# with "AH00534: More than one MPM loaded". Keep exactly one (prefork, which
# the official PHP Apache image expects), then start the server.
log "ensuring a single Apache MPM (prefork)"
a2dismod -f mpm_event mpm_worker >/dev/null 2>&1 || true
a2enmod -f mpm_prefork >/dev/null 2>&1 || true

log "starting Apache"
exec docker-php-entrypoint "$@"
