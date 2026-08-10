<?php

// @file
// Drupal 11 settings for the drupal-railway template.
//
// Everything dynamic is driven by environment variables; see README.md for
// the full reference. This file is intentionally trimmed compared to
// default.settings.php — anything not set here keeps Drupal's defaults.

// ---- Shared helpers (env parsing; must stay dependency-free) ----------------
require_once (getenv('RAILWAY_DIR') ?: '/opt/drupal-railway') . '/env.inc.php';

// ---- Database ----------------------------------------------------------------
// Configured entirely from DATABASE_URL or PG* environment variables.
$db_config = drupal_railway_db_config();
if ($db_config !== NULL) {
  $databases['default']['default'] = [
    'database' => $db_config['database'],
    'username' => $db_config['username'],
    'password' => $db_config['password'],
    'host' => $db_config['host'],
    'port' => $db_config['port'],
    'driver' => 'pgsql',
    'prefix' => '',
    'namespace' => 'Drupal\\pgsql\\Driver\\Database\\pgsql',
  ];
}

// ---- Hash salt ----------------------------------------------------------------
// Required by Drupal. Prefer DRUPAL_HASH_SALT; otherwise generate once and
// persist it inside the (persistent) files directory so sessions survive
// restarts. Set DRUPAL_HASH_SALT explicitly when running multiple replicas.
$settings['hash_salt'] = drupal_railway_hash_salt($app_root);

// ---- Trusted hosts --------------------------------------------------------------
// Railway's generated domains and deploy-time healthcheck host are allowed by
// default. Custom domains must be explicitly added as a comma-separated regex
// list via DRUPAL_TRUSTED_HOST_PATTERNS. Never derive this allowlist from the
// incoming Host header: doing so would defeat Drupal's Host-header protection.
$host_patterns = [
  '^localhost$',
  '^127\\.0\\.0\\.1$',
  '^healthcheck\\.railway\\.app$',
  '^.+\\.up\\.railway\\.app$',
];
$env_patterns = getenv('DRUPAL_TRUSTED_HOST_PATTERNS');
if (is_string($env_patterns) && $env_patterns !== '') {
  foreach (explode(',', $env_patterns) as $pattern) {
    $pattern = trim($pattern);
    if ($pattern !== '') {
      $host_patterns[] = $pattern;
    }
  }
}
$settings['trusted_host_patterns'] = $host_patterns;

// ---- Reverse proxy (opt-in) -------------------------------------------------------
// On Railway, set DRUPAL_REVERSE_PROXY=1 so client IPs from X-Forwarded-For
// are honored (useful for flood control / logging). DRUPAL_REVERSE_PROXY_ADDRESSES
// overrides the default of trusting all addresses — only set that when you know
// Railway's proxy ranges.
if (getenv('DRUPAL_REVERSE_PROXY') === '1') {
  $settings['reverse_proxy'] = TRUE;
  $proxy_addresses = getenv('DRUPAL_REVERSE_PROXY_ADDRESSES');
  $settings['reverse_proxy_addresses'] = (is_string($proxy_addresses) && $proxy_addresses !== '')
    ? array_map('trim', explode(',', $proxy_addresses))
    : ['0.0.0.0/0'];
}

// ---- Files & configuration -----------------------------------------------------------
$settings['file_public_path'] = 'sites/default/files';
// Exported configuration lives on the persistent volume; the entrypoint
// protects it with a .htaccess that denies all requests.
$settings['config_sync_directory'] = $app_root . '/sites/default/files/config/sync';

// ---- Logging -----------------------------------------------------------------------------
// Hide errors from visitors; they still land in the container logs.
$config['system.logging']['error_level'] = 'hide';
