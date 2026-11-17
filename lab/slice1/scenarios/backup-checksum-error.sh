#!/usr/bin/env bash
# Scenario backup-checksum-error: damage one page of a table on the primary's disk and let pgBackRest find it. A table (autovacuum off, frozen, so nothing dirties or reads its pages afterwards) is written in the postgres database, which is not published; the periodic backups are paused with one backup, whose checkpoint flushes the table (pause_backups); the run waits for headroom under PostgresCheckpointsRequested (checkpoint_headroom); 16 bytes in the tuple area of one page are overwritten in the data file (page header and LSN untouched, so the page checksum no longer matches); an incremental backup is taken. pgBackRest logs "invalid page checksum found", ends "completed successfully" with exit code 0 and sets the backup's error flag (seen 2026-11-17); expect PgBackRestBackupChecksumError. PgBackRestBackupStale stays silent: the backup completed. The revert drops the table, takes a clean incremental backup (which clears pgbackrest_backup_last_error_status) and starts the periodic backups again; it takes no backup when the service could not be stopped. The damaged backup stays in the repository until retention expires it. Time to detect counts from the start of inject() and so includes the headroom wait (inject_seconds; the smoke run of 2026-11-17 waited 339 s of its 390 s).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgBackRestBackupChecksumError:pgbackrest")
# exporter refresh 30 s + scrape 30 s + evaluation 15 s + Alertmanager and margin 120 s, rounded up
DETECT_TIMEOUT=300
TABLE=backup_checksum_error
PAGE=2        # damaged block of the table's first segment
OFFSET=4096   # byte inside that block: the tuple area, past the 24-byte page header

inject() {
  local file bs info label warned backup_end
  psql_p -c "DROP TABLE IF EXISTS $TABLE" >/dev/null || return 1
  psql_p >/dev/null <<EOF || { FAILS+=("creating table $TABLE failed"); return 1; }
CREATE TABLE $TABLE WITH (autovacuum_enabled = off) AS
  SELECT g AS id, repeat('x', 200) AS pad FROM generate_series(1, 2000) g;
VACUUM (FREEZE) $TABLE;
EOF
  pause_backups || { FAILS+=("pausing the periodic backups (stop and one backup) failed"); return 1; }
  wait_until 600 "no requested checkpoint on the primary in the last 5 minutes" checkpoint_headroom || return 1
  file=$(psql_p -c "SELECT current_setting('data_directory') || '/' || pg_relation_filepath('$TABLE')") || return 1
  bs=$(psql_p -c "SHOW block_size") || return 1
  [ "$(psql_p -c "SELECT pg_relation_size('$TABLE') / current_setting('block_size')::int > $PAGE")" = t ] \
    || { FAILS+=("table $TABLE has no block $PAGE"); return 1; }
  docker exec -u postgres "$PRIMARY" sh -c 'printf "OBENHUB-CORRUPT!" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none' \
    sh "$file" $((PAGE * bs + OFFSET)) || { FAILS+=("overwriting block $PAGE of $file failed"); return 1; }
  log "overwrote 16 bytes at block $PAGE offset $OFFSET of $file"
  take_backup || { FAILS+=("the backup after the damage failed"); return 1; }
  backup_end=$(now_ts)
  info=$(pgbr info --output=json) || { FAILS+=("pgbackrest info failed after the damaged backup"); return 1; }
  label=$(jq -r '.[0].backup[-1] | select(.error == true) | .label' <<<"$info")
  # evidence only, null when the log cannot be read; grep -c prints 0 and exits 1 on no match
  warned=$(docker exec "$PRIMARY" sh -c 'grep -c "invalid page checksum found in file $1 at page $2" /var/log/pgbackrest/slice1-backup.log' sh "$file" "$PAGE" || true)
  log "last backup ${label:-has no error flag}; checksum warnings for the page in the backup log: ${warned:-unreadable}"
  EXTRA_JSON=$(jq -n -c --arg file "$file" --argjson page "$PAGE" --arg label "$label" --argjson warned "${warned:-null}" --arg backup_end "$backup_end" \
    '{damaged_file: $file, damaged_page: $page, backup_with_error: $label, damaged_backup_done: $backup_end, log_warnings_for_page: $warned}') || return 1
  [ -n "$label" ] || { FAILS+=("the last backup has no error flag: the damage did not reach the backup"); return 1; }
}
revert() {
  local rc=0
  psql_p -c "DROP TABLE IF EXISTS $TABLE" >/dev/null || rc=1
  # inject() may have failed before pause_backups: never back up next to the service
  # a clean backup clears the error flag of the last backup; when it fails, or
  # the stop failed, the service takes the next one on its own schedule
  if dc stop "$BACKUP_SVC" >/dev/null; then
    take_backup || rc=1
  else
    rc=1
  fi
  dc start "$BACKUP_SVC" >/dev/null || rc=1
  return "$rc"
}
run_scenario backup-checksum-error
