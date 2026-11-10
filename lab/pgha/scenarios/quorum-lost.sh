#!/usr/bin/env bash
# Scenario quorum-lost: stop etcd on two of three nodes (pgha-2 and pgha-3, systemctl stop etcd); the Patroni leader cannot refresh its key and demotes itself (failsafe_mode is off, lab/pgha/files/patroni.yml.tmpl). Expect PatroniNoWritablePrimary plus the etcd view: EtcdInsufficientMembers, EtcdNoLeader on the survivor pgha-1, and EtcdMemberAbsent for each stopped member (decision as in stage 3: member-down is not suppressed by the quorum alert, it names the members to restart). After detection every node is read-only. Patroni itself keeps running on every node, but the leader's hardware watchdog stays armed until the demotion reaches its safepoint (Patroni ha.py demote(), on_safepoint=watchdog.disable): with ttl 30 and safety_margin 5 a PostgreSQL shutdown that takes longer than the remaining margin resets the VM. No reset in the first suite run (2026-11-10).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PatroniNoWritablePrimary:" "EtcdInsufficientMembers:" "EtcdNoLeader:pgha-1" "EtcdMemberAbsent:pgha-2" "EtcdMemberAbsent:pgha-3")
# As in stage 3: when quorum returns a node is promoted on a new timeline, so
# PatroniFailoverHappened follows after the revert; it is a real timeline
# change, allowed and checked in extra_checks. EtcdHighLeaderChanges: the
# elections during quorum loss and recovery are real (stage 3 run of
# 2026-11-08: 3 changes in 5 m).
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
  rn pgha-2 systemctl stop etcd && rn pgha-3 systemctl stop etcd
}
after_detect() {
  all_in_recovery || { FAILS+=("a node is still writable while the DCS has no quorum"); return 1; }
  log "every node is in recovery (read-only)"
}
revert() {
  [ "$STOPPED" = 1 ] || return 0
  local rc=0
  rn pgha-2 systemctl start --no-block etcd || rc=1
  rn pgha-3 systemctl start --no-block etcd || rc=1
  [ "$rc" = 0 ] || return 1
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
