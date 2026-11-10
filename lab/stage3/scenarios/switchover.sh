#!/usr/bin/env bash
# Scenario switchover: planned switchover to a replica (patronictl switchover). Expect PatroniFailoverHappened and nothing else. The extra fields record what the signals show, to answer whether a planned switchover can be told from a failover (compare with leader-killed).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PatroniFailoverHappened:")
OLD="" NEW="" TL0="" T0=""
inject() {
  OLD=$(leader_name) && [ -n "$OLD" ] || return 1
  NEW=$(first_replica) && [ -n "$NEW" ] || return 1
  TL0=$(timeline)
  log "switchover $OLD -> $NEW on timeline $TL0"
  T0=$(date +%s)
  ptl switchover "$CLUSTER" --leader "$OLD" --candidate "$NEW" --force >/dev/null
}
after_detect() {
  wait_until 120 "cluster healthy after the switchover" cluster_healthy || { FAILS+=("cluster not healthy after the switchover"); return 1; }
  local tl1 gap minrun
  tl1=$(timeline)
  gap=$(primary_gap_seconds "$T0")
  minrun=$(vm_query "min_over_time(min(patroni_postgres_running)[$(($(date +%s) - T0 + 15))s:15s])")
  EXTRA_JSON=$(jq -n -c --arg old "$OLD" --arg new "$(leader_name)" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" \
    --argjson gap "${gap:-0}" --arg minrun "${minrun:-}" \
    '{old_leader: $old, new_leader: $new, timeline_before: $tl0, timeline_after: $tl1, seconds_without_primary: $gap, min_postgres_running: $minrun}')
}
# nothing to undo: roles move, the cluster is healthy
revert() { wait_until 120 "cluster healthy" cluster_healthy; }
run_scenario switchover
