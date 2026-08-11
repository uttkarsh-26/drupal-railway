#!/usr/bin/env bash
#
# drupal-railway deployment preflight.
#
# Secret-safe validation for the deployed container: checks required
# environment variables, database configuration, PHP PostgreSQL extensions and
# writable persistent storage — WITHOUT ever printing credentials.
#
# Installed in the image at /opt/drupal-railway/preflight.sh. Run it inside
# the container (docker compose exec web /opt/drupal-railway/preflight.sh).
# Exit 0 = container is ready to boot; exit 1 = fix the printed items first.
#
set -uo pipefail

LOG="$(mktemp)"
# Tee everything so we can scan the log for accidental secret exposure at the end.
exec > >(tee "$LOG") 2>&1

FAILED=0
note() { printf 'preflight: %s\n' "$*"; }
bad()  { note "FAIL  $*"; FAILED=1; }
good() { note "ok    $*"; }

# 1. Admin password -------------------------------------------------------------
if [ -z "${DRUPAL_ACCOUNT_PASS:-}" ]; then
  bad "DRUPAL_ACCOUNT_PASS is not set (generate one, e.g. openssl rand -hex 24)"
else
  case "$DRUPAL_ACCOUNT_PASS" in
    changeme|password|admin|drupal)
      bad "DRUPAL_ACCOUNT_PASS looks like a placeholder value" ;;
    *)
      good "DRUPAL_ACCOUNT_PASS is set (${#DRUPAL_ACCOUNT_PASS} chars; value never printed)" ;;
  esac
fi

# 2. Database configuration ------------------------------------------------------
if [ -n "${DATABASE_URL:-}" ]; then
  if [[ "$DATABASE_URL" =~ ^postgres(ql)?://([^:/@]+):([^@/]*)@([^:/@]+):([0-9]+)/([^?]+) ]]; then
    [ -n "${BASH_REMATCH[3]}" ] || bad "DATABASE_URL has an empty password"
    good "DATABASE_URL is parseable (host=${BASH_REMATCH[4]}, db=${BASH_REMATCH[6]}; password never printed)"
  else
    bad "DATABASE_URL must start with postgres:// or postgresql:// and include credentials"
  fi
elif [ -n "${PGHOST:-}" ] && [ -n "${PGDATABASE:-}" ]; then
  good "PGHOST/PGDATABASE fallback configuration present (credentials never printed)"
else
  bad "set DATABASE_URL or PGHOST+PGDATABASE (plus PGPORT/PGUSER/PGPASSWORD as needed)"
fi

# 3. PHP PostgreSQL driver ----------------------------------------------------
# Drupal needs PDO pgsql; the procedural pgsql extension is optional.
if php -m 2>/dev/null | grep -qix "pdo_pgsql"; then
  good "PHP PDO pgsql driver loaded"
else
  bad "missing PHP extension: pdo_pgsql (required by Drupal)"
fi

# 4. Writable persistent storage ----------------------------------------------------
persistent_root="${DRUPAL_PERSISTENT_ROOT:-/data}"
if [ -d "$persistent_root" ]; then
  probe="$persistent_root/.preflight-$$"
  if ( umask 077 && : > "$probe" ) 2>/dev/null; then
    rm -f "$probe"
    good "persistent storage $persistent_root is writable"
  else
    bad "persistent storage $persistent_root is not writable by $(id -un)"
  fi
else
  bad "persistent storage $persistent_root does not exist (mount your Railway volume at $persistent_root)"
fi

# 5. Secret-leak self-check ----------------------------------------------------------
# If any known credential appears in our own output, the script itself is broken.
leaked=""
for secret in "${DRUPAL_ACCOUNT_PASS:-}" "${DATABASE_URL:-}" "${PGPASSWORD:-}"; do
  [ -n "$secret" ] && [ "${#secret}" -ge 8 ] || continue
  if grep -Fq "$secret" "$LOG"; then
    leaked="$leaked $secret"
  fi
done
rm -f "$LOG"
if [ -n "$leaked" ]; then
  bad "a secret value appeared in preflight output (internal bug — fix the script)"
  printf 'preflight: RESULT=FAIL\n' >&2
  exit 1
fi

if [ "$FAILED" = "1" ]; then
  printf 'preflight: RESULT=FAIL — fix the items above and re-run.\n' >&2
  exit 1
fi
printf 'preflight: RESULT=PASS — container is ready to boot.\n'
