#!/usr/bin/env bash
# Scenario fenced: fence the first replica the way CloudNativePG documents it, the annotation cnpg.io/fencedInstances on the Cluster (the kubectl-cnpg plugin's `fencing on` sets the same annotation; assumption, the plugin is not installed on this box). The instance manager stops PostgreSQL in the pod; the pod stays Running, turns not ready, and its exporter keeps answering with cnpg_collector_fencing_on 1 (read 2026-11-11). Expect CNPGInstanceFenced for the replica and PostgresPhysicalSlotInactive for the primary: the fenced replica's HA slot _cnpg_<replica> has no consumer, which is the pack's rule working as designed, and it holds for as long as the fence does, so the run waits for it too. All pack series of the fenced pod stop, the heartbeat included (read 2026-11-11), so PostgresSeriesVanished stays quiet and PostgresTargetAbsent is inert on this lab (see lab/packs/cnpg/rules.yml). Pass needs both alerts, both resolved after the revert, and no other alert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
ALLOW=()
REP="" PRIM="" READY_FENCED="" POD_READY_FENCED=""
inject() {
  REP=$(first_replica) && [ -n "$REP" ] || return 1
  PRIM=$(leader_name)
  EXPECT=("CNPGInstanceFenced:$REP" "PostgresPhysicalSlotInactive:$PRIM")
  log "fencing $REP (primary $PRIM)"
  kc annotate cluster "$CLUSTER" "cnpg.io/fencedInstances=[\"$REP\"]" --overwrite >/dev/null
}
after_detect() {
  READY_FENCED=$(cluster_json | jq -r '.status.readyInstances')
  POD_READY_FENCED=$(kc get pod "$REP" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}')
  log "while fenced: readyInstances=$READY_FENCED, container postgres of $REP ready=$POD_READY_FENCED"
}
revert() {
  kc annotate cluster "$CLUSTER" cnpg.io/fencedInstances- >/dev/null 2>&1 || true
  wait_until 300 "cluster healthy" cluster_healthy
}
extra_checks() {
  EXTRA_JSON=$(jq -n -c --arg rep "$REP" --arg prim "$PRIM" --arg ready "$READY_FENCED" --arg pod "$POD_READY_FENCED" --argjson events "$(events_json "$T_INJECT" "$T_END")" \
    '{fenced: $rep, primary: $prim, ready_instances_while_fenced: ($ready|if . == "" then null else tonumber end), postgres_container_ready_while_fenced: ($pod|if . == "" then null else . == "true" end), kubernetes_events: $events}')
  log "extra: $EXTRA_JSON"
}
run_scenario fenced
