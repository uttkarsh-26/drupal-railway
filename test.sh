#!/usr/bin/env bash
#
# drupal-railway end-to-end smoke test.
#
# Builds the image and verifies, against a real local PostgreSQL:
#   1. Concurrent first boot: two containers racing to install on the same
#      fresh database result in exactly ONE install (advisory-lock safety).
#   2. The locked production dependencies pass Composer's security audit.
#   3. Readiness remains 503 before install and while PostgreSQL is unavailable.
#   4. The stack serves HTTP 200 on / and /user/login; /health.php proves a
#      successful Drupal bootstrap; hostile Host headers are rejected.
#   5. Files and the generated hash salt survive a web container recreate and
#      Drupal is NOT re-installed.
#
# Requirements: docker with compose v2, curl, openssl.
#
# Usage:
#   ./test.sh              # full run, cleans up afterwards
#   KEEP=1 ./test.sh       # leave containers/volumes running for debugging
#   WEB_PORT=9090 ./test.sh  # use a different host port
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE=(docker compose)
WEB_PORT="${WEB_PORT:-8080}"
WEB_URL="http://localhost:${WEB_PORT}"
TMPDIR_TEST="$(mktemp -d)"
BUILD_LOG="$TMPDIR_TEST/build.log"

log()  { printf '\033[1;34m[test]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[test] ok\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[test] FAIL\033[0m %s\n' "$*"; exit 1; }

# ---- preflight ------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not found"
"${COMPOSE[@]}" version >/dev/null 2>&1 || fail "docker compose v2 not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

# Fresh random admin password per run; never a committed or fixed default.
export DRUPAL_ACCOUNT_PASS="${DRUPAL_ACCOUNT_PASS:-$(openssl rand -hex 16)}"
log "using a randomly generated DRUPAL_ACCOUNT_PASS (value never printed)"

teardown() {
  if [ "${KEEP:-0}" = "1" ]; then
    log "KEEP=1: leaving containers and volumes running"
  else
    log "tearing down containers and volumes"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR_TEST"
}
trap teardown EXIT

wait_for_db_container() {
  local cid i=0 status
  cid="$("${COMPOSE[@]}" ps -q db)" || true
  [ -n "${cid:-}" ] || fail "db container not running"
  while [ "$i" -lt 90 ]; do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo missing)"
    [ "$status" = "healthy" ] && return 0
    i=$((i + 1))
    sleep 2
  done
  fail "db container never became healthy (last status: ${status:-unknown})"
}

# Prints "HTTP_CODE|BODY" for the health endpoint (BODY may be empty).
fetch_health() {
  local code body
  body="$(curl -sS --max-time 5 "$WEB_URL/health.php" 2>/dev/null)" || body=""
  code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$WEB_URL/health.php" 2>/dev/null)" || code="000"
  printf '%s|%s' "$code" "$body"
}

wait_for_installed() {
  local i=0 response code body
  while [ "$i" -lt 120 ]; do
    response="$(fetch_health)"
    code="${response%%|*}"
    body="${response#*|}"
    if [ "$code" = "200" ] \
      && printf '%s' "$body" | grep -q '"drupal_installed":true' \
      && printf '%s' "$body" | grep -q '"drupal_bootstrap":true'; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  fail "health endpoint did not report 200 + installed within 240s (last: code=$code body=$body)"
}

