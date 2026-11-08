#!/usr/bin/env bash
# Scenario quorum-lost: stop two of three etcd members (etcd-2 and etcd-3); the Patroni leader cannot refresh its key and demotes itself. Expect PatroniNoWritablePrimary plus the etcd view: EtcdInsufficientMembers, EtcdNoLeader on the survivor etcd-1, and EtcdMemberAbsent for each stopped member (decision: member-down is not suppressed by the quorum alert, it names the members to restart). After detection every node is read-only.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PatroniNoWritablePrimary:" "EtcdInsufficientMembers:" "EtcdNoLeader:etcd-1" "EtcdMemberAbsent:etcd-2" "EtcdMemberAbsent:etcd-3")
# When quorum returns, the demoted leader (or another node) is promoted again
# on a new timeline, so PatroniFailoverHappened follows after the revert. That
# is a real timeline change, not noise; it is allowed and checked in extra_checks.
# EtcdHighLeaderChanges: replayed on the 2026-11-08 suite-5 run, etcd-1 reached 3 changes in 5 m (max(increase(...[5m])) = 3 for 75 s); the elections during quorum loss and recovery are real.
ALLOW=("PatroniFailoverHappened:" "EtcdHighLeaderChanges:")
STOPPED=0 TL0=""
all_in_recovery() {
  local n
  for n in "${NODES[@]}"; do
    [ "$(psql_n "$n" -c 'SELECT pg_is_in_recovery()')" = t ] || return 1
  done
}
inject() {
  TL0=$(timeline)
  STOPPED=1
  dc stop etcd-2 etcd-3 >/dev/null
}
after_detect() {
  all_in_recovery || { FAILS+=("a node is still writable while the DCS has no quorum"); return 1; }
  log "every node is in recovery (read-only)"
}
revert() {
  [ "$STOPPED" = 1 ] || return 0
  dc start etcd-2 etcd-3 >/dev/null || return 1
  wait_until 120 "etcd healthy again" etcd_healthy || return 1
  wait_until 300 "cluster healthy again" cluster_healthy
}
extra_checks() {
  local f tl1
  f=$(first_record firing PatroniFailoverHappened "" "$T_INJECT" || true)
  tl1=$(timeline)
  log "timeline before: ${TL0:-?}, after: ${tl1:-?}; PatroniFailoverHappened firing at: ${f:-never}"
  EXTRA_JSON=$(jq -n -c --arg f "$f" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" '{followed_by_failover_alert_at: ($f|if . == "" then null else . end), timeline_before: $tl0, timeline_after: $tl1}')
  [ -n "$f" ] && [ "${tl1:-0}" -gt "${TL0:-0}" ] || FAILS+=("expected a timeline change after the quorum returned")
}
run_scenario quorum-lost
