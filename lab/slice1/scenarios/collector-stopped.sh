#!/usr/bin/env bash
# Scenario collector-stopped: stop the Collector; expect CollectorAbsent only, held 300 s after detection so that PostgresTargetAbsent and PostgresSeriesVanished (which require a live Collector) are seen not to fire.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD_AFTER_DETECT=300   # seconds; suppressed alerts must not fire in this time
EXPECT=("CollectorAbsent:otelcol-slice1")
# The 5 m slow tier of every database loses samples while the Collector is down (about 9 minutes here), so
# PostgresSlowCollectionIntervalTooLong trails the outage (packs/postgresql/rules.yml): it may fire and
# resolve while revert() waits for the slow tier to settle, and must not reach the next scenario.
ALLOW=("PostgresSlowCollectionIntervalTooLong:pg-primary" "PostgresSlowCollectionIntervalTooLong:pg-standby" "PostgresSlowCollectionIntervalTooLong:pg-subscriber")
inject() { dc stop otelcol >/dev/null; }
revert() { dc start otelcol >/dev/null && wait_slow_tier_settled; }
run_scenario collector-stopped
