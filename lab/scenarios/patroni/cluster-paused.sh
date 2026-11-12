#!/usr/bin/env bash
# Scenario cluster-paused: maintenance mode on (patronictl pause); expect PatroniClusterPaused after the 3 m window.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PatroniClusterPaused:")
inject() { ptl pause --wait >/dev/null; }
revert() { ptl resume --wait >/dev/null; wait_until 120 "cluster healthy" cluster_healthy; }
run_scenario cluster-paused
