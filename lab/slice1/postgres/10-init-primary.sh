#!/usr/bin/env bash
# Runs once on the primary, from /docker-entrypoint-initdb.d (initdb phase).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v repl_pw="$REPLICATOR_PASSWORD" -v mon_pw="$OTEL_MONITOR_PASSWORD" <<'SQL'
-- the temporary init server runs with the compose command, so
-- pg_stat_statements is loaded: keep the password statements out of it
SET pg_stat_statements.track = 'none';
-- statements carrying a password must not reach the log or pg_stat_statements
SET log_min_duration_statement = -1;
SET log_statement = 'none';
SET log_min_error_statement = panic;
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'repl_pw';
CREATE ROLE otel_monitor WITH LOGIN PASSWORD :'mon_pw';
GRANT pg_monitor TO otel_monitor;
GRANT pg_use_reserved_connections TO otel_monitor;
ALTER ROLE otel_monitor SET statement_timeout = '5s';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_create_physical_replication_slot('standby1');
SQL

# The image's pg_hba.conf has no remote replication entry ("all" does not
# match the replication keyword). Only the repl network may replicate.
echo "host replication replicator 10.213.0.0/24 scram-sha-256" >>"$PGDATA/pg_hba.conf"

# Stage 2: database `app`, its publication and the subscription role.
# logical_repl is the least PostgreSQL 18 needs on the publisher: LOGIN and
# REPLICATION plus SELECT on the published tables (initial table copy); it is
# not a superuser and owns nothing. The subscriber connects to database `app`,
# so pg_hba matches the database name (the "replication" keyword is only for
# physical connections).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v logical_pw="$LOGICAL_PASSWORD" -v app_pw="$APP_PASSWORD" <<'SQL'
SET pg_stat_statements.track = 'none';
-- statements carrying a password must not reach the log or pg_stat_statements
SET log_min_duration_statement = -1;
SET log_statement = 'none';
SET log_min_error_statement = panic;
CREATE ROLE logical_repl WITH REPLICATION LOGIN PASSWORD :'logical_pw';
-- the application role: PgBouncer logs in as it (the connections-exhausted
-- scenario reuses it and resets its password, which stays the same value)
CREATE ROLE app WITH LOGIN PASSWORD :'app_pw';
CREATE DATABASE app;
SQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname app \
  -f /opt/obenhub/app-schema.sql -f - <<'SQL'
CREATE PUBLICATION app_pub FOR TABLE customers, orders;
GRANT SELECT ON customers, orders TO logical_repl;
SQL

# Put the logical entries before the image's catch-all "host all all all":
# logical_repl may connect from the logical network only. First match wins.
{
  echo "host app logical_repl 10.214.0.0/24 scram-sha-256"
  echo "host all logical_repl all reject"
  cat "$PGDATA/pg_hba.conf"
} >"$PGDATA/pg_hba.conf.new"
mv "$PGDATA/pg_hba.conf.new" "$PGDATA/pg_hba.conf"
