#!/usr/bin/env bash
# Scenario statements-evicted: run more distinct statements than pg_stat_statements.max (read from the server) in one psql session on the primary, so that entries are evicted and pg_stat_statements_info.dealloc rises; expect PostgresStatementsEvicted for pg-primary. A table alias is part of a statement's identity for pg_stat_statements (a column alias is not: three statements differing only in a column alias were one entry, tested on the lab primary 2026-11-24), so `SELECT 1 FROM generate_series(1,1) AS g<n>` for n = 1..max+500 are that many distinct entries with short text. inject() proves it: dealloc must have risen. after_detect checks that the per-database statement metrics and the wait-event series are in VictoriaMetrics and records how many series. revert() resets pg_stat_statements, which also resets dealloc, so the rule's last-minus-first window turns negative and the alert resolves.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresStatementsEvicted:pg-primary")
dealloc() { psql_p -c "SELECT dealloc FROM pg_stat_statements_info"; }
# series of a pack metric on the primary (instant query, count of series)
series_count() { vm_query "count(last_over_time({__name__=\"$1\", \"service.instance.id\"=\"pg-primary\"$2}[2m]))"; }
statement_series_seen() { [ "$(series_count postgresql.statement.call ', "postgresql.database.name"="postgres"')" -ge 1 ] \
  && [ "$(series_count postgresql.statement.execution_time ', "postgresql.database.name"="postgres"')" -ge 1 ] \
  && [ "$(series_count postgresql.statement.temp_block_written ', "postgresql.database.name"="postgres"')" -ge 1 ]; }
wait_series_seen() { [ "$(series_count postgresql.client_session.count '')" -ge 1 ]; }
inject() {
  local max before after n
  max=$(psql_p -c "SHOW pg_stat_statements.max") || return 1
  case "$max" in ''|*[!0-9]*) log "pg_stat_statements.max is not a number: $max"; return 1 ;; esac
  [ "$max" -le 50000 ] || { log "pg_stat_statements.max $max is too large for this scenario"; return 1; }
  before=$(dealloc) || return 1
  n=$((max + 500))
  log "pg_stat_statements.max is $max; running $n distinct statements (dealloc before: $before)"
  seq 1 "$n" | awk '{ printf "SELECT 1 FROM generate_series(1,1) AS g%d;\n", $1 }' \
    | docker exec -i "$PRIMARY" psql -U postgres -X -q -o /dev/null -d postgres || return 1
  after=$(dealloc) || return 1
  [ "$after" -gt "$before" ] || { log "dealloc did not rise ($before -> $after): the statements were not distinct"; return 1; }
  extra_set statements_run "$n"
  extra_set pg_stat_statements_max "$max"
  extra_set dealloc_after_inject "$after"
}
after_detect() {
  local st ws
  wait_until 90 "per-database statement series in VictoriaMetrics" statement_series_seen \
    || { FAILS+=("postgresql.statement.{call,execution_time,temp_block_written} have no series for database postgres"); return 1; }
  wait_until 90 "wait-event series in VictoriaMetrics" wait_series_seen \
    || { FAILS+=("postgresql.client_session.count has no series"); return 1; }
  st=$(vm_query 'count(last_over_time({__name__=~"postgresql[.]statement[.](call|execution_time|temp_block_written)", "service.instance.id"="pg-primary"}[2m]))')
  ws=$(series_count postgresql.client_session.count '')
  extra_set statement_series "${st:-0}"
  extra_set wait_event_series "${ws:-0}"
}
revert() {
  psql_p -c "SELECT pg_stat_statements_reset()" >/dev/null
}
run_scenario statements-evicted
