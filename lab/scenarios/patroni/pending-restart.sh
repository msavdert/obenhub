#!/usr/bin/env bash
# Scenario pending-restart: change shared_buffers (needs a restart) through patronictl edit-config; expect PatroniPendingRestart on every node (the setting is cluster-wide).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
for _n in "${NODES[@]}"; do EXPECT+=("PatroniPendingRestart:$_n"); done
CHANGED=0
inject() {
  ptl edit-config --force -s postgresql.parameters.shared_buffers=192MB >/dev/null || return 1
  CHANGED=1
}
# Setting the value back clears PostgreSQL's pending_restart flag after a
# reload; if Patroni still reports one, restart the flagged members.
revert() {
  [ "$CHANGED" = 1 ] || return 0
  ptl edit-config --force -s postgresql.parameters.shared_buffers=128MB >/dev/null || return 1
  if ! wait_until 90 "pending restart cleared by setting the value back" cluster_healthy; then
    log "pending restart remained after the value was set back; restarting the flagged members"
    ptl restart "$CLUSTER" --pending --force >/dev/null || return 1
    wait_until 180 "cluster healthy" cluster_healthy
  fi
}
run_scenario pending-restart
