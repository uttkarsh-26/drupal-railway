# Drupal 11 on Railway

[![CI](https://github.com/uttkarsh-26/drupal-railway/actions/workflows/ci.yml/badge.svg)](https://github.com/uttkarsh-26/drupal-railway/actions/workflows/ci.yml)

A production-oriented [Drupal](https://www.drupal.org/) 11 template for
[Railway](https://railway.com), built on a digest-pinned official Drupal 11.4.4
PHP 8.5 Apache image
with PostgreSQL. First boot is fully automatic and idempotent: the container
waits for the database, installs Drupal from environment variables (safely
serialized across concurrent replicas with a Postgres advisory lock), and
starts Apache with a healthcheck Railway can rely on.

**Differentiator: reliability.** Deployment either completes or fails fast
with an actionable log line — no half-installed sites, no "install via the web
UI" steps, no hardcoded credentials.

## How first boot works

1. Entrypoint creates public files and private state directories under the
   `/data` volume. Only `/data/files` is symlinked into Drupal's web root.
2. It polls PostgreSQL until reachable (`DB_WAIT_TIMEOUT`, default 120s).
3. The installer (`installer.php`) takes a Postgres advisory lock, checks
   whether Drupal's schema exists, and runs `drush site:install` only if
   needed. Concurrent replicas block on the lock, then see the completed
   install and skip — exactly one install always wins.
4. Files are handed to `www-data`, Apache is pointed at Railway's `PORT`, and
   the server starts.

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Digest-pinned official Drupal base + locked dependencies + production settings |
| `composer.json`, `composer.lock` | Reproducible Drupal, Drush, and patched Guzzle dependency set |
| `docker/entrypoint.sh` | DB wait → idempotent install → Apache (handles `PORT`) |
| `drupal/env.inc.php` | Shared env parsing (`DATABASE_URL` / `PG*`), used by everything |
| `drupal/settings.php` | Drupal settings driven by environment variables |
| `drupal/installer.php` | Idempotent, advisory-lock-serialized installer |
| `drupal/check-db.php` | DB readiness probe for the wait loop |
| `drupal/health.php` | `/health.php` — DB + Drupal-bootstrap readiness endpoint (no secrets) |
| `drupal/php.ini`, `drupal/apache-https.conf` | Production PHP + https-behind-proxy config |
| `railway.toml` | Railway config-as-code (builder + healthcheck) |
| `docker-compose.yml` | Local stack: Drupal + PostgreSQL (named volumes) |
| `test.sh` | End-to-end smoke test (also runs in GitHub Actions) |

## Local development

Prerequisites: Docker with Compose v2.

```bash
cp .env.example .env        # then set DRUPAL_ACCOUNT_PASS to something strong
docker compose up -d --build
```

Open http://localhost:8080 — Drupal is installed automatically on first boot.
Log in at `/user/login` with `admin` and your `DRUPAL_ACCOUNT_PASS`.

Run the full smoke test (build, concurrent first-boot, HTTP checks, secret
leak check, persistence across container recreation):

```bash
./test.sh              # tears everything down afterwards
KEEP=1 ./test.sh       # keep containers/volumes for debugging
```

Useful while developing:

```bash
docker compose exec web drush status
docker compose exec web drush cache:rebuild
docker compose exec web drush uli          # one-time login link
```

The standard install profile enables Drupal's core Automated Cron module.
`drush cron` is also installed and exercised by the smoke test. For a strict
production schedule, invoke `drush --root=/opt/drupal/web cron` from a Railway
scheduled service that references the same database and `DRUPAL_HASH_SALT`;
contributed cron jobs that read uploads also need access to the files volume.

## Deploying to Railway

1. Push this repository to GitHub.
2. In the Railway dashboard: **New Project → Deploy from GitHub repo** → pick
   this repository. `railway.toml` already selects the Dockerfile builder and
   sets the healthcheck to `/health.php`.
3. Add PostgreSQL: **+ New → Database → Add PostgreSQL**. Reference its private
   URL from the web service as `DATABASE_URL=${{Postgres.DATABASE_URL}}`
   (replace `Postgres` if you renamed the database service).
4. Add a **volume** to the web service mounted at `/data` (persistent uploads,
   private config export, and the auto-generated hash salt). Without it,
   uploaded files are lost on redeploy.
5. Add at least `DRUPAL_ACCOUNT_PASS` as a generated secret
   (`${{secret(48)}}` in the template editor, or generate one locally with
   `openssl rand -hex 24`). Add the other variables you want (table below).
6. Deploy. Watch the logs for
   `[drupal-railway] Drupal installed successfully`, then open the
   `*.up.railway.app` domain. Your admin login is
   `DRUPAL_ACCOUNT_NAME` / `DRUPAL_ACCOUNT_PASS`.

> Variables and volumes are managed in the dashboard (config-as-code covers
> build/deploy settings only).

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `DATABASE_URL` | one of | — | Full Postgres URL (`postgres://user:pass@host:5432/db`). Overrides `PG*`. Provided by Railway Postgres. |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | one of | — | Standard Postgres variables (also provided by Railway Postgres). |
| `DRUPAL_ACCOUNT_PASS` | **yes** | none | Admin password for the first install. No default — install fails fast if missing. |
| `DRUPAL_ACCOUNT_NAME` | no | `admin` | Admin username. |
| `DRUPAL_ACCOUNT_MAIL` | no | `admin@example.com` | Admin email. |
| `DRUPAL_SITE_NAME` | no | `Drupal on Railway` | Site name. |
| `DRUPAL_INSTALL_PROFILE` | no | `standard` | `standard`, `minimal`, or `demo_umami`. |
| `DRUPAL_LOCALE` | no | `en` | Install locale. |
| `DRUPAL_HASH_SALT` | no | auto-generated, persisted on the volume | Drupal hash salt. Set explicitly when running **multiple replicas**. |
| `DRUPAL_TRUSTED_HOST_PATTERNS` | no | Railway and localhost domains only | Comma-separated regex patterns for custom domains, e.g. `^www\.example\.com$,^example\.com$`. |
| `DRUPAL_REVERSE_PROXY` | no | off | `1` to trust `X-Forwarded-For` for client IPs. |
| `DRUPAL_REVERSE_PROXY_ADDRESSES` | no | `0.0.0.0/0` (when enabled) | Comma-separated proxy addresses. |
| `DRUPAL_DB_SSLMODE` / `PGSSLMODE` | no | `prefer` | PostgreSQL SSL mode (exported to libpq). |
| `DB_WAIT_TIMEOUT` | no | `120` | Seconds to wait for the database at boot. |
| `DRUPAL_SKIP_INSTALL` | no | — | `1` skips auto-install (custom provisioning). |
| `DRUPAL_SKIP_DB_WAIT` | no | — | `1` skips the DB wait loop. |
| `DRUPAL_SKIP_CHOWN` | no | — | `1` skips the recursive `chown` at boot. |
| `PORT` | Railway-injected | `80` | Apache listens on this port when set. |

## Publishing this as a Railway template

1. Push the repo to GitHub (make it public to reach the marketplace).
2. Railway dashboard → workspace **Settings → Templates → New Template**.
3. **Add New → GitHub repo** → select this repository.
4. In the template editor, configure the defaults you want users to inherit:
   - Reference the database variable as
     `DATABASE_URL=${{Postgres.DATABASE_URL}}`.
   - Generate `DRUPAL_ACCOUNT_PASS` with `${{secret(48)}}`; do not use a
     shared default or require users to invent one before first deploy.
   - Add optional defaults such as `DRUPAL_SITE_NAME`.
   - Volume: mount `/data` (public files plus private operational state).
   - Healthcheck path: `/health.php` (already in `railway.toml`).
5. **Create Template**, then share the template URL. Publishing to the
   marketplace also makes open-source templates eligible for Railway's
   kickback program. Exact composer values (variables, volume, healthcheck)
   live in [docs/railway-publication.md](docs/railway-publication.md).

## Security notes

- **No committed secrets.** `.env.example` holds placeholders only, there is
  no fixed admin password, and first boot fails fast when
  `DRUPAL_ACCOUNT_PASS` is missing.
- The generated hash salt and config export are persisted under `/data/state`
  and `/data/config`, outside the web root. Only `/data/files` is exposed via a
  symlink for public uploads; the smoke test enforces this boundary.
- **Locked, audited dependencies.** The image build and smoke test fail if
  Composer reports a production advisory. The lock currently includes Guzzle
  7.15.3, fixing the advisories present in the upstream Drupal image lock.
- **`/health.php` never returns credentials** — it reports status flags only
  and returns 200 only after Drupal itself bootstraps (the smoke test asserts
  both properties).
- The admin password is passed to `drush` as a CLI argument, so it is visible
  in the container's process list for the duration of the install; it is never
  written to logs or files. Rotate it after first login if you prefer.
- Trusted hosts default to localhost, Railway's `*.up.railway.app` domains,
  and `healthcheck.railway.app`. Add every custom domain to
  `DRUPAL_TRUSTED_HOST_PATTERNS`; unknown Host headers receive HTTP 400.
- Reverse proxy (client IP trust) is opt-in.
- Local compose database credentials are development-only.

## Troubleshooting

- **`DRUPAL_ACCOUNT_PASS is required for the first install`** — set the
  variable and redeploy.
- **`database not reachable after 120s`** — check the Postgres service and
  that `DATABASE_URL`/`PG*` point at it; raise `DB_WAIT_TIMEOUT` if the
  database restarts slowly.
- **Reinstall from scratch** — delete the Postgres volume/database and the
  web files volume, then redeploy (the installer runs again on an empty DB).
- **`Access denied` on the site** — trusted-host mismatch: set
  `DRUPAL_TRUSTED_HOST_PATTERNS` to cover your domain(s).
- **Updating Drupal/dependencies** — update the pinned base tag/digest and
  lockfile together, run `./test.sh`, and commit both. Never update only the
  human-readable tag while retaining an old digest.

## License

MIT — see [LICENSE](LICENSE).
