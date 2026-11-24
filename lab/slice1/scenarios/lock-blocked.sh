#!/usr/bin/env bash
# Scenario lock-blocked: one session takes ACCESS EXCLUSIVE on a scratch table in database postgres and stays idle in its transaction; a second session waits for the table. Expect PostgresBlockedSessions for pg-primary, and two more alerts that any realistic blocker brings with it. PostgresIdleInTransaction for pg-primary: the blocker is by nature a session idle in a transaction (warning after 60 s idle). PostgresSnapshotHeldTooLong for pg-primary: a plain SELECT gets its snapshot before parse analysis, which is where the table lock is requested, so the waiter holds backend_xmin while it waits and snapshot.oldest_age rises past 120 s (observed in VictoriaMetrics during the development runs of 2026-11-08; the run record of a rerun will show it). run_scenario waits for every EXPECT entry before it reverts, so the run is deterministic, not a race against the thresholds. The wait-event series with wait event type Lock must be above 0 during the block (after_detect, recorded as lock_wait_sessions).
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
# the wait-event metric shows the lock wait: sessions with wait event type Lock on the primary
lock_wait_series_seen() {
  local v; v=$(vm_query 'sum(last_over_time({__name__="postgresql.client_session.count", "service.instance.id"="pg-primary", "postgresql.wait_event.type"="Lock"}[1m]))')
  [ -n "$v" ] && awk -v v="$v" 'BEGIN { exit !(v > 0) }'
}
after_detect() {
  wait_until 90 "sessions with wait event type Lock in postgresql.client_session.count" lock_wait_series_seen \
    || { FAILS+=("postgresql.client_session.count shows no session with wait event type Lock during the block"); return 1; }
  extra_set lock_wait_sessions "$(vm_query 'sum(last_over_time({__name__="postgresql.client_session.count", "service.instance.id"="pg-primary", "postgresql.wait_event.type"="Lock"}[1m]))')"
}
revert() {
  psql_p -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name IN ('$BLOCKER', '$WAITER')" >/dev/null
  docker exec "$PRIMARY" pkill -f 'sleep 1204' 2>/dev/null
  wait_until 30 "scratch table dropped" scratch_dropped
}
run_scenario lock-blocked
