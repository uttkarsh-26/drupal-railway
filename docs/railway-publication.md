# Railway Template Publication Payload

Ready-to-paste configuration for publishing **drupal-railway** as a Railway
template. Follow the steps in the README ("Publish as a Railway template").
This file captures the exact values to enter in the template composer.

## Template metadata

- **Name:** Drupal 11 on Railway (Production)
- **Short description (≤140 chars):**
  `Production-ready Drupal 11 + PostgreSQL. Automatic idempotent install, persistent /data volume, readiness health checks, generated secrets, Drush, cron.`
- **Long description:** point to the GitHub README (feature bullets + first-boot flow).

## Services

### 1. Web (from this GitHub repo, `main` branch)

- **Source:** `https://github.com/uttkarsh-26/drupal-railway`
- **Builder:** Dockerfile (Railway auto-detects `Dockerfile` + `railway.toml`)
- **Root directory:** `/` (leave empty)
- **Healthcheck path:** `/health.php` (already in `railway.toml`; confirm it shows in Settings → Healthcheck Path)
- **Start command:** leave default (`apache2-foreground` via entrypoint)
- **Public networking:** HTTP (TCP Proxy default is fine)
- **Volume:** attach volume to this service, mount path **`/data`** (required for persistence)

### 2. PostgreSQL (Railway plugin)

- **Source:** Add → Database → PostgreSQL
- **Private networking:** web service references it as `${{Postgres.DATABASE_URL}}`

## Variables (web service)

| Variable | Value / expression | Notes |
|---|---|---|
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Private URL reference; never expose publicly |
| `DRUPAL_ACCOUNT_PASS` | `${{secret(48)}}` | Generated admin password; required for first install |
| `DRUPAL_SITE_NAME` | `Drupal on Railway` | Optional |
| `DRUPAL_TRUSTED_HOST_PATTERNS` | *(leave unset)* | Defaults allow `*.up.railway.app` + `healthcheck.railway.app` + localhost; set only for custom domains |
| `DB_WAIT_TIMEOUT` | *(leave unset, default 120)* | Raise only if Postgres restarts slowly |

> The `railway.toml` in-repo covers build + deploy (healthcheck, restart
> policy). Volumes and variables are **not** config-as-code — the template
> composer is where the table above gets applied. `secret()` is evaluated per
> deployment, so every template user gets a unique admin password.

## First-boot behavior (expectation for template users)

1. PostgreSQL plugin provisions; web container polls until reachable.
2. Entrypoint creates `/data/files`, `/data/config/sync`, `/data/state`.
3. Idempotent installer takes a Postgres advisory lock, checks the schema, and
   runs `drush site:install` exactly once (concurrent replicas are safe).
4. `health.php` returns 503 until Drupal bootstraps against the DB, then 200 —
   Railway routes traffic only after readiness.
5. Admin login: **/user/login**, username `admin`, password = the generated
   `DRUPAL_ACCOUNT_PASS` (shown in the deploy's Variables tab).

## Post-deploy checklist (for users and for template QA)

- [ ] `/health.php` returns 200 with `drupal_installed:true`
- [ ] Homepage 200, site name renders
- [ ] `/user/login` 200; log in with the generated password
- [ ] `/admin/reports/status` shows no critical errors
- [ ] Upload a file → `sites/default/files` persists after redeploy (volume)
- [ ] Stop/start web service → no re-install (advisory-lock + schema check)
- [ ] `docker compose exec web /opt/drupal-railway/preflight.sh` → RESULT=PASS
- [ ] Custom domain: add pattern to `DRUPAL_TRUSTED_HOST_PATTERNS` and redeploy

## Do NOT put in the free template

Advanced backups (R2/S3), staging environments, Cloudflare hardening, agency
runbooks, disaster recovery automation — these belong in the paid **Drupal 11
Production Operations Kit**.
