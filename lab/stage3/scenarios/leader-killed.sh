#!/usr/bin/env bash
# Scenario leader-killed: kill the leader container (SIGKILL); expect PatroniFailoverHappened and that a different node becomes leader without help. The old leader is started again at the end and rejoins as a replica.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PatroniFailoverHappened:")
OLD="" TL0="" T0=""
inject() {
  OLD=$(leader_name) && [ -n "$OLD" ] || return 1
  TL0=$(timeline)
  log "leader is $OLD on timeline $TL0"
  T0=$(date +%s)
  docker kill "$(cname "$OLD")" >/dev/null
}
new_leader() { local l; l=$(leader_name); [ -n "$l" ] && [ "$l" != "$OLD" ]; }
after_detect() {
  wait_until 120 "a new leader without help" new_leader || { FAILS+=("no new leader within 120s"); return 1; }
  local tl1; tl1=$(timeline)
  log "new leader $(leader_name) on timeline $tl1"
  EXTRA_JSON=$(jq -n -c --arg old "$OLD" --arg new "$(leader_name)" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" \
    --argjson gap "$(primary_gap_seconds "$T0")" '{old_leader: $old, new_leader: $new, timeline_before: $tl0, timeline_after: $tl1, seconds_without_primary: $gap}')
}
revert() {
  [ -n "$OLD" ] || return 0
  dc start "$OLD" >/dev/null || return 1
  wait_until 300 "cluster healthy with $OLD back" cluster_healthy
}
run_scenario leader-killed
