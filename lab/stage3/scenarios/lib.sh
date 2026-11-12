#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Stage 3 adapter for the shared Patroni fault scenario machinery in
# lab/scenarios/lib-core.sh: it binds the core to the Compose lab (docker
# exec into the node containers). Source it from a scenario; do not run it.
# A scenario defines EXPECT, inject() and revert() and calls run_scenario (see
# cluster-paused.sh for the smallest example). The core's header lists what
# an adapter provides.
#
# Needs: docker, curl, jq, the lab running (mise run lab:stage3:up).

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
RESULTS="$LAB_DIR/results/runs.jsonl"
PROJECT=obenhub-stage3
CLUSTER=stage3
VL=${VL:-http://127.0.0.1:29428}
AM=${AM:-http://127.0.0.1:29093}
VMALERT=${VMALERT:-http://127.0.0.1:28880}
VMALERT_C=obenhub-stage3-vmalert
AM_C=obenhub-stage3-alertmanager
VM=${VM:-http://127.0.0.1:28428}
NODES=(pg-1 pg-2 pg-3)
ETCD_MEMBERS=(etcd-1 etcd-2 etcd-3)
REPL_NET=obenhub-stage3_repl
LOAD=obenhub-stage3-load
CONFIG_FILES=("$LAB_DIR/vmalert/inventory.yml" "$LAB_DIR/../packs/etcd/rules.yml" "$LAB_DIR/../packs/patroni/rules.yml" "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/../mon/alertmanager.yml")

# shellcheck disable=SC1091
[ -r "$LAB_DIR/.env" ] && set -a && . "$LAB_DIR/.env" && set +a

# shellcheck source=lab/scenarios/lib-core.sh
. "$SC_DIR/../../scenarios/lib-core.sh"

dc() { docker compose -p "$PROJECT" -f "$LAB_DIR/compose.yaml" "$@"; }
cname() { printf 'obenhub-stage3-%s' "$1"; }
# static address of a node on the repl network (compose.yaml)
repl_ip() { printf '10.216.0.1%s' "${1#pg-}"; }

# psql as superuser over the node's local socket (trust, no password).
psql_n() { local n=$1; shift; docker exec -i "$(cname "$n")" psql -U postgres -X -v ON_ERROR_STOP=1 -At "$@"; }

# patronictl on the first node that answers (a stopped node cannot).
ptl() {
  local n
  for n in "${NODES[@]}"; do
    docker exec "$(cname "$n")" patronictl "$@" 2>/dev/null && return 0
  done
  return 1
}

# etcd members, queried from whichever member answers (a stopped one cannot).
# `endpoint status` prints one line per answering member; the endpoint
# http://etcd-N:2379 is reduced to the member name.
ETCD_EPS=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379
etcd_status() {
  local m out
  for m in "${ETCD_MEMBERS[@]}"; do
    out=$(docker exec "$(cname "$m")" etcdctl --endpoints="$ETCD_EPS" endpoint status 2>/dev/null)
    [ -n "$out" ] && { printf '%s\n' "$out" | sed -E 's#^http://([^:]+):2379#\1#'; return 0; }
  done
  return 1
}
# etcd_move_leader TARGET: ask the current leader to hand over to TARGET
etcd_move_leader() {
  local l id; l=$(etcd_leader); id=$(etcd_member_id "$1")
  [ -n "$l" ] && [ -n "$id" ] || return 1
  docker exec "$(cname "$l")" etcdctl --endpoints="http://$l:2379" move-leader "$id" >/dev/null
}

# etcd_stop / etcd_start MEMBER...: stop or start etcd members (shared
# scenarios etcd-member-down and quorum-lost); here the member's container
etcd_stop() { dc stop "$@" >/dev/null; }
etcd_start() { dc start "$@" >/dev/null; }

load_running() { [ "$(docker inspect -f '{{.State.Running}}' "$LOAD" 2>/dev/null)" = true ]; }

# component versions recorded under "images" in runs.jsonl
component_versions() {
  { dc config --images 2>/dev/null | grep -v "^obenhub-"; grep -E '^FROM ' "$LAB_DIR/postgres/Dockerfile" | sed 's/^FROM //'; } | sort -u \
    | jq -R . | jq -s -c .
}

lab_precondition() {
  wait_until 120 "etcd healthy (three members, one leader)" etcd_healthy || { PRE_ERR="etcd not healthy"; return 1; }
  wait_until 180 "cluster healthy (one leader, two streaming replicas)" cluster_healthy || { PRE_ERR="cluster not healthy"; return 1; }
  not_paused || { PRE_ERR="cluster is paused"; return 1; }
  load_running || { PRE_ERR="load container not running"; return 1; }
}
