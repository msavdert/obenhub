#!/usr/bin/env bash
# Scenario observer-stopped: the fast-start failover observer of the CDB19 configuration is stopped (systemctl stop dg-observer@cdb19 on ora-dg-obs, which runs /home/oracle/scripts/observer.sh stop cdb19: dgmgrl "stop observer", then a kill of any leftover process). The CDB19B observer, started by its own unit, is not touched. The databases keep running and nothing fails over: without an observer the broker only loses its ability to fail over automatically.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml: fs_failover_observer_present turns NO on the primary, so OracleFastStartFailoverObserverMissing (observer_present 0 with fast-start failover enabled, on the primary, hold 2m) fires for CDB19. Whether the status also leaves SYNCHRONIZED (OracleFastStartFailoverNotSynchronized) is not known; an unexpected alert fails the run and is named in its record.
# Revert: systemctl start dg-observer@cdb19 (observer.sh start, which waits 10 s after dgmgrl "start observer in background"), then wait until the broker shows the observer again, the configuration is SUCCESS and lag is small.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleFastStartFailoverObserverMissing:$PRIMARY_SID")
ALLOW=()
inject() {
  rn "$OBSERVER_HOST" systemctl stop "$OBSERVER_UNIT" || return 1
  local rc=0
  rn "$OBSERVER_HOST" pgrep -u oracle -f /u01/app/oracle/dg/cdb19/fsfo.dat >/dev/null || rc=$?
  # pgrep: 1 = no such process; 0 = still running; anything else (ssh 255,
  # timeout 124) proves nothing
  case $rc in
    1) ;;
    0) FAILS+=("observer process still running after stop"); return 1 ;;
    *) FAILS+=("could not check the observer process after stop (status $rc)"); return 1 ;;
  esac
}
revert() {
  retry rn "$OBSERVER_HOST" systemctl start "$OBSERVER_UNIT" || { FAILS+=("starting $OBSERVER_UNIT failed three times: the observer may be left stopped"); return 1; }
  wait_until 300 "observer back in the broker and the pair healthy" healthy_pair
}
run_scenario observer-stopped
