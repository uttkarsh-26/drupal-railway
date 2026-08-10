<?php

/**
 * @file
 * Shared environment helpers for the drupal-railway template.
 *
 * Dependency-free (runs before Drupal bootstraps), never outputs anything,
 * and never exposes credentials. Used by settings.php, check-db.php,
 * installer.php and health.php.
 *
 * Supported inputs:
 *   - DATABASE_URL, e.g. postgres://user:password@host:5432/dbname?sslmode=require
 *   - PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (Railway Postgres plugin)
 *   - DRUPAL_DB_SSLMODE / PGSSLMODE (default: prefer)
 */

/**
 * Returns normalized PostgreSQL connection settings, or NULL when no
 * database environment is configured.
 */
function drupal_railway_db_config(): ?array {
  static $config = NULL;
  if ($config !== NULL) {
    return $config;
  }

  $url = getenv('DATABASE_URL');
  if (is_string($url) && $url !== '') {
    $parts = parse_url($url);
    if ($parts === FALSE || !isset($parts['host'])) {
      $config = NULL;
      return $config;
    }
    $config = [
      'host' => $parts['host'],
      'port' => isset($parts['port']) ? (string) $parts['port'] : '5432',
      'database' => isset($parts['path']) ? ltrim(rawurldecode($parts['path']), '/') : '',
      'username' => isset($parts['user']) ? rawurldecode($parts['user']) : '',
      'password' => isset($parts['pass']) ? rawurldecode($parts['pass']) : '',
      'sslmode' => drupal_railway_sslmode($parts['query'] ?? NULL),
    ];
    return $config;
  }

  $host = getenv('PGHOST');
  if (!is_string($host) || $host === '') {
    $config = NULL;
    return $config;
  }
  $config = [
    'host' => $host,
    'port' => getenv('PGPORT') ?: '5432',
    'database' => getenv('PGDATABASE') ?: '',
    'username' => getenv('PGUSER') ?: '',
    'password' => getenv('PGPASSWORD') ?: '',
    'sslmode' => drupal_railway_sslmode(NULL),
  ];
  return $config;
}

/**
 * Resolves the SSL mode: DATABASE_URL query > DRUPAL_DB_SSLMODE > PGSSLMODE >
 * libpq default. Exports it as PGSSLMODE so libpq applies it to Drupal's own
 * PDO connections (Drupal's pgsql driver does not pass sslmode itself).
 */
function drupal_railway_sslmode(?string $query): string {
  if ($query !== NULL) {
    parse_str($query, $params);
    if (isset($params['sslmode']) && is_string($params['sslmode']) && $params['sslmode'] !== '') {
      $mode = $params['sslmode'];
      putenv('PGSSLMODE=' . $mode);
      return $mode;
    }
  }
  $mode = getenv('DRUPAL_DB_SSLMODE');
  if (!is_string($mode) || $mode === '') {
    $mode = getenv('PGSSLMODE');
  }
  if (!is_string($mode) || $mode === '') {
    $mode = 'prefer';
  }
  putenv('PGSSLMODE=' . $mode);
  return $mode;
}

/**
 * Builds a PDO DSN for the helper scripts. sslmode is deliberately omitted:
 * libpq picks it up from the PGSSLMODE environment variable.
 */
function drupal_railway_pdo_dsn(array $config): string {
  return sprintf(
    'pgsql:host=%s;port=%s;dbname=%s',
    $config['host'],
    $config['port'],
    $config['database']
  );
}

/**
 * True when Drupal's schema exists in the database (key_value table).
 */
function drupal_railway_is_installed(PDO $pdo): bool {
  $stmt = $pdo->query("SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = 'key_value'");
  return (bool) $stmt->fetchColumn();
}

/**
 * Hash salt resolution: DRUPAL_HASH_SALT env > persisted file in the files
 * directory > random fallback.
 *
 * Lives here (not in settings.php) because Drupal includes settings.php more
 * than once during installation, and function declarations there would fatal.
 */
function drupal_railway_hash_salt(string $app_root): string {
  $salt = getenv('DRUPAL_HASH_SALT');
  if (is_string($salt) && $salt !== '') {
    return $salt;
  }
  // Operational state must live outside the web root. Public uploads are a
  // symlink into the same volume, but this sibling state directory is never
  // reachable through Apache.
  $persistent_root = getenv('DRUPAL_PERSISTENT_ROOT') ?: '/data';
  $file = $persistent_root . '/state/hash-salt';
  if (is_file($file)) {
    $existing = trim((string) file_get_contents($file));
    if ($existing !== '') {
      return $existing;
    }
  }
  $dir = dirname($file);
  if (is_dir($dir) && is_writable($dir)) {
    $salt = bin2hex(random_bytes(32));
    if (@file_put_contents($file, $salt) !== FALSE) {
      @chmod($file, 0600);
      return $salt;
    }
  }
  // Last resort: the files directory is not writable. Drupal still boots,
  // but sessions will not survive restarts — set DRUPAL_HASH_SALT.
  return bin2hex(random_bytes(32));
}
