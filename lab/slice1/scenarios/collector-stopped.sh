#!/usr/bin/env bash
# Scenario collector-stopped: stop the Collector; expect CollectorAbsent only, held 300 s after detection so that PostgresTargetAbsent and SeriesVanished (which require a live Collector) are seen not to fire.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD_AFTER_DETECT=300   # seconds; suppressed alerts must not fire in this time
EXPECT=("CollectorAbsent:otelcol-slice1")
inject() { dc stop otelcol >/dev/null; }
revert() { dc start otelcol >/dev/null; }
run_scenario collector-stopped
