#!/usr/bin/env bash
# Runs once on the subscriber, from /docker-entrypoint-initdb.d (initdb phase).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
\getenv mon_pw OTEL_MONITOR_PASSWORD
SET pg_stat_statements.track = 'none';
-- statements carrying a password must not reach the log or pg_stat_statements
SET log_min_duration_statement = -1;
SET log_statement = 'none';
SET log_min_error_statement = panic;
CREATE ROLE otel_monitor WITH LOGIN PASSWORD :'mon_pw';
GRANT pg_monitor TO otel_monitor;
GRANT pg_use_reserved_connections TO otel_monitor;
ALTER ROLE otel_monitor SET statement_timeout = '5s';
CREATE DATABASE app;
SQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname app \
  -f /opt/obenhub/app-schema.sql

# The primary's own initdb server listens on its socket only, so a TCP
# answer means the primary is up and has finished its init scripts.
deadline=$((SECONDS + 300))
until pg_isready -h pg-primary-logical -q; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "init-subscriber: pg-primary-logical not accepting connections after 300s" >&2
    exit 1
  fi
  sleep 1
done

# The slot is created on the primary by this statement and is named after
# the subscription (slot_name defaults to the subscription name). The
# statement carries the password, so it is kept out of the error log.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname app <<'SQL'
\getenv logical_pw LOGICAL_PASSWORD
\set conninfo 'host=pg-primary-logical dbname=app user=logical_repl password=' :logical_pw ' sslmode=disable'
SET pg_stat_statements.track = 'none';
-- statements carrying a password must not reach the log or pg_stat_statements
SET log_min_duration_statement = -1;
SET log_statement = 'none';
SET log_min_error_statement = panic;
CREATE SUBSCRIPTION app_sub CONNECTION :'conninfo' PUBLICATION app_pub;
SQL
