#!/usr/bin/env bash
# Scenario control: no fault, the load client keeps running; pass = no alert but Watchdog and no ERROR/FATAL from otel_monitor in the server logs of any node.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
SECONDS_LOAD=${CONTROL_SECONDS:-600}
inject() {
  log "no fault; load runs for ${SECONDS_LOAD}s"
  sleep "$SECONDS_LOAD"
}
revert() { :; }
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
