#!/usr/bin/env bash
# Scenario standby-stopped: stop the standby container; expect PostgresTargetAbsent for pg-standby only, held 180 s after detection so that SeriesVanished (which requires a live heartbeat) is seen not to fire.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD_AFTER_DETECT=180   # seconds; suppressed alerts must not fire in this time
EXPECT=("PostgresTargetAbsent:pg-standby")
inject() { dc stop pg-standby >/dev/null; }
revert() { dc start pg-standby >/dev/null && wait_until 180 "standby streaming again" is_streaming; }
run_scenario standby-stopped
