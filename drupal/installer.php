<?php

/**
 * @file
 * Idempotent, concurrency-safe Drupal installer.
 *
 * Designed to be run from the container entrypoint before Apache starts:
 *   1. Serializes first-run installs across replicas/containers with a
 *      PostgreSQL session advisory lock.
 *   2. Skips cleanly when Drupal is already installed.
 *   3. Fails fast with actionable messages when required env vars are missing.
 *
 * Never prints credentials.
 */

require __DIR__ . '/env.inc.php';

// Arbitrary advisory lock key, unique to this template's install path.
const DRUPAL_RAILWAY_LOCK_KEY = 72837462;

function drupal_railway_installer_fail(string $message): never {
  fwrite(STDERR, "[drupal-railway] " . $message . "\n");
  exit(1);
}

$webroot = getenv('DRUPAL_WEBROOT') ?: '/opt/drupal/web';

$config = drupal_railway_db_config();
if ($config === NULL) {
  drupal_railway_installer_fail('No database configuration found. Set DATABASE_URL or PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE and redeploy.');
}
if (!extension_loaded('pdo_pgsql')) {
  drupal_railway_installer_fail('The pdo_pgsql PHP extension is missing.');
}

try {
  $pdo = new PDO(drupal_railway_pdo_dsn($config), $config['username'], $config['password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_TIMEOUT => 10,
  ]);
}
catch (Throwable $e) {
  drupal_railway_installer_fail('cannot connect to the database (connection failed; credentials are not printed).');
}

// Hold the advisory lock for the rest of this process. A concurrent replica
// blocks here until we finish, then re-checks and skips. The lock is released
// automatically when the connection closes (including on failure).
$pdo->exec('SELECT pg_advisory_lock(' . DRUPAL_RAILWAY_LOCK_KEY . ')');

try {
  if (drupal_railway_is_installed($pdo)) {
    echo "[drupal-railway] Drupal is already installed; nothing to do.\n";
    exit(0);
  }

  $account_pass = getenv('DRUPAL_ACCOUNT_PASS');
  if (!is_string($account_pass) || $account_pass === '') {
    drupal_railway_installer_fail('DRUPAL_ACCOUNT_PASS is required for the first install. Generate one (e.g. `openssl rand -hex 24`), set it as a Railway variable, and redeploy.');
  }

  $site_name = getenv('DRUPAL_SITE_NAME');
  $site_name = (is_string($site_name) && $site_name !== '') ? $site_name : 'Drupal on Railway';
  $account_name = getenv('DRUPAL_ACCOUNT_NAME');
  $account_name = (is_string($account_name) && $account_name !== '') ? $account_name : 'admin';
  $account_mail = getenv('DRUPAL_ACCOUNT_MAIL');
  $account_mail = (is_string($account_mail) && $account_mail !== '') ? $account_mail : 'admin@example.com';
  $profile = getenv('DRUPAL_INSTALL_PROFILE');
  $profile = (is_string($profile) && $profile !== '') ? $profile : 'standard';
  $locale = getenv('DRUPAL_LOCALE');
  $locale = (is_string($locale) && $locale !== '') ? $locale : 'en';

  $allowed_profiles = ['standard', 'minimal', 'demo_umami'];
  if (!in_array($profile, $allowed_profiles, TRUE)) {
    drupal_railway_installer_fail("Unsupported DRUPAL_INSTALL_PROFILE '$profile'. Allowed: " . implode(', ', $allowed_profiles) . '.');
  }

  echo "[drupal-railway] Installing Drupal (profile: $profile, site: $site_name)...\n";

  // The account password is passed on the command line, so it is visible in
  // the container's process list for the duration of the install. It is never
  // written to logs or files.
  $command = sprintf(
    'cd %s && drush -y site:install %s --site-name=%s --account-name=%s --account-pass=%s --account-mail=%s --locale=%s 2>&1',
    escapeshellarg($webroot),
    escapeshellarg($profile),
    escapeshellarg($site_name),
    escapeshellarg($account_name),
    escapeshellarg($account_pass),
    escapeshellarg($account_mail),
    escapeshellarg($locale)
  );

  $output = [];
  $status = 0;
  exec($command, $output, $status);
  foreach ($output as $line) {
    echo $line . "\n";
  }
  if ($status !== 0) {
    drupal_railway_installer_fail("drush site:install failed (exit $status). The container will restart and retry; see the log above.");
  }

  echo "[drupal-railway] Drupal installed successfully.\n";
  exit(0);
}
finally {
  // Closing the connection releases the advisory lock.
  $pdo = NULL;
}
