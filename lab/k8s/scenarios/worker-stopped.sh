#!/usr/bin/env bash
# Scenario worker-stopped: power cut of the kind node that runs the primary: `docker kill` (SIGKILL), revert `docker start`. docker kill was enough, the node rejoined by itself (Ready 2 s after the start, smoke runs 2026-11-11), so `docker stop` was not needed. The primary must run on a worker without the CloudNativePG operator (its absence would stall the failover) and the load client (its acked ids would be lost); otherwise a preparatory switchover is made and the run waits 210 s for its CNPGPrimaryChanged to pass.
# Expect CNPGPrimaryChanged, KubernetesNodeNotReady (lab/packs/k8s/rules.yml) and CollectorAbsent for otelcol-agent-<node> (the slowest, about 3.7 minutes after the kill). The pods tolerate not-ready for 300 s (tolerationSeconds, read on the pods), so detection is capped at 270 s (DETECT_DEADLINE in lib-core.sh) plus a 15 s hold: no eviction.
# Allowed: StandbyNotStreaming and PhysicalSlotInactive (seen in one run only) and SeriesVanished for the surviving replica only: its slot series ended with the promotion and came back after the rejoin, a gap longer than the rule's 2 m window. The killed instance has no heartbeat, which the rule requires. Replication is asynchronous (no spec.postgresql.synchronous, minSyncReplicas 0 in cnpg/cluster.yaml): writer_missing is recorded and fails the run only for a row acknowledged more than 10 s (a choice) before the kill.
# Events seen: Node NodeNotReady, NodeReady; Pod NodeNotReady, TaintManagerEviction (message "Cancelling deletion of Pod"); Cluster FailingOver, FailoverTarget.
# shellcheck disable=SC1091,SC2034,SC2153
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# overall cap below the 300 s not-ready toleration of the pods (see header)
DETECT_DEADLINE=270
# lib-core sets HOLD_AFTER_DETECT to 0 before this point
[ "$HOLD_AFTER_DETECT" -gt 0 ] || HOLD_AFTER_DETECT=15
EXPECT=()
ALLOW=()
for p in "${NODES[@]}"; do ALLOW+=("StandbyNotStreaming:$p" "PhysicalSlotInactive:$p"); done
OLD="" TL0="" T0="" NODE="" T_KILLED="" T_STARTED="" SECONDS_DOWN=null NODE_NOT_READY=""

