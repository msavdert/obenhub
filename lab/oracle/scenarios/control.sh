#!/usr/bin/env bash
# Scenario control: no fault on the CDB19 pair for CONTROL_SECONDS (default 600); pass = no alert but Watchdog, so no Data Guard pack rule fires on a healthy pair; a synthetic alert is delivered as firing and resolved (the Alertmanager sink is alive) and the Oracle alert log has records in the window (the Collector ships it, service.name oracledb; lab/oracle/files/otelcol-db.yaml). A healthy pair can stay silent in its alert log for ten minutes (80 of 144 ten-minute buckets of 2026-11-18/19 had no record), so control makes one entry itself: one log switch on the primary (log_switch, ALTER SYSTEM ARCHIVE LOG CURRENT, which the alert log records) at the start. This is the control run for the other Oracle scenarios and uses the same rules.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
ALLOW=(ObenhubSinkProbe:)
SECONDS_QUIET=${CONTROL_SECONDS:-600}
inject() {
  sink_probe_start
  log_switch || { FAILS+=("the log switch for the alert-log check failed"); return 1; }
  log "no fault; waiting ${SECONDS_QUIET}s"
  sleep "$SECONDS_QUIET"
}
revert() { :; }
extra_checks() {
  sink_probe_check
  pg_log_records_check oracledb
}
run_scenario control
