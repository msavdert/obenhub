#!/usr/bin/env bash
# Scenario checkpoint-pressure: lower max_wal_size on the primary and write with pgbench into a scratch database, so WAL reaches max_wal_size long before checkpoint_timeout; expect PostgresCheckpointsRequested for pg-primary. Revert resets max_wal_size, reloads and drops the scratch database. The periodic pgBackRest backups are paused for the run (each is a requested checkpoint). The load is rate limited to stay clear of the replication alerts on the standby and the subscriber.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresCheckpointsRequested:pg-primary")
DB=obenhub_ckpt
WAL_SIZE=${WAL_SIZE:-48MB}
RATE=${RATE:-400}       # pgbench transactions per second, all clients together
requested() { psql_p -c "SELECT num_requested FROM pg_stat_checkpointer"; }
inject() {
  local before
  # pgBackRest backups are requested checkpoints too; the run counts only the load's
  pause_backups || return 1
  psql_p -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null || return 1
  psql_p -c "CREATE DATABASE $DB" >/dev/null || return 1
  docker exec "$PRIMARY" pgbench -U postgres -i -s 5 -q "$DB" >/dev/null 2>&1 || return 1
  before=$(requested) || return 1
  psql_p -c "ALTER SYSTEM SET max_wal_size = '$WAL_SIZE'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  docker exec -d "$PRIMARY" timeout 1200 pgbench -U postgres -c 4 -j 2 -R "$RATE" -T 1200 "$DB" || return 1
  sleep 20   # a load duration, not a wait for a condition
  log "num_requested: $before -> $(requested) after 20 s of load"
}
after_detect() {
  EXTRA_JSON=$(jq -n -c --arg w "$WAL_SIZE" --argjson r "$RATE" --argjson n "$(requested)" '{max_wal_size: $w, pgbench_rate: $r, num_requested_at_detect: $n}')
}
revert() {
  docker exec "$PRIMARY" pkill -x pgbench 2>/dev/null
  psql_p -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  sleep 2
  psql_p -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null
  resume_backups
}
run_scenario checkpoint-pressure
