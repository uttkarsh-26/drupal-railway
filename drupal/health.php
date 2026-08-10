<?php

/**
 * @file
 * Lightweight health endpoint for Railway.
 *
 * Returns HTTP 200 only when the database is reachable, Drupal is installed,
 * and the Drupal service container can bootstrap. This is a readiness check,
 * not merely a TCP liveness check, so Railway never routes traffic to a
 * half-installed or broken release. It never echoes credentials or errors.
 *
 * Railway healthchecks originate from healthcheck.railway.app; settings.php
 * explicitly allows that host.
 */

require (getenv('RAILWAY_DIR') ?: '/opt/drupal-railway') . '/env.inc.php';

header('Content-Type: application/json');

function drupal_railway_health_respond(int $status, array $payload): void {
  http_response_code($status);
  echo json_encode($payload, JSON_UNESCAPED_SLASHES) . "\n";
  exit;
}

$config = drupal_railway_db_config();
if ($config === NULL) {
  drupal_railway_health_respond(503, ['status' => 'degraded', 'database' => 'unconfigured', 'drupal_installed' => FALSE]);
}
if (!extension_loaded('pdo_pgsql')) {
  drupal_railway_health_respond(503, ['status' => 'degraded', 'database' => 'driver_missing', 'drupal_installed' => FALSE]);
}

try {
  $pdo = new PDO(drupal_railway_pdo_dsn($config), $config['username'], $config['password'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_TIMEOUT => 3,
  ]);
  $pdo->query('SELECT 1');
  $installed = drupal_railway_is_installed($pdo);
}
catch (Throwable $e) {
  drupal_railway_health_respond(503, ['status' => 'degraded', 'database' => 'unreachable', 'drupal_installed' => FALSE]);
}

if (!$installed) {
  drupal_railway_health_respond(503, ['status' => 'starting', 'database' => 'ok', 'drupal_installed' => FALSE]);
}

try {
  $autoloader = require dirname(__DIR__) . '/vendor/autoload.php';
  $request = Symfony\Component\HttpFoundation\Request::create(
    '/',
    'GET',
    [],
    [],
    [],
    ['HTTP_HOST' => 'healthcheck.railway.app', 'HTTPS' => 'on']
  );
  $kernel = Drupal\Core\DrupalKernel::createFromRequest($request, $autoloader, 'prod');
  $kernel->boot();
  Drupal::database()->query('SELECT 1')->fetchField();
  $kernel->shutdown();
}
catch (Throwable $e) {
  drupal_railway_health_respond(503, ['status' => 'degraded', 'database' => 'ok', 'drupal_installed' => TRUE, 'drupal_bootstrap' => FALSE]);
}

drupal_railway_health_respond(200, ['status' => 'ok', 'database' => 'ok', 'drupal_installed' => TRUE, 'drupal_bootstrap' => TRUE]);