node_ready() { [ "$(kcg get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }
vmalert_quiet() { curl -fsS "$VMALERT/api/v1/alerts" | jq -e '[.data.alerts[] | select(.name != "Watchdog")] | length == 0' >/dev/null; }
pod_node() { kc get pod "$1" -o jsonpath='{.spec.nodeName}'; }
# Precondition: the primary runs on a worker that hosts neither the operator
# nor the load client. If it does not, switch over (promote_to) to an instance
# that does, and wait until no alert is left from that promotion.
eval "$(declare -f lab_precondition | sed '1s/lab_precondition/base_lab_precondition/')"
lab_precondition() {
  base_lab_precondition || return 1
  local busy p n target="" pod
  busy=$(kc get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk '$1 ~ /^obenhub-load/ {print $2}'; kcg -n cnpg-system get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
  p=$(leader_name)
  # the current primary first, so a primary already on a free worker is kept
  for pod in "$p" "${NODES[@]}"; do
    [ -n "$pod" ] || continue
    n=$(pod_node "$pod")
    case "$n" in *worker*) ;; *) continue ;; esac
    printf '%s\n' "$busy" | grep -qx "$n" && continue
    target=$pod; break
  done
  [ -n "$target" ] || { PRE_ERR="no instance runs on a worker free of the operator and the load client"; return 1; }
  if [ "$target" != "$p" ]; then
    log "primary $p is not on a free worker; switching over to $target first"
    promote_to "$target" || { PRE_ERR="promote_to $target failed"; return 1; }
    wait_until 300 "cluster healthy on $target" cluster_healthy || { PRE_ERR="no healthy cluster after the switchover"; return 1; }
    [ "$(leader_name)" = "$target" ] || { PRE_ERR="primary is not $target after the switchover"; return 1; }
    # CNPGPrimaryChanged needs a pack sample after the promotion and holds for 3 minutes after it
    # (lab/packs/cnpg/rules.yml); a quiet check right after the promotion passes before it has
    # even started (observed in two aborted smoke runs), so wait out the window first.
    # Then vmalert, then Alertmanager (it shows an alert only after its group_wait).
    log "waiting 210 s for the CNPGPrimaryChanged of the preparatory switchover to pass"
    sleep 210
    wait_until 400 "vmalert quiet after the switchover" vmalert_quiet || { PRE_ERR="vmalert still has alerts after the preparatory switchover"; return 1; }
    wait_until 400 "Alertmanager clean after the switchover" am_clean || { PRE_ERR="Alertmanager not clean after the preparatory switchover"; return 1; }
  fi
}

inject() {
  OLD=$(leader_name) && [ -n "$OLD" ] || return 1
  NODE=$(pod_node "$OLD") && [ -n "$NODE" ] || return 1
  TL0=$(timeline)
  EXPECT=("CNPGPrimaryChanged:" "KubernetesNodeNotReady:" "CollectorAbsent:otelcol-agent-$NODE")
  log "power cut of kind node $NODE (primary $OLD, timeline $TL0): docker kill"
  T0=$(date +%s.%N)
  docker kill "$NODE" >/dev/null || return 1
  T_KILLED=$(now_ts)
}
after_detect() {
  # SeriesVanished is allowed for the surviving replica only: neither the killed
  # instance nor the promoted one. The promoted one is known by now (the run has
  # seen CNPGPrimaryChanged); if it is not, nothing is allowed.
  local new rep
  new=$(leader_name) || new=""
  if [ -n "$new" ] && [ "$new" != "$OLD" ]; then
    for rep in "${NODES[@]}"; do
      [ "$rep" = "$OLD" ] || [ "$rep" = "$new" ] || ALLOW+=("SeriesVanished:$rep")
    done
  fi
  NODE_NOT_READY=$(node_ready "$NODE" && echo false || echo true)
  log "while down: node $NODE not Ready=$NODE_NOT_READY; instance pods bound to it: $(kc get pods -l cnpg.io/cluster="$CLUSTER" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk -v n="$NODE" '$2 == n {print $1}' | paste -sd, -)"
}
revert() {
  [ -n "$NODE" ] || return 0
  docker start "$NODE" >/dev/null || return 1
  T_STARTED=$(now_ts)
  SECONDS_DOWN=$(secs "$T_KILLED" "$T_STARTED")
  wait_until 300 "node $NODE Ready" node_ready "$NODE" || return 1
  wait_until 400 "cluster healthy" cluster_healthy
}
extra_checks() {
  local node_events sync="null" f keep=() oldest age=null ep out
  role_change_evidence "$OLD" "$TL0" "$T0" "$T_INJECT" "$T_END"
  # Asynchronous replication (header): a missing acknowledged row does not fail
  # the run unless it was acknowledged more than 10 s before the kill. ids and
  # epochs are ascending together, so the oldest missing id (the first of
  # writer_missing_ids_first_200) is the one to check.
  sync=$(cluster_json | jq -c '((.spec.minSyncReplicas // 0) > 0) or ((.spec.postgresql.synchronous // null) != null)') || sync=null
  [ -n "$sync" ] || sync=null
  oldest=$(jq -r '.writer_missing_ids_first_200 // empty | split(",")[0]' <<<"$EXTRA_JSON" 2>/dev/null)
  if [ -n "$oldest" ]; then
    ep=$(kc exec "$LOAD" -- cat /work/acked | awk -v id="$oldest" '$2 == id { print $1; exit }')
    [ -z "$ep" ] || age=$(awk -v t="$T0" -v e="$ep" 'BEGIN{printf "%.1f", t - e}')
  fi
  for f in "${FAILS[@]}"; do
    if [ "$sync" = false ] && [[ $f == *"acknowledged rows missing on the primary"* ]]; then
      if [ "$age" != null ] && awk -v a="$age" 'BEGIN{exit !(a <= 10)}'; then log "recorded, not failed (asynchronous, oldest missing row acknowledged ${age}s before the kill): $f"; continue; fi
      f="$f; age of the oldest missing row before the kill: ${age} s (more than 10 s, or unknown)"
    fi
    keep+=("$f")
  done
  FAILS=("${keep[@]}")
  node_events=$(vl "_time:>$T_INJECT _time:<=$T_END object.reason:* object.regarding.kind:=Node | stats by (object.regarding.name, object.reason, object.type) count() n, min(_time) first | sort by (first)" | jq -s -c 'map({name: .["object.regarding.name"], reason: .["object.reason"], type: .["object.type"], records: (.n|tonumber), first: .first})' 2>/dev/null) || node_events=null
  [ -n "$node_events" ] || node_events=null
  if out=$(jq -c --arg node "$NODE" --arg killed "$T_KILLED" --arg started "$T_STARTED" --argjson down "${SECONDS_DOWN:-null}" --argjson sync "$sync" --argjson age "$age" --argjson nev "$node_events" \
    '. + {stopped_node: $node, method: "docker kill", killed_at: $killed, started_at: $started, seconds_node_down: $down, synchronous_replication: $sync, oldest_missing_age_seconds: $age, node_events: $nev}' <<<"$EXTRA_JSON" 2>/dev/null) && [ -n "$out" ]; then
    EXTRA_JSON=$out
  fi
  log "extra: $EXTRA_JSON"
}
run_scenario worker-stopped
