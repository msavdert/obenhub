#!/usr/bin/env bash
# Scenario control: no fault on the CDB19 pair for CONTROL_SECONDS (default 600); pass = no alert but Watchdog, so no Data Guard pack rule fires on a healthy pair. This is the control run for the other Oracle scenarios and uses the same rules.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
SECONDS_QUIET=${CONTROL_SECONDS:-600}
inject() {
  log "no fault; waiting ${SECONDS_QUIET}s"
  sleep "$SECONDS_QUIET"
}
revert() { :; }
run_scenario control
