#!/bin/sh
# Entrypoint of the pgbackrest-backup service: create the stanza (idempotent),
# then keep one backup per BACKUP_INTERVAL seconds. The schedule is read from
# the repository, not kept in the process, so a restart of the service neither
# backs up at once nor restarts the full cycle: before each backup it sleeps
# until the last backup's stop time + BACKUP_INTERVAL (no sleep when there is
# none or it is overdue). The backup is a full one when no full backup exists
# or the last full one is older than FULL_EVERY * BACKUP_INTERVAL, else an
# incremental one. Stop the service to stop backups (scenario backup-stale).
# A failed backup is logged and tried again at once after the next look.
# The info JSON has keys in alphabetical order, so a backup's timestamp object
# is followed by its type: {"timestamp":{"start":N,"stop":N},"type":"full"}.
set -u
stanza=slice1
interval=${BACKUP_INTERVAL:-600}
full_every=${FULL_EVERY:-10}

until pg_isready -q -h /var/run/postgresql; do sleep 2; done
until pgbackrest --stanza="$stanza" stanza-create; do sleep 5; done

while :; do
  # "<stop> <type>" per backup
  backups=$(pgbackrest --stanza="$stanza" --output=json info 2>/dev/null \
    | grep -o '"timestamp":{"start":[0-9]*,"stop":[0-9]*},"type":"[a-z]*"' \
    | sed 's/.*"stop":\([0-9]*\)},"type":"\([a-z]*\)"/\1 \2/')
  now=$(date +%s)
  last=$(printf '%s\n' "$backups" | awk 'NF { if ($1 > m) m = $1 } END { print m + 0 }')
  last_full=$(printf '%s\n' "$backups" | awk '$2 == "full" { if ($1 > m) m = $1 } END { print m + 0 }')
  wait=$((last + interval - now))
  if [ "$last" -gt 0 ] && [ "$wait" -gt 0 ]; then
    echo "pgbackrest-backup: last backup ended $((now - last)) s ago, next in $wait s"
    sleep "$wait"
    now=$(date +%s)
  fi
  type=incr
  if [ "$last_full" -eq 0 ] || [ $((now - last_full)) -gt $((full_every * interval)) ]; then type=full; fi
  pgbackrest --stanza="$stanza" --type="$type" backup || { echo "pgbackrest-backup: $type backup failed" >&2; sleep 60; }
done
