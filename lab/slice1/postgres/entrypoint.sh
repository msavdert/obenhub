#!/usr/bin/env bash
# Shared entrypoint for primary and standby.
# STANDBY_OF=<host>: when PGDATA is empty, clone it with pg_basebackup first.
set -euo pipefail

mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# local WAL archive (archive_command in compose.yaml); a volume mounts it as root; chmod undoes a SIGKILLed archiver-failing scenario
mkdir -p /archive
chown postgres:postgres /archive
chmod 755 /archive

if [ -n "${STANDBY_OF:-}" ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  until PGPASSWORD="$REPLICATOR_PASSWORD" gosu postgres pg_isready -h "$STANDBY_OF" -q; do
    sleep 1
  done
  PGPASSWORD="$REPLICATOR_PASSWORD" gosu postgres pg_basebackup \
    -h "$STANDBY_OF" -U replicator -D "$PGDATA" \
    -R -X stream -S standby1
fi

exec docker-entrypoint.sh "$@"
