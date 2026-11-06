#!/usr/bin/env bash
# Scenario control: no fault, pgbench load; pass = no alert but Watchdog and no ERROR/FATAL from otel_monitor in the server log.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
SECONDS_LOAD=${CONTROL_SECONDS:-600}
inject() {
  psql_p -c "DROP DATABASE IF EXISTS slice1_bench" -c "CREATE DATABASE slice1_bench" >/dev/null || return 1
  docker exec "$PRIMARY" pgbench -U postgres -i -s 10 -q slice1_bench >/dev/null 2>&1 || return 1
  log "pgbench for ${SECONDS_LOAD}s"
  docker exec "$PRIMARY" pgbench -U postgres -c 8 -j 2 -T "$SECONDS_LOAD" -P 60 slice1_bench >&2
}
revert() { psql_p -c "DROP DATABASE IF EXISTS slice1_bench WITH (FORCE)" >/dev/null; }
extra_checks() {
  local out n
  if ! out=$(vl "_time:>$T_START _time:<=$T_END service.name:=postgresql user:=otel_monitor error_severity:in(ERROR,FATAL,PANIC) | stats count() n"); then
    FAILS+=("ERROR/FATAL count: VictoriaLogs query failed")
    return 0
  fi
  n=$(printf '%s\n' "$out" | jq -r '.n') || n=""
  case "$n" in
    ''|*[!0-9]*) FAILS+=("ERROR/FATAL count: unparsable VictoriaLogs answer"); return 0 ;;
  esac
  log "monitoring-role ERROR/FATAL records in the window: $n"
  EXTRA_JSON=$(jq -n -c --argjson n "$n" '{monitor_role_errors: $n}')
  [ "$n" = 0 ] || FAILS+=("$n ERROR/FATAL records from otel_monitor in the server log")
}
run_scenario control
