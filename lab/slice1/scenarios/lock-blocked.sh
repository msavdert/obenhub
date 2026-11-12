#!/usr/bin/env bash
# Scenario lock-blocked: one session takes ACCESS EXCLUSIVE on a scratch table in database postgres and stays idle in its transaction; a second session waits for the table. Expect PostgresBlockedSessions for pg-primary, and two more alerts that any realistic blocker brings with it. PostgresIdleInTransaction for pg-primary: the blocker is by nature a session idle in a transaction (warning after 60 s idle). PostgresSnapshotHeldTooLong for pg-primary: a plain SELECT gets its snapshot before parse analysis, which is where the table lock is requested, so the waiter holds backend_xmin while it waits and snapshot.oldest_age rises past 120 s (observed in VictoriaMetrics during the development runs of 2026-11-08; the run record of a rerun will show it). run_scenario waits for every EXPECT entry before it reverts, so the run is deterministic, not a race against the thresholds.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresBlockedSessions:pg-primary" "PostgresIdleInTransaction:pg-primary" "PostgresSnapshotHeldTooLong:pg-primary")
BLOCKER=slice1-lock-blocker
WAITER=slice1-lock-waiter
# polls instead of fixed sleeps: wait_until (lib-core.sh) retries every 5 s up to a deadline
lock_count() { # granted|waiting
  local g=true; [ "$1" = waiting ] && g=false
  psql_p -c "SELECT count(*) FROM pg_locks WHERE locktype = 'relation' AND relation = 'obenhub_lock_scratch'::regclass AND granted = $g"
}
blocker_holds() { [ "$(lock_count granted)" -ge 1 ]; }
# exactly one waiter on the scratch table: a session of the lab (or autovacuum) waiting on another table does not count
waiter_waits() { [ "$(lock_count waiting)" = 1 ]; }
scratch_dropped() { psql_p -c "SET lock_timeout = '3s'; DROP TABLE IF EXISTS obenhub_lock_scratch" >/dev/null; }
inject() {
  psql_p -c "DROP TABLE IF EXISTS obenhub_lock_scratch; CREATE TABLE obenhub_lock_scratch AS SELECT 1 AS id" >/dev/null || return 1
  docker exec -d -e PGAPPNAME="$BLOCKER" "$PRIMARY" sh -c \
    "{ echo 'BEGIN; LOCK TABLE obenhub_lock_scratch IN ACCESS EXCLUSIVE MODE;'; sleep 1204; } | psql -U postgres -X -q -o /dev/null" || return 1
  wait_until 30 "the blocker holds the lock" blocker_holds || return 1
  docker exec -d -e PGAPPNAME="$WAITER" "$PRIMARY" timeout 1200 psql -U postgres -X -q -o /dev/null \
    -c "SELECT count(*) FROM obenhub_lock_scratch" || return 1
  wait_until 30 "one session waits for the scratch table" waiter_waits
}
revert() {
  psql_p -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name IN ('$BLOCKER', '$WAITER')" >/dev/null
  docker exec "$PRIMARY" pkill -f 'sleep 1204' 2>/dev/null
  wait_until 30 "scratch table dropped" scratch_dropped
}
run_scenario lock-blocked
