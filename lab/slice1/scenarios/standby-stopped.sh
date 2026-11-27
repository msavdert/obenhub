#!/usr/bin/env bash
# Scenario standby-stopped: stop the standby container; expect PostgresTargetAbsent for pg-standby, held 180 s after detection so that PostgresSeriesVanished (which requires a live heartbeat) is seen not to fire. The hold also outlasts the standby's physical slot being inactive for 120 s plus 1 m, so PostgresPhysicalSlotInactive for pg-primary is expected as well: with the standby gone for over 5 minutes the unused slot is a correct alert, not a side effect.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD_AFTER_DETECT=180   # seconds; suppressed alerts must not fire in this time
EXPECT=("PostgresTargetAbsent:pg-standby" "PostgresPhysicalSlotInactive:pg-primary")
# The standby is down for about 7 minutes: its slow-tier heartbeat loses samples, so
# PostgresSlowCollectionIntervalTooLong trails the outage (packs/postgresql/rules.yml); it may fire and
# resolve while revert() waits for the slow tier to settle, and must not reach the next scenario.
ALLOW=("PostgresSlowCollectionIntervalTooLong:pg-standby")
inject() { dc stop pg-standby >/dev/null; }
revert() { dc start pg-standby >/dev/null && wait_until 180 "standby streaming again" is_streaming && wait_slow_tier_settled; }
run_scenario standby-stopped
