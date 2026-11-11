#!/usr/bin/env bash
# Scenario primary-deleted: kubectl delete pod of the current primary. CloudNativePG notices the missing primary, promotes a replica (failover.md, "Failover": the primary pod is deleted), and recreates the pod as a replica. Expect CNPGPrimaryChanged (lab/packs/cnpg/rules.yml). Pass also needs every row the load client had acknowledged to be on the new primary (assumption: the delete is a SIGTERM and a clean shutdown, so the WAL reaches the replicas; the run checks it, and a loss would be a finding, not a flake). The extra fields are those of switchover.sh.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("CNPGPrimaryChanged:")
OLD="" TL0="" T0=""
inject() {
  OLD=$(leader_name) && [ -n "$OLD" ] || return 1
  TL0=$(timeline)
  log "deleting pod $OLD (primary, timeline $TL0)"
  T0=$(date +%s.%N)
  kc delete pod "$OLD" --wait=false >/dev/null
}
# nothing to undo: CloudNativePG recreates the pod; wait for it to be a healthy replica
revert() { wait_until 300 "cluster healthy" cluster_healthy; }
extra_checks() { role_change_evidence "$OLD" "$TL0" "$T0" "$T_INJECT" "$T_END"; }
run_scenario primary-deleted
