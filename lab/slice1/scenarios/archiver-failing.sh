#!/usr/bin/env bash
# Scenario archiver-failing: make the primary's archive directory unreadable and unwritable (chmod 000 /archive, so the archive_command cp fails) and switch WAL segments until more than 8 wait for the archiver; expect PostgresArchivingFailing (pg_stat_archiver: last failure newer than last success) and PostgresArchiveBacklog (.ready files in pg_wal/archive_status) for pg-primary. The revert restores the mode; the archiver retries about once a minute and drains the backlog, which resolves both alerts.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresArchivingFailing:pg-primary" "PostgresArchiveBacklog:pg-primary")
FAILING_SQL="SELECT (last_failed_time > coalesce(last_archived_time, '-infinity'))::int FROM pg_stat_archiver"
inject() {
  local i
  docker exec -u root "$PRIMARY" chmod 000 /archive || return 1
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
revert() { docker exec -u root "$PRIMARY" chmod 755 /archive; }
run_scenario archiver-failing
