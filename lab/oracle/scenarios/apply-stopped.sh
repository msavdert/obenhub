#!/usr/bin/env bash
# Scenario apply-stopped: redo apply on the standby CDB19_STBY is stopped through the broker (EDIT DATABASE ... SET STATE='APPLY-OFF'); transport stays on, so the primary keeps shipping redo and nothing blocks. A log switch on the primary every 20 s (ALTER SYSTEM ARCHIVE LOG CURRENT; no schema object is created) keeps redo flowing so that the apply lag grows; without redo the lag would not.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml: the managed recovery process is gone, so OracleStandbyApplyStopped (apply.running 0, hold 3m) fires for CDB19_STBY; the apply lag then grows by about one second per second, so OracleStandbyLag (lag > 60 for 2m) fires about 3 minutes after the injection. Transport lag stays 0, so OracleRedoGap, OracleRedoDestinationInvalid and OracleProtectionDegraded stay quiet, and with zero-data-loss fast-start failover the observer and synchronization state do not depend on apply (assumption, to be confirmed by this run).
# Revert: stop the log switches, APPLY-ON (three attempts), wait until apply runs and both lags are back to at most 10 s.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleStandbyApplyStopped:$STANDBY_SID" "OracleStandbyLag:$STANDBY_SID")
ALLOW=()
no_apply() { local n; n=$(apply_count) && [ -n "$n" ] && [ "$n" -eq 0 ] 2>/dev/null; }
inject() {
  dg "$PRIMARY_SID" "edit database $STANDBY_SID set state='APPLY-OFF'" || return 1
  wait_until 60 "managed recovery gone on $STANDBY_SID" no_apply || { FAILS+=("managed recovery not confirmed gone 60 s after APPLY-OFF (still present or the query failed)"); return 1; }
  start_generator
}
revert() {
  stop_generator
  retry dg "$PRIMARY_SID" "edit database $STANDBY_SID set state='APPLY-ON'" || { FAILS+=("APPLY-ON failed three times: $STANDBY_SID may be left in APPLY-OFF"); return 1; }
  wait_until 600 "apply running and lag back to at most 10 s" healthy_pair
}
run_scenario apply-stopped
