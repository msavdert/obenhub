#!/usr/bin/env bash
# Runs once, on the first node, after initdb (Patroni bootstrap.post_bootstrap;
# $1 is a connection URL for the superuser). The roles replicate to the others.
set -euo pipefail

# \getenv (psql 15+) reads the passwords from the environment, so they never
# appear on a command line (ps); fail closed, as \getenv leaves a missing
# variable unset
: "${OTEL_MONITOR_PASSWORD:?OTEL_MONITOR_PASSWORD not set}"
: "${APP_PASSWORD:?APP_PASSWORD not set}"

psql -X -v ON_ERROR_STOP=1 "$1" <<'SQL'
\getenv mon_pw OTEL_MONITOR_PASSWORD
\getenv app_pw APP_PASSWORD
-- statements carrying a password must not reach the log
SET log_min_duration_statement = -1;
SET log_statement = 'none';
SET log_min_error_statement = panic;
CREATE ROLE otel_monitor WITH LOGIN PASSWORD :'mon_pw';
GRANT pg_monitor TO otel_monitor;
GRANT pg_use_reserved_connections TO otel_monitor;
ALTER ROLE otel_monitor SET statement_timeout = '5s';
CREATE ROLE app WITH LOGIN PASSWORD :'app_pw';
CREATE DATABASE app OWNER app;
SQL
