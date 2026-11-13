#!/usr/bin/env bash
# Scenario etcd-leader-changes: move the etcd leader four times, 15 s apart, with etcdctl move-leader; expect EtcdHighLeaderChanges (3 or more changes within 5 m). Nothing is stopped, so there is nothing to revert; the alert resolves when the 5 m window passes the last move.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("EtcdHighLeaderChanges:")
MOVES=${MOVES:-4}
leader_is() { [ "$(etcd_leader)" = "$1" ]; }
inject() {
  local i l t m
  for i in $(seq 1 "$MOVES"); do
    l=$(etcd_leader)
    t=""
    for m in "${ETCD_MEMBERS[@]}"; do [ "$m" != "$l" ] && t=$m && break; done
    [ -n "$l" ] && [ -n "$t" ] || return 1
    etcd_move_leader "$t" || return 1
    wait_until 30 "etcd leader is $t" leader_is "$t" || return 1
    log "move $i: leader $l -> $t"
    sleep 15
  done
}
revert() { wait_until 120 "etcd healthy" etcd_healthy && wait_until 120 "cluster healthy" cluster_healthy; }
run_scenario etcd-leader-changes
