#!/usr/bin/env bash
# Scenario autovacuum-backlog: stop autovacuum from reaching a table (autovacuum_naptime 1 day on the primary, ALTER SYSTEM and reload) and leave a table of database app with dead tuples past its threshold (10000 rows inserted, 5000 deleted; the default threshold is 50 plus 20% of reltuples, which is -1 for a table never vacuumed and read as 0); expect PostgresAutovacuumBacklog for pg-primary. Timing, derived from the rule and the 5 minute slow tier (not yet measured): the receiver reads the database every 5 minutes, so the first positive sample arrives within 5 minutes of the injection, and the rule holds 15 minutes, so detection takes 15 to 20 minutes plus one evaluation (1 minute): DETECT_TIMEOUT is 1500 s. Resolution: after revert (setting reset, table dropped) the next sample reads 0 within 5 minutes and last_over_time over 10 minutes returns that latest sample, so the alert resolves within about 6 minutes: RESOLVE_TIMEOUT 900 s. inject() proves the table is past its threshold with pg_stat_user_tables; after_detect checks that the per-database series carries database app and that the standby, in recovery, reports only the slow heartbeat. The table is created and dropped on the primary only (the publication names customers and orders, so logical replication is not touched).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresAutovacuumBacklog:pg-primary")
DETECT_TIMEOUT=1500
RESOLVE_TIMEOUT=900
TABLE=obenhub_av_backlog
dead_tuples() { psql_pa -c "SELECT coalesce(max(n_dead_tup), 0) FROM pg_stat_user_tables WHERE relname = '$TABLE'"; }
dead_past() { local d; d=$(dead_tuples) && [ "${d:-0}" -ge 5000 ]; }
series() { vm_query "max(last_over_time(postgresql.autovacuum.pending_table.count{\"service.instance.id\"=\"pg-primary\",\"postgresql.database.name\"=\"app\"}[10m]))"; }
inject() {
  psql_p -c "ALTER SYSTEM SET autovacuum_naptime = '1d'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  # a launcher that already woke has re-read the setting once the reload was handled
  sleep 3
  psql_pa -c "DROP TABLE IF EXISTS $TABLE" -c "CREATE TABLE $TABLE (id int)" \
    -c "INSERT INTO $TABLE SELECT generate_series(1, 10000)" -c "DELETE FROM $TABLE WHERE id <= 5000" >/dev/null || return 1
  wait_until 60 "dead tuples of $TABLE in pg_stat_user_tables" dead_past || return 1
  extra_set dead_tuples_after_inject "$(dead_tuples)"
}
after_detect() {
  local v hb
  v=$(series)
  [ "${v:-0}" -ge 1 ] || { FAILS+=("postgresql.autovacuum.pending_table.count for database app on pg-primary is '${v:-none}', not at least 1"); return 1; }
  extra_set pending_tables "$v"
  hb=$(vm_query 'count(last_over_time(postgresql.collection.slow_heartbeat{"service.instance.id"="pg-standby"}[10m]))')
  [ "${hb:-0}" -ge 1 ] || FAILS+=("the standby reports no postgresql.collection.slow_heartbeat")
  [ -z "$(vm_query 'count(last_over_time(postgresql.autovacuum.pending_table.count{"service.instance.id"="pg-standby"}[10m]))')" ] \
    || FAILS+=("the standby reports postgresql.autovacuum.pending_table.count although it is in recovery")
}
revert() {
  local rc=0
  psql_p -c "ALTER SYSTEM RESET autovacuum_naptime" -c "SELECT pg_reload_conf()" >/dev/null || rc=1
  psql_pa -c "DROP TABLE IF EXISTS $TABLE" >/dev/null || rc=1
  return "$rc"
}
run_scenario autovacuum-backlog