http_code() { # $1 = path
  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$WEB_URL$1" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

# ---- phase 1: build ----------------------------------------------------------------
log "phase 1/4: building the web image (several minutes on first run)"
if ! "${COMPOSE[@]}" build web >"$BUILD_LOG" 2>&1; then
  tail -n 60 "$BUILD_LOG"
  fail "docker build failed (full log: $BUILD_LOG)"
fi
ok "image built"

image_id="drupal-railway-web:smoke"
docker image inspect "$image_id" >/dev/null 2>&1 || fail "could not resolve the built web image"
docker run --rm --entrypoint composer "$image_id" validate --strict --no-check-publish >/dev/null \
  || fail "composer.json/composer.lock validation failed"
docker run --rm --entrypoint composer "$image_id" audit --locked --no-dev --format=summary \
  || fail "Composer security audit failed"
guzzle_version="$(docker run --rm --entrypoint composer "$image_id" show guzzlehttp/guzzle --format=json \
  | docker run --rm -i --entrypoint php "$image_id" -r '$d=json_decode(stream_get_contents(STDIN), true); echo ltrim($d["versions"][0] ?? "0", "v");')"
docker run --rm --entrypoint php "$image_id" -r 'exit(version_compare($argv[1], "7.15.3", ">=") ? 0 : 1);' "$guzzle_version" \
  || fail "Guzzle $guzzle_version is below the required patched version 7.15.3"
ok "locked dependencies validate and pass security audit (Guzzle $guzzle_version)"

"${COMPOSE[@]}" run --rm --no-deps \
  -e PORT=8081 -e DRUPAL_SKIP_DB_WAIT=1 -e DRUPAL_SKIP_INSTALL=1 \
  web sh -c "grep -qx 'Listen 8081' /etc/apache2/ports.conf && grep -q '<VirtualHost \*:8081>' /etc/apache2/sites-available/000-default.conf" \
  >/dev/null || fail "entrypoint did not adapt Apache to PORT=8081"
ok "entrypoint adapts Apache to Railway's dynamic PORT"

"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d db >/dev/null
wait_for_db_container
ok "database up and healthy"

# A reachable but empty database is not deployment-ready. Start Apache without
# auto-installing and verify Railway would keep the release unrouted.
preinstall_cid="$("${COMPOSE[@]}" run -d --service-ports -e DRUPAL_SKIP_INSTALL=1 web)"
preinstall_code="000"
for _ in $(seq 1 30); do
  preinstall_code="$(http_code /health.php)"
  [ "$preinstall_code" != "000" ] && break
  sleep 1
done
[ "$preinstall_code" = "503" ] || fail "uninstalled health returned HTTP $preinstall_code (expected 503)"
docker rm -f "$preinstall_cid" >/dev/null 2>&1 || true
ok "readiness stays HTTP 503 before Drupal installation"

# ---- phase 2: concurrent first boot ---------------------------------------------------
log "phase 2/4: concurrent first boot (two containers, one fresh database)"
cid_a="$("${COMPOSE[@]}" run -d -e DRUPAL_SKIP_INSTALL=1 web php /opt/drupal-railway/installer.php)"
cid_b="$("${COMPOSE[@]}" run -d -e DRUPAL_SKIP_INSTALL=1 web php /opt/drupal-railway/installer.php)"
code_a="$(docker wait "$cid_a")"
code_b="$(docker wait "$cid_b")"
log_a="$(docker logs "$cid_a" 2>&1 || true)"
log_b="$(docker logs "$cid_b" 2>&1 || true)"
docker rm -f "$cid_a" "$cid_b" >/dev/null 2>&1 || true

[ "$code_a" = "0" ] || fail "installer A exited $code_a (expected 0)"
[ "$code_b" = "0" ] || fail "installer B exited $code_b (expected 0)"
installs="$( { printf '%s\n%s\n' "$log_a" "$log_b"; } | grep -c 'Drupal installed successfully' || true)"
skips="$( { printf '%s\n%s\n' "$log_a" "$log_b"; } | grep -c 'already installed' || true)"
[ "$installs" = "1" ] || fail "expected exactly 1 install, saw $installs"
[ "$skips" = "1" ] || fail "expected exactly 1 skip, saw $skips"
ok "concurrent first boot is safe (1 install + 1 skip, both exit 0)"

# ---- phase 3: full stack + HTTP checks ---------------------------------------------------
log "phase 3/4: starting full stack and verifying HTTP endpoints"
"${COMPOSE[@]}" up -d web >/dev/null
wait_for_installed
ok "health endpoint: HTTP 200, Drupal installed and bootstrapped"

code="$(http_code /)"
[ "$code" = "200" ] || fail "homepage returned HTTP $code (expected 200)"
curl -fsS --max-time 10 "$WEB_URL/" | grep -q "Drupal on Railway (local)" || fail "homepage does not contain the site name"
ok "homepage HTTP 200 with site name"

code="$(http_code /user/login)"
[ "$code" = "200" ] || fail "/user/login returned HTTP $code (expected 200)"
ok "/user/login HTTP 200"

code="$(curl -sS --max-time 10 -H 'Host: attacker.invalid' -o /dev/null -w '%{http_code}' "$WEB_URL/" 2>/dev/null || true)"
code="${code:-000}"
[ "$code" = "400" ] || fail "host-header protection returned HTTP $code for an untrusted host (expected 400)"
ok "untrusted Host header is rejected with HTTP 400"

status="$(docker compose exec -T web drush status --fields=bootstrap,db-status 2>/dev/null || true)"
printf '%s' "$status" | grep -qi "Successful" || fail "drush does not report a successful bootstrap: $status"
ok "drush reports a successful bootstrap"

docker compose exec -T web drush cron >/dev/null 2>&1 || fail "drush cron failed"
ok "Drupal cron completes successfully"

table_count="$(docker compose exec -T db psql -U drupal -d drupal -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ' || true)"
[ "${table_count:-0}" -ge 50 ] || fail "expected >= 50 Drupal tables, found ${table_count:-0}"
ok "database contains $table_count Drupal tables"

health_body="$(curl -fsS --max-time 5 "$WEB_URL/health.php" 2>/dev/null || true)"
printf '%s' "$health_body" | grep -q "$DRUPAL_ACCOUNT_PASS" && fail "health endpoint leaked the admin password"
printf '%s' "$health_body" | grep -qi "postgres://" && fail "health endpoint leaked the connection string"
printf '%s' "$health_body" | grep -qi "pgpassword" && fail "health endpoint leaked a password key"
ok "health endpoint leaks no secrets"

# ---- phase 4: persistence across web container recreation -------------------------------
log "phase 4/4: verifying persistence across web container recreation"
marker="persistence-test-$(date +%s).txt"
docker compose exec -T web sh -c "echo smoke > /opt/drupal/web/sites/default/files/$marker" || fail "could not write marker file"
salt_path="/opt/drupal/web/sites/default/files/.drupal-railway/hash-salt"
salt_before="$(docker compose exec -T web sha256sum "$salt_path" | cut -d' ' -f1)"
[ -n "$salt_before" ] || fail "generated hash salt file is missing"
salt_http="$(http_code /sites/default/files/.drupal-railway/hash-salt)"
case "$salt_http" in
  403|404) ;;
  *) fail "hash salt was downloadable over HTTP $salt_http" ;;
esac
"${COMPOSE[@]}" up -d --force-recreate web >/dev/null
wait_for_installed
docker compose exec -T web sh -c "test -f /opt/drupal/web/sites/default/files/$marker" || fail "marker file lost after web recreation"
salt_after="$(docker compose exec -T web sha256sum "$salt_path" | cut -d' ' -f1)"
[ "$salt_before" = "$salt_after" ] || fail "generated hash salt changed after web recreation"
ok "files and HTTP-protected hash salt survive web container recreation"
code="$(http_code /)"
[ "$code" = "200" ] || fail "homepage returned HTTP $code after recreation (expected 200)"
ok "site still serves HTTP 200 after recreation (no re-install)"

"${COMPOSE[@]}" stop db >/dev/null
down_code="000"
for _ in $(seq 1 20); do
  down_code="$(http_code /health.php)"
  [ "$down_code" = "503" ] && break
  sleep 1
done
[ "$down_code" = "503" ] || fail "health returned HTTP $down_code while PostgreSQL was stopped (expected 503)"
"${COMPOSE[@]}" start db >/dev/null
wait_for_db_container
wait_for_installed
ok "readiness returns 503 during database outage and recovers to 200"

log "ALL SMOKE TESTS PASSED"
