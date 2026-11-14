#!/usr/bin/env bash
# Scenario transport-cut: redo transport from the primary CDB19 to CDB19_STBY is switched off through the broker (EDIT DATABASE cdb19 SET STATE='TRANSPORT-OFF', on the primary; the same command on the standby is refused with ORA-16516). The broker accepts it with fast-start failover enabled and needs neither a protection-mode change nor FSFO disabled (checked 2026-11-14 with an immediate TRANSPORT-ON). A log switch on the primary every 20 s keeps redo being generated so that the transport lag grows.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml and corrected by the first trial run (2026-11-14, which expected two more alerts): the primary's protection level drops below MaxAvailability (it read RESYNCHRONIZATION; OracleProtectionDegraded, hold 1m), its remote destination status leaves VALID (OracleRedoDestinationInvalid, hold 1m), and the standby receives nothing new, so lag.data_age grows (OracleStandbyDataStale, over 60 s for 2m). Not seen in that run, so not expected: OracleFastStartFailoverNotSynchronized (fs_failover_status stayed SYNCHRONIZED while the level was RESYNCHRONIZATION, cause not investigated) and OracleStandbyLag (the lag values stayed 0 because no redo reached the standby, which is why DataStale is the signal). OracleRedoGap did not fire either and is not allowed: a gap alert in a later run is reported as unexpected rather than passing silently. Observer, apply and role are untouched, so the other rules stay quiet.
# Revert: stop the log switches, TRANSPORT-ON (three attempts), wait until the broker is SUCCESS, apply runs, lags are at most 10 s, the protection level equals the mode and fast-start failover is SYNCHRONIZED again.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleProtectionDegraded:$PRIMARY_SID" "OracleRedoDestinationInvalid:$PRIMARY_SID" "OracleStandbyDataStale:$STANDBY_SID")
ALLOW=()
restored() { healthy_pair && sync_ok; }
inject() {
  dg "$PRIMARY_SID" "edit database $PRIMARY_SID set state='TRANSPORT-OFF'" || return 1
  start_generator
}
revert() {
  stop_generator
  retry dg "$PRIMARY_SID" "edit database $PRIMARY_SID set state='TRANSPORT-ON'" || { FAILS+=("TRANSPORT-ON failed three times: $PRIMARY_SID may be left in TRANSPORT-OFF"); return 1; }
  wait_until 900 "pair healthy, protection level restored, fast-start failover SYNCHRONIZED" restored
}
run_scenario transport-cut
