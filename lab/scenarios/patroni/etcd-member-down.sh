#!/usr/bin/env bash
# Scenario etcd-member-down: stop one etcd member that is not the leader (quorum stays); expect EtcdMemberAbsent for it and nothing else. Patroni keeps its DCS session on the other two members, and PostgreSQL and Patroni on that node keep running. etcd_stop and etcd_start are adapter functions (stage 3: the etcd container; pgha: systemctl on the node).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
VICTIM=""
inject() {
  local l m
  l=$(etcd_leader)
  for m in "${ETCD_MEMBERS[@]}"; do [ "$m" != "$l" ] && VICTIM=$m && break; done
  [ -n "$VICTIM" ] || return 1
  log "etcd leader is $l; stopping etcd on $VICTIM"
  EXPECT=("EtcdMemberAbsent:$VICTIM")
  etcd_stop "$VICTIM"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  etcd_start "$VICTIM" || return 1
  wait_until 120 "etcd healthy again" etcd_healthy && wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario etcd-member-down
