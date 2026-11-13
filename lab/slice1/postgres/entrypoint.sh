#!/usr/bin/env bash
# Shared entrypoint for primary and standby.
# STANDBY_OF=<host>: when PGDATA is empty, clone it with pg_basebackup first.
set -euo pipefail

mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# ARCHIVE_STANZA=<stanza>: archive WAL with pgBackRest (ADR 0007). The
# repository and the socket directory are named volumes shared with the
# pgbackrest-backup service and mounted as root. A volume copies its ownership
# from the image on first use; chown makes it so for a volume that already
# existed.
if [ -n "${ARCHIVE_STANZA:-}" ]; then
  chown postgres:postgres /var/run/postgresql
  # -R and u+rwX also undo a SIGKILLed archiver-failing scenario (it removes access to a repository directory)
  chown -R postgres:postgres /var/lib/pgbackrest
  chmod -R u+rwX /var/lib/pgbackrest
  set -- "$@" -c archive_mode=on -c "archive_command=pgbackrest --stanza=${ARCHIVE_STANZA} archive-push %p"
fi

# The clone is marked incomplete before it starts and unmarked after pg_basebackup
# returned, so a container killed in the middle (the data volume survives) is
# cloned again instead of starting from a half-copied PGDATA. The marker lives
# beside PGDATA, in the volume, because pg_basebackup needs an empty directory.
clone_marker=/var/lib/postgresql/.basebackup-incomplete
if [ -n "${STANDBY_OF:-}" ] && { [ ! -s "$PGDATA/PG_VERSION" ] || [ -e "$clone_marker" ]; }; then
  case "${STANDBY_OF_WAIT:-300}" in
    ''|*[!0-9]*|0*|???????*) echo "entrypoint: STANDBY_OF_WAIT must be a positive integer of at most 6 digits without leading zeros (seconds), got '${STANDBY_OF_WAIT:-}'" >&2; exit 1 ;;
  esac
  touch "$clone_marker"
  mkdir -p "$PGDATA"
  find "$PGDATA" -mindepth 1 -delete
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  # bounded: after the deadline the container exits and restart: unless-stopped tries again
  deadline=$((SECONDS + ${STANDBY_OF_WAIT:-300}))
  until PGPASSWORD="$REPLICATOR_PASSWORD" gosu postgres pg_isready -h "$STANDBY_OF" -q; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "entrypoint: $STANDBY_OF not accepting connections after ${STANDBY_OF_WAIT:-300}s" >&2
      exit 1
    fi
    sleep 1
  done
  PGPASSWORD="$REPLICATOR_PASSWORD" gosu postgres pg_basebackup \
    -h "$STANDBY_OF" -U replicator -D "$PGDATA" \
    -R -X stream -S standby1
  rm -f "$clone_marker"
fi

exec docker-entrypoint.sh "$@"
