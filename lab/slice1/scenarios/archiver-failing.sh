#!/usr/bin/env bash
# Scenario archiver-failing: remove all access to the repository directory that holds the archived WAL (chmod 000, so pgBackRest's archive-push, the archive_command of the primary, fails) and switch WAL segments until more than 8 wait for the archiver; expect PostgresArchivingFailing (pg_stat_archiver: last failure newer than last success) and PostgresArchiveBacklog (.ready files in pg_wal/archive_status) for pg-primary. The same fault makes `pgbackrest info` report an error for the stanza (status 99, seen 2026-11-13), so PgBackRestStanzaError may fire, and PgBackRestBackupStale may fire after the revert while the age of the last backup is above the lab parameter; whether either fires depends on how long the fault is held, so both are allowed, not expected. The periodic backups are paused for the run (after one synchronous backup); the revert restores the mode, takes a backup that must succeed and resumes them; the archiver retries about once a minute and drains the backlog, which resolves both alerts.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresArchivingFailing:pg-primary" "PostgresArchiveBacklog:pg-primary")
ALLOW=("PgBackRestStanzaError:pgbackrest" "PgBackRestBackupStale:pgbackrest")
FAILING_SQL="SELECT (last_failed_time > coalesce(last_archived_time, '-infinity'))::int FROM pg_stat_archiver"
inject() {
  local i
  # no periodic backup (and checkpoint) while the fault is held; one backup is taken first
  pause_backups || return 1
  docker exec -u root "$PRIMARY" chmod 000 "$PGBR_WAL_DIR" || return 1
  # pg_switch_wal does nothing unless WAL was written since the last switch
  for i in $(seq 1 12); do
    psql_p -c "SELECT pg_logical_emit_message(true, 'obenhub', 'archiver-failing')" -c "SELECT pg_switch_wal()" >/dev/null || return 1
  done
  # the archiver tries again about once a minute; wait for its failure to show
  for i in $(seq 1 24); do
    [ "$(psql_p -c "$FAILING_SQL")" = 1 ] && break
    sleep 5
  done
  log "pg_stat_archiver: $(psql_p -F ' ' -c "SELECT failed_count, last_failed_wal FROM pg_stat_archiver")"
  [ "$(psql_p -c "$FAILING_SQL")" = 1 ] || return 1
  [ "$(psql_p -c "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'")" -gt 8 ]
}
revert() {
  local rc=0
  docker exec -u root "$PRIMARY" chmod 750 "$PGBR_WAL_DIR" || rc=1
  # a fresh backup resets the age that the fault left behind; it must succeed
  take_backup || rc=1
  resume_backups || rc=1
  return "$rc"
}
run_scenario archiver-failing
