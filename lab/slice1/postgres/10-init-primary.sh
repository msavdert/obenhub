#!/usr/bin/env bash
# Runs once on the primary, from /docker-entrypoint-initdb.d (initdb phase).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v repl_pw="$REPLICATOR_PASSWORD" -v mon_pw="$OTEL_MONITOR_PASSWORD" <<'SQL'
-- the temporary init server runs with the compose command, so
-- pg_stat_statements is loaded: keep the password statements out of it
SET pg_stat_statements.track = 'none';
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
