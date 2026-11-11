#!/usr/bin/env bash
# Scenario switchover: planned switchover to a replica, the way CloudNativePG documents it (kubectl cnpg promote; without the plugin, the status change the plugin makes, see promote_to in lib.sh). Expect CNPGPrimaryChanged (lab/packs/cnpg/rules.yml). Pass also needs every row the load client had acknowledged to be on the new primary (a planned switchover shuts the old primary down cleanly after the replica has caught up; assumption, the run checks it). The extra fields record what the signals show, to answer whether a planned switchover can be told from a failover (compare with primary-deleted): old and new primary, timelines, the longest gap between acknowledged writes, acknowledged rows kept and lost, and the Kubernetes events of the window.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("CNPGPrimaryChanged:")
# Other alerts: none expected. A run that delivers one lists it in unexpected_alerts and fails.
ALLOW=()
OLD="" NEW="" TL0="" T0=""
inject() {
  OLD=$(leader_name) && [ -n "$OLD" ] || return 1
  NEW=$(first_replica) && [ -n "$NEW" ] || return 1
  TL0=$(timeline)
  log "switchover $OLD -> $NEW on timeline $TL0"
  T0=$(date +%s.%N)
  promote_to "$NEW"
}
# nothing to undo: roles move; wait for the Cluster to settle
revert() { wait_until 300 "cluster healthy" cluster_healthy; }
extra_checks() { role_change_evidence "$OLD" "$TL0" "$T0" "$T_INJECT" "$T_END"; }
run_scenario switchover
