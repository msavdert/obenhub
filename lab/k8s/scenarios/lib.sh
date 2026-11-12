#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# k8s adapter for the shared fault scenario machinery in
# lab/scenarios/lib-core.sh: it binds the core to the kind lab (lab/k8s:
# CloudNativePG Cluster pg in namespace obenhub, kubectl context kind-<name>)
# and to the backend Compose project obenhub-k8s on this box. Source it from
# a scenario; do not run it. The core's header lists what an adapter provides.
#
# The core was written for Patroni. Its Patroni and etcd helpers (ptl,
# members, leader_name, first_replica, timeline, cluster_healthy,
# cluster_paused, etcd_*) are redefined here after the
# core is sourced, on the Cluster's status; the core calls them only through those names, so
# no core change is needed. There is no etcd and no pause: NODES holds the
# pod names, ETCD_MEMBERS is empty, not_paused always succeeds.
# Nodes are pods (pg-1..3), named, never roles; service.instance.id is the pod
# name for the pack's series (lab/k8s/README.md).
#
# Load client: Deployment obenhub-load (lab/k8s/load/load.yaml) writes about
# five rows a second through pg-rw and logs every acknowledged id to
# /work/acked in its pod ("epoch id"). role_change_evidence compares that file
# with the table on the new primary.
#
# Needs: kubectl (with the kubectl-cnpg plugin), curl, jq, docker (the alerting config hash is read inside
# the backend containers), the lab running (lab/k8s/scripts/up.sh).

# The pinned tools live in mise.k8s.toml (MISE_ENV=k8s). A scenario started
# without them on PATH re-runs itself once under `MISE_ENV=k8s mise exec`.
if ! "$(dirname "${BASH_SOURCE[0]}")/../scripts/check-tools.sh" >/dev/null 2>&1 &&
  [ -z "${OBENHUB_MISE_REEXEC:-}" ] && command -v mise >/dev/null; then
  export OBENHUB_MISE_REEXEC=1
  MISE_ENV=k8s exec mise exec -- "$0" "$@"
