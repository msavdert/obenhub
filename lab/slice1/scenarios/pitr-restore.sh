#!/usr/bin/env bash
# Scenario pitr-restore: point-in-time recovery from the pgBackRest repository. Write marker rows (phase before), note the time, write more rows (phase after), switch the WAL segment and wait until it is archived; then restore the stanza with `pgbackrest restore --type=time --target=<noted time>` into a throwaway container and volume (never the primary's data volume), start it with no network, and assert that every `before` row exists and no `after` row does. The counts go into the result row (extra). No alert is expected; any alert in the window is unexpected, as in control.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
ROWS=20
RESTORE_VOL=${PROJECT}_pitr-restore

# Runs as root in the throwaway container: restore, start PostgreSQL on a
# socket only, wait for recovery to end, print "before=N after=M". $1 is the target.
RESTORE_SCRIPT=$(cat <<'EOS'
set -eu
install -d -m 700 -o postgres -g postgres /restore/data
gosu postgres pgbackrest --stanza=slice1 --pg1-path=/restore/data --type=time "--target=$1" --target-action=promote restore >&2
gosu postgres pg_ctl -D /restore/data -l /tmp/pg.log -w -t 120 \
  -o "-c listen_addresses= -c archive_mode=off -c unix_socket_directories=/tmp" start >&2 || { cat /tmp/pg.log >&2; exit 1; }
q() { gosu postgres psql -h /tmp -U postgres -X -At "$@"; }
n=0
until [ "$(q -c "SELECT pg_is_in_recovery()")" = f ]; do
  n=$((n + 1)); [ "$n" -lt 60 ] || { echo "recovery did not end" >&2; cat /tmp/pg.log >&2; exit 1; }
  sleep 1
done
echo "before=$(q -c "SELECT count(*) FROM pitr_marker WHERE phase = 'before'") after=$(q -c "SELECT count(*) FROM pitr_marker WHERE phase = 'after'")"
gosu postgres pg_ctl -D /restore/data -m fast stop >&2
EOS
)

archived_past() { # LSN: the WAL segment that ends at LSN is archived
  [ "$(psql_p -c "SELECT (last_archived_wal >= pg_walfile_name('$1'::pg_lsn - 1))::int FROM pg_stat_archiver")" = 1 ]
}

inject() {
  local target lsn out before after
  # a volume left by a killed run would make the restore fail with "[040] ... contains files"
  docker volume rm "$RESTORE_VOL" >/dev/null 2>&1 || true
  psql_p -c "DROP TABLE IF EXISTS pitr_marker" -c "CREATE TABLE pitr_marker (id serial PRIMARY KEY, phase text NOT NULL, at timestamptz NOT NULL DEFAULT clock_timestamp())" >/dev/null || return 1
  psql_p -c "INSERT INTO pitr_marker (phase) SELECT 'before' FROM generate_series(1, $ROWS)" >/dev/null || return 1
  sleep 3
  target=$(psql_p -c "SELECT clock_timestamp()") || return 1
  sleep 3
  psql_p -c "INSERT INTO pitr_marker (phase) SELECT 'after' FROM generate_series(1, $ROWS)" >/dev/null || return 1
  # the segment holding both phases must be in the repository before the restore
  lsn=$(psql_p -c "SELECT pg_switch_wal()") || return 1
  wait_until 120 "WAL up to $lsn archived" archived_past "$lsn" || return 1
  log "restore target $target"
  docker volume create "$RESTORE_VOL" >/dev/null || return 1
  out=$(docker run --rm --network none -v "$RESTORE_VOL:/restore" -v "$REPO_VOL:/var/lib/pgbackrest:ro" \
    --entrypoint sh "$PG_IMAGE" -c "$RESTORE_SCRIPT" sh "$target") || { FAILS+=("restore container failed"); return 1; }
  log "restored: $out"
  before=${out#before=}; before=${before%% *}
  after=${out##*after=}
  EXTRA_JSON=$(jq -n -c --arg target "$target" --argjson rows "$ROWS" --argjson before "${before:-null}" --argjson after "${after:-null}" \
    '{restore_target: $target, rows_per_phase: $rows, restored_before: $before, restored_after: $after}') || return 1
  [ "$before" = "$ROWS" ] || { FAILS+=("restored $before rows written before the target, expected $ROWS"); return 1; }
  [ "$after" = 0 ] || { FAILS+=("restored $after rows written after the target, expected 0"); return 1; }
}
revert() {
  psql_p -c "DROP TABLE IF EXISTS pitr_marker" >/dev/null
  docker volume rm "$RESTORE_VOL" >/dev/null 2>&1 || true
}
run_scenario pitr-restore
