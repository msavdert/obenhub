#!/usr/bin/env bash
# Scenario autovacuum-off: set autovacuum off on the primary (ALTER SYSTEM and reload) and create a table of database app with the storage parameter autovacuum_enabled false; expect PostgresAutovacuumOff and PostgresAutovacuumTableDisabled for pg-primary. Timing, derived from the rules and the 5 minute slow tier (not yet measured): the first sample with the changed value arrives within 5 minutes; PostgresAutovacuumOff holds 5 minutes, so it fires 5 to 10 minutes after the injection, and PostgresAutovacuumTableDisabled holds 15 minutes, so it fires 15 to 20 minutes after it (plus one 1 minute evaluation); DETECT_TIMEOUT is 1500 s. After revert (setting reset, table dropped) the next sample reads the good value within 5 minutes and the alerts resolve with it (last_over_time over 10 minutes returns the latest sample): RESOLVE_TIMEOUT 900 s. No table is past its threshold (the app tables are empty and the scratch table holds ten rows), so PostgresAutovacuumBacklog must stay quiet; that is not asserted here. after_detect checks the two series behind the alerts in VictoriaMetrics.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresAutovacuumOff:pg-primary" "PostgresAutovacuumTableDisabled:pg-primary")
DETECT_TIMEOUT=1500
RESOLVE_TIMEOUT=900
TABLE=obenhub_av_disabled
setting_off() { [ "$(psql_p -c "SHOW autovacuum")" = off ]; }
inject() {
  psql_pa -c "DROP TABLE IF EXISTS $TABLE" -c "CREATE TABLE $TABLE (id int) WITH (autovacuum_enabled = false)" \
    -c "INSERT INTO $TABLE SELECT generate_series(1, 10)" >/dev/null || return 1
  psql_p -c "ALTER SYSTEM SET autovacuum = off" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  wait_until 30 "autovacuum is off on the primary" setting_off
}
after_detect() {
  local v
  v=$(vm_query 'max(last_over_time(postgresql.autovacuum.enabled{"service.instance.id"="pg-primary"}[10m]))')
  [ "$v" = 0 ] || FAILS+=("postgresql.autovacuum.enabled for pg-primary is '${v:-none}', not 0")
  v=$(vm_query 'max(last_over_time(postgresql.autovacuum.disabled_table.count{"service.instance.id"="pg-primary","postgresql.database.name"="app"}[10m]))')
  [ "${v:-0}" -ge 1 ] || FAILS+=("postgresql.autovacuum.disabled_table.count for database app is '${v:-none}', not at least 1")
}
revert() {
  local rc=0
  psql_p -c "ALTER SYSTEM RESET autovacuum" -c "SELECT pg_reload_conf()" >/dev/null || rc=1
  psql_pa -c "DROP TABLE IF EXISTS $TABLE" >/dev/null || rc=1
  return "$rc"
}
run_scenario autovacuum-off