fi

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
# shellcheck source=lab/k8s/versions.sh
. "$LAB_DIR/versions.sh"
RESULTS="$LAB_DIR/results/runs.jsonl"
NS=obenhub
CLUSTER=pg
KCTX="kind-$KIND_CLUSTER"
VL=${VL:-http://127.0.0.1:49428}
AM=${AM:-http://127.0.0.1:49093}
VMALERT=${VMALERT:-http://127.0.0.1:48880}
VM=${VM:-http://127.0.0.1:48428}
VMALERT_C=obenhub-k8s-vmalert
AM_C=obenhub-k8s-alertmanager
NODES=(pg-1 pg-2 pg-3)
ETCD_MEMBERS=()
# Same files, same order as the containers read them (inventory, then
# pack/*.yml sorted by name: cnpg.yml, k8s.yml, postgresql.yml; lab/k8s/mon/compose.yaml).
CONFIG_FILES=("$LAB_DIR/mon/vmalert/inventory.yml" "$LAB_DIR/../packs/cnpg/rules.yml" "$LAB_DIR/../packs/k8s/rules.yml" "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/../stage3/alertmanager/alertmanager.yml")

# shellcheck source=lab/scenarios/lib-core.sh
. "$SC_DIR/../../scenarios/lib-core.sh"

# kubectl in the lab's namespace; kcg without the namespace
kc() { kubectl --context "$KCTX" -n "$NS" "$@"; }
kcg() { kubectl --context "$KCTX" "$@"; }
cluster_json() { kc get cluster "$CLUSTER" -o json; }

# psql as superuser on a pod's local socket (the instance image runs as
# postgres); callers pass -d app like the pgha scenarios do
psql_n() { local n=$1; shift; kc exec "$n" -c postgres -- psql -X -v ON_ERROR_STOP=1 -At "$@"; }

# --- Cluster state, in place of Patroni's members ----------------------------
# current primary: status.currentPrimary, the instance the operator has
# finished promoting (targetPrimary leads it during a switchover)
leader_name() { cluster_json | jq -r '.status.currentPrimary // empty'; }
leader_or() { local l; l=$(leader_name); echo "${l:-$1}"; }
first_replica() {
  local p; p=$(leader_name) || return 1
  cluster_json | jq -r --arg p "$p" '[.status.instancesStatus.healthy[]? | select(. != $p)] | sort | .[0] // empty'
}
# timeline of the Cluster: status.timelineID (CloudNativePG 1.30.1 API)
timeline() { cluster_json | jq -r '.status.timelineID // empty'; }
# three ready instances, phase healthy, current == target primary, one
# primary that is writable and two replicas streaming from it
cluster_healthy() {
  local p
  cluster_json | jq -e '
    .status.readyInstances == 3
    and .status.phase == "Cluster in healthy state"
    and (.status.currentPrimary // "") != ""
    and .status.currentPrimary == .status.targetPrimary
    and ((.status.instancesStatus.healthy // []) | length) == 3' >/dev/null || return 1
  p=$(leader_name) && [ -n "$p" ] || return 1
  [ "$(psql_n "$p" -d app -c "SELECT NOT pg_is_in_recovery() AND (SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming') = 2")" = t ]
}
cluster_paused() { return 1; }
not_paused() { return 0; }
# no etcd here; the core's etcd_* helpers are not called by this lab's scenarios
etcd_status() { return 1; }

# primary_gap_seconds (core) is not used here: in the smoke runs of
# 2026-11-11 the old and the new primary overlapped in every 15 s step, so it
# always read 0 while the writer saw 5 to 9 s without an acknowledged write.
# The writer's gap (seconds_without_acknowledged_write) is the outage measure.

# --- load client --------------------------------------------------------------
LOAD=deploy/obenhub-load
# the Deployment is available and has acknowledged a row in the last 30 s
load_running() {
  local last now
  last=$(kc exec "$LOAD" -- tail -n1 /work/acked 2>/dev/null | cut -d' ' -f1)
  now=$(date +%s)
  [ -n "$last" ] && awk -v l="$last" -v n="$now" 'BEGIN{exit !(n - l < 30)}'
}

# component versions recorded under "images" in runs.jsonl: the operand image
# the Cluster runs, the CloudNativePG operator, the kind node image, the Collector
component_versions() {
  {
    cluster_json | jq -r '.status.image // empty'
    kcg -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
    echo
    echo "$KIND_NODE_IMAGE"
    echo "$OTELCOL_IMAGE"
  } 2>/dev/null | grep . | sort -u | jq -R . | jq -s -c .
}

lab_precondition() {
  wait_until 180 "cluster healthy (one primary, two streaming replicas, 3 ready)" cluster_healthy || { PRE_ERR="cluster not healthy"; return 1; }
  wait_until 60 "load client acknowledging rows" load_running || { PRE_ERR="load client not running or not acknowledging rows (Deployment obenhub-load)"; return 1; }
}

# --- role change evidence (switchover.sh, primary-deleted.sh) -----------------
# promote_to POD: make POD the primary with `kubectl cnpg promote CLUSTER POD`,
# the method CloudNativePG documents (kubectl-plugin.md, "Promote"). The plugin
# is pinned in mise.k8s.toml at CNPG_VERSION. Read at v1.30.1,
# internal/cmd/plugin/promote/promote.go: it returns early when POD is already
# status.targetPrimary, refuses a fenced POD, requires the Pod to exist, then
# sets status.targetPrimary, targetPrimaryTimestamp, phase "Switchover in
# progress" and phaseReason on the Cluster status (optimistic lock); the
# operator does the rest. It does not wait; callers wait for the Cluster.
promote_to() {
  # --context after the plugin name: kubectl does not hand flags before it to a plugin
  kubectl cnpg promote --context "$KCTX" -n "$NS" "$CLUSTER" "$1"
}

# event_reasons SINCE UNTIL: Kubernetes events in the namespace in the window,
# as a JSON array {kind, name, reason, type, records, first}, from VictoriaLogs
# (k8sobjects receiver; fields object.*). Nothing is filtered by name.
# records counts log records, not the Kubernetes event's own count: the
# receiver may emit one event more than once.
event_reasons() {
  local out
  out=$(vl "_time:>$1 _time:<=$2 object.reason:* object.regarding.namespace:=$NS | stats by (object.regarding.kind, object.regarding.name, object.reason, object.type) count() n, min(_time) first | sort by (first)") || return 1
  printf '%s\n' "$out" | jq -s -c 'map({kind: .["object.regarding.kind"], name: .["object.regarding.name"], reason: .["object.reason"], type: .["object.type"], records: (.n|tonumber), first: .first})'
}

# acked_rows FROM_EPOCH: the load client's acknowledged ids since FROM_EPOCH.
# Callers start 60 s before the fault: with asynchronous replication the rows
# most at risk are the ones acknowledged just before it.
acked_rows() { kc exec "$LOAD" -- cat /work/acked | awk -v f="$1" '$1 >= f { print $2 }'; }

# role_change_evidence OLD TL0 T0_EPOCH FROM_ISO UNTIL_ISO: builds EXTRA_JSON and
# adds to FAILS when an acknowledged row is missing on the current primary.
# Call it from extra_checks: the cluster is healthy again and the window is closed.
role_change_evidence() {
  local old=$1 tl0=$2 t0=$3 from=$4 until=$5
  local new tl1 tl_sql acked missing=null kept=null miss_ids="" events wgap=null ids rc
  new=$(leader_name 2>/dev/null) || new=""
  tl1=$(timeline 2>/dev/null) || tl1=""
  tl_sql=$([ -n "$new" ] && psql_n "$new" -d app -c "SELECT timeline_id FROM pg_control_checkpoint()" 2>/dev/null || true)
  events=$(event_reasons "$from" "$until" 2>/dev/null) || events=""
  [ -n "$events" ] || { events=null; FAILS+=("Kubernetes event query against VictoriaLogs failed"); }
  acked=0
  ids=$(mktemp)
  if acked_rows "$(awk -v t="$t0" 'BEGIN{printf "%.3f", t - 60}')" >"$ids" 2>/dev/null && [ -s "$ids" ] && [ -n "$new" ]; then
    acked=$(wc -l <"$ids")
    local have; have=$(mktemp)
    # an empty answer is not a read failure: it means every acknowledged row is gone
    psql_n "$new" -d app -c "SELECT id FROM load_rows WHERE id >= $(LC_ALL=C sort -n "$ids" | head -n1)" >"$have.raw" 2>/dev/null
    rc=$?
    if [ "$rc" = 0 ]; then
      LC_ALL=C sort "$have.raw" >"$have"
      LC_ALL=C sort "$ids" >"$ids.s"
      missing=$(LC_ALL=C comm -23 "$ids.s" "$have" | wc -l)
      kept=$((acked - missing))
      miss_ids=$(LC_ALL=C comm -23 "$ids.s" "$have" | sort -n | head -n 200 | paste -sd, -)
      [ "$missing" = 0 ] || FAILS+=("$missing of $acked acknowledged rows missing on the primary $new; ids: ${miss_ids:0:200}")
    else
      FAILS+=("cannot read load_rows on the primary ${new:-?}")
    fi
    rm -f "$have" "$have.raw" "$ids.s"
    # longest gap between two acknowledged writes from the fault on (writer view)
    wgap=$(kc exec "$LOAD" -- cat /work/acked | awk -v f="$t0" '$1 >= f - 5 { if (p && $1 - p > m) m = $1 - p; p = $1 } END { printf "%.1f", m }')
  else
    FAILS+=("load client result not available (no acknowledged ids, or no primary)")
  fi
  rm -f "$ids"
  # the gap above only spans acknowledged rows; a writer that never resumed
  # would show a short gap, so the load must be acknowledging again now
  load_running || FAILS+=("load client has not acknowledged a write in the last 30 s")
  [[ $wgap =~ ^[0-9.]+$ ]] || wgap=null
  EXTRA_JSON=$(jq -n -c --arg old "$old" --arg new "$new" --arg tl0 "$tl0" --arg tl1 "$tl1" --arg tlsql "$tl_sql" \
    --argjson wgap "$wgap" --argjson acked "$acked" --argjson kept "$kept" --argjson missing "$missing" --arg mids "$miss_ids" --argjson events "$events" '
    def nz: if . == "" then null else . end;
    def num: nz | if . then tonumber else . end;
    {old_primary: ($old|nz), new_primary: ($new|nz), timeline_before: ($tl0|num), timeline_after: ($tl1|num),
     timeline_after_pg_control_checkpoint: ($tlsql|num),
     seconds_without_acknowledged_write: $wgap,
     writer_acked: $acked, writer_kept: $kept, writer_missing: $missing, writer_missing_ids_first_200: ($mids|nz),
     kubernetes_events: $events}')
  log "extra: $EXTRA_JSON"
}

# --- network cut of one replica (replica-cut.sh, slot-retaining-wal.sh) ------
# cut_replica REPLICA: NetworkPolicy obenhub-replica-cut on the current
# primary's pod (selected by cnpg.io/instanceName) that admits every source
# except REPLICA's pod IP, so the operator, the Collectors and the load client
# keep their access to the primary and only the replica loses it (kindnet
# enforces NetworkPolicy and ipBlock on pod IPs: probed 2026-11-11, a pg_isready
# from the excluded pod timed out, from the other replica it answered, through
# the pg-rw Service too). The policy filters new connections only: the
# established walsender connection survives it, so the walsender of REPLICA is
# terminated once the policy is in force, and the replica's reconnects meet the
# policy. Prints the primary's name.
CUT_POLICY=obenhub-replica-cut
cut_replica() {
  local rep=$1 prim ip pip n=0
  prim=$(leader_name) && [ -n "$prim" ] || return 1
  # a failover since the caller picked the replica: refuse rather than cut the primary from itself
  [ "$prim" != "$rep" ] || { log "$rep is the primary now; not cutting"; return 1; }
  ip=$(kc get pod "$rep" -o jsonpath='{.status.podIP}') && [ -n "$ip" ] || return 1
  pip=$(kc get pod "$prim" -o jsonpath='{.status.podIP}') && [ -n "$pip" ] || return 1
  kc apply -f - >/dev/null <<ENDPOLICY || return 1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $CUT_POLICY
spec:
  podSelector:
    matchLabels:
      cnpg.io/instanceName: $prim
  policyTypes: [Ingress]
  ingress:
    - from:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: ["$ip/32"]
ENDPOLICY
  # in force when the replica can no longer open a connection to the primary
  # pg_isready exits 2 when it gets no response (a dropped SYN, but also a refused connection: a primary
  # restarting here passes the loop, and the terminate below then fails the cut); other codes are not the cut
  local rc
  while :; do
    kc exec "$rep" -c postgres -- pg_isready -h "$pip" -t 2 >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 2 ] || break
    n=$((n + 1)); [ "$n" -lt 20 ] || { log "NetworkPolicy not in force after 20 tries"; return 1; }
    sleep 2
  done
  psql_n "$prim" -d app -c "SELECT pg_terminate_backend(pid) FROM pg_stat_replication WHERE application_name = '$rep'" >/dev/null || return 1
  echo "$prim"
}
# uncut_replica: remove the policy (the replica reconnects by itself)
uncut_replica() { kc delete networkpolicy "$CUT_POLICY" --ignore-not-found >/dev/null; }

# events_json FROM UNTIL: the window's Kubernetes events as JSON, null when the query fails
events_json() { event_reasons "$1" "$2" 2>/dev/null || echo null; }
