#!/usr/bin/env bash
# Scenario deadlock: two sessions update two rows of a scratch table in database app in opposite order; PostgreSQL aborts one after deadlock_timeout. Expect PostgresDeadlocks for pg-primary (the Collector reads postgresql.deadlocks only for the databases it is configured with, which includes app). The alert covers a 5 minute window, so it resolves about 5 minutes after the deadlock.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresDeadlocks:pg-primary")
deadlock_counted() { [ "$(psql_pa -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'app'")" -gt "$before" ]; }
inject() {
  local before after
  psql_pa -c "DROP TABLE IF EXISTS obenhub_deadlock_scratch; CREATE TABLE obenhub_deadlock_scratch AS SELECT g AS id, 0 AS v FROM generate_series(1, 2) g" >/dev/null || return 1
  before=$(psql_pa -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'app'") || return 1
  docker exec "$PRIMARY" sh -c '
    psql -U postgres -d app -X -q -c "BEGIN; UPDATE obenhub_deadlock_scratch SET v = 1 WHERE id = 1; SELECT pg_sleep(2); UPDATE obenhub_deadlock_scratch SET v = 1 WHERE id = 2; COMMIT" >/dev/null 2>&1 &
    psql -U postgres -d app -X -q -c "BEGIN; UPDATE obenhub_deadlock_scratch SET v = 2 WHERE id = 2; SELECT pg_sleep(2); UPDATE obenhub_deadlock_scratch SET v = 2 WHERE id = 1; COMMIT" >/dev/null 2>&1 &
    wait'
  # the counter is flushed by the backends asynchronously: poll for it
  wait_until 30 "pg_stat_database.deadlocks rises" deadlock_counted
  after=$(psql_pa -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'app'") || return 1
  log "pg_stat_database.deadlocks for app: $before -> $after"
  [ "$after" -gt "$before" ]
}
revert() { psql_pa -c "DROP TABLE IF EXISTS obenhub_deadlock_scratch" >/dev/null; }
run_scenario deadlock
