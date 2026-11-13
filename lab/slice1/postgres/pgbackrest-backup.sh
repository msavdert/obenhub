#!/bin/sh
# Entrypoint of the pgbackrest-backup service: create the stanza (idempotent),
# then take a backup every BACKUP_INTERVAL seconds. The first backup is a full
# one because pgBackRest turns an incremental backup into a full one when no
# full backup exists; every FULL_EVERY-th backup is a full one. Stop the
# service to stop backups (scenario backup-stale). A failed backup is logged
# and tried again at the next interval.
set -u
stanza=slice1
interval=${BACKUP_INTERVAL:-120}
full_every=${FULL_EVERY:-10}

until pg_isready -q -h /var/run/postgresql; do sleep 2; done
until pgbackrest --stanza="$stanza" stanza-create; do sleep 5; done

n=0
while :; do
  type=incr
  if [ $((n % full_every)) -eq 0 ]; then type=full; fi
  pgbackrest --stanza="$stanza" --type="$type" backup || echo "pgbackrest-backup: $type backup failed" >&2
  n=$((n + 1))
  sleep "$interval"
done
