#!/usr/bin/env bash
# Scenario etcd-member-down: stop etcd (systemctl stop etcd) on one node that is not the etcd leader (quorum stays); expect EtcdMemberAbsent for it and nothing else. Patroni keeps its DCS session on the other two members, and PostgreSQL and Patroni on that node keep running.
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
  rn "$VICTIM" systemctl stop etcd
}
revert() {
  [ -n "$VICTIM" ] || return 0
  rn "$VICTIM" systemctl start --no-block etcd || return 1
  wait_until 120 "etcd healthy again" etcd_healthy && wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario etcd-member-down
