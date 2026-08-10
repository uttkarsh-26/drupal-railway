<?php

/**
 * @file
 * Database readiness probe used by the entrypoint wait loop.
 *
 * Exit code 0 = reachable, 1 = not yet (or misconfigured). Prints to stderr
 * only, and never includes credentials in error messages.
 */

require __DIR__ . '/env.inc.php';

$config = drupal_railway_db_config();
if ($config === NULL) {
  fwrite(STDERR, "[drupal-railway] No database configuration found. Set DATABASE_URL or PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.\n");
  exit(1);
}
if (!extension_loaded('pdo_pgsql')) {
  fwrite(STDERR, "[drupal-railway] The pdo_pgsql PHP extension is missing.\n");
  exit(1);
}

try {
  $pdo = new PDO(drupal_railway_pdo_dsn($config), $config['username'], $config['password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_TIMEOUT => 5,
  ]);
  $pdo->query('SELECT 1');
}
catch (Throwable $e) {
  // Do not echo the driver exception: connection errors can contain host,
  // username, database, or DSN fragments. The detailed error remains
  // available by running a one-off database client inside the project.
  fwrite(STDERR, "[drupal-railway] database not ready (connection failed).\n");
  exit(1);
}

exit(0);
