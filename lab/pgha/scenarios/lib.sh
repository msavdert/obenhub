#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2029,SC2034
# pgha adapter for the shared Patroni fault scenario machinery in
# lab/scenarios/lib-core.sh: it binds the core to the three Debian VMs over
# ssh (same options as rn() in lab/pgha/scripts/provision.sh) and to the
# backend Compose project obenhub-pgha on this box. Source it from a
# scenario; do not run it. The core's header lists what an adapter provides.
#
# Per node: patronictl as postgres with /etc/patroni/config.yml (it sends the
# restapi basic-auth credentials for unsafe actions, ctl: in that file),
# psql as postgres over /var/run/postgresql (peer authentication), etcdctl
# as root with the client certificate etcdctl.crt. service.instance.id is
# pgha-N for PostgreSQL, Patroni and etcd alike, so one name serves all.
#
# Needs: ssh to pgha-1..3 (user with sudo), curl, jq, docker (the Collector
# config hash is read inside the backend containers), the lab running
# (mise run lab:pgha:mon:up and lab:pgha:provision).

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
RESULTS="$LAB_DIR/results/runs.jsonl"
CLUSTER=pgha
VL=${VL:-http://127.0.0.1:39428}
AM=${AM:-http://127.0.0.1:39093}
VMALERT=${VMALERT:-http://127.0.0.1:38880}
VMALERT_C=obenhub-pgha-vmalert
AM_C=obenhub-pgha-alertmanager
VM=${VM:-http://127.0.0.1:38428}
# nodes.sh sets NODES to a "name=ip ..." string; keep it as a lookup and make
# NODES the array of names the core expects
# shellcheck source=lab/pgha/nodes.sh
. "$LAB_DIR/nodes.sh"
NODE_MAP=$NODES
NODES=()
for _e in $NODE_MAP; do NODES+=("${_e%%=*}"); done
ETCD_MEMBERS=("${NODES[@]}")
CONFIG_FILES=("$LAB_DIR/mon/vmalert/inventory.yml" "$LAB_DIR/../packs/etcd/rules.yml" "$LAB_DIR/../packs/host/rules.yml" "$LAB_DIR/../packs/patroni/rules.yml" "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/../stage3/alertmanager/alertmanager.yml")

# shellcheck source=lab/scenarios/lib-core.sh
. "$SC_DIR/../../scenarios/lib-core.sh"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
node_ip() { local e; for e in $NODE_MAP; do [ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return 0; }; done; return 1; }
# rn NODE COMMAND...: run a command as root on the node. ssh joins its
# arguments into one remote command line, so each one is quoted. -n: ssh must
# not read the caller's stdin.
rn() { local n=$1; shift; ssh -n "${SSH_OPTS[@]}" "$n" "sudo $(printf '%q ' "$@")"; }
# rn_in NODE COMMAND...: like rn, stdin is passed on
rn_in() { local n=$1; shift; ssh "${SSH_OPTS[@]}" "$n" "sudo $(printf '%q ' "$@")"; }

# psql as superuser over the node's local socket
psql_n() { local n=$1; shift; rn "$n" -u postgres psql -h /var/run/postgresql -X -v ON_ERROR_STOP=1 -At "$@"; }

# patronictl on the first node that answers (a stopped node cannot). The
# timeout keeps a call from hanging when the DCS has no quorum.
ptl() {
  local n
  for n in "${NODES[@]}"; do
    rn "$n" -u postgres timeout 120 patronictl -c /etc/patroni/config.yml "$@" 2>/dev/null && return 0
  done
  return 1
}

# etcdctl on a node against all members over TLS (client certificate)
ETCD_TLS=(--cacert=/etc/etcd/tls/ca.crt --cert=/etc/etcd/tls/etcdctl.crt --key=/etc/etcd/tls/etcdctl.key)
etcd_eps() { local n o=""; for n in "${NODES[@]}"; do o="$o${o:+,}https://$(node_ip "$n"):2379"; done; printf '%s' "$o"; }
etcd_status() {
  local n out e sed_args=()
  for e in $NODE_MAP; do sed_args+=(-e "s#^https://${e#*=}:2379#${e%%=*}#"); done
  for n in "${NODES[@]}"; do
    out=$(rn "$n" etcdctl --endpoints="$(etcd_eps)" "${ETCD_TLS[@]}" endpoint status 2>/dev/null)
    [ -n "$out" ] && { printf '%s\n' "$out" | sed "${sed_args[@]}"; return 0; }
  done
  return 1
}
# etcd_move_leader TARGET: ask the current leader to hand over to TARGET
etcd_move_leader() {
  local l id; l=$(etcd_leader); id=$(etcd_member_id "$1")
  [ -n "$l" ] && [ -n "$id" ] || return 1
  rn "$l" etcdctl --endpoints="https://$(node_ip "$l"):2379" "${ETCD_TLS[@]}" move-leader "$id" >/dev/null
}

# nftables fault table "inet obenhub_fault" on a node. fault_table_add reads
# the table definition from stdin; fault_table_del removes it and succeeds
# when it is already gone.
fault_table_add() { rn_in "$1" nft -f -; }
fault_table_del() {
  rn "$1" sh -c 'nft list table inet obenhub_fault >/dev/null 2>&1 && nft delete table inet obenhub_fault; true' || return 1
  [ "$(fault_table_state "$1")" = absent ]
}
# fault_table_state NODE: prints present or absent; fails when the node cannot
# be asked (ssh or nft error), so an unreachable node never counts as clean.
fault_table_state() {
  local t
  t=$(rn "$1" nft list tables) || return 1
  if grep -qx 'table inet obenhub_fault' <<<"$t"; then echo present; else echo absent; fi
}

# the load unit (files/load.sh) runs on every node and writes on the primary
load_running() {
  local n
  for n in "${NODES[@]}"; do
    [ "$(rn "$n" systemctl is-active obenhub-load 2>/dev/null)" = active ] || return 1
  done
  # and the primary really writes: a pgbench round lasts 60 s, so the newest
  # history row is younger than 90 s while the load works
  [ "$(psql_n "$(leader_name)" -d app -c "SELECT coalesce(max(mtime) > now() - interval '90 seconds', false) FROM pgbench_history")" = t ]
}

# component versions, taken from the nodes; recorded under "images" in
# runs.jsonl like the stage 3 image names. A node that differs adds a line.
component_versions() {
  local n
  for n in "${NODES[@]}"; do
    rn "$n" sh -c '/usr/lib/postgresql/18/bin/postgres --version | sed "s/ (Debian.*//"; patroni --version; /usr/local/bin/etcd --version | head -n1 | sed "s/ Version: / /"; otelcol-contrib --version | sed "s/ version / /"' 2>/dev/null
  done | sort -u | jq -R . | jq -s -c .
}

lab_precondition() {
  local n
  wait_until 120 "etcd healthy (three members, one leader)" etcd_healthy || { PRE_ERR="etcd not healthy"; return 1; }
  wait_until 180 "cluster healthy (one leader, two streaming replicas)" cluster_healthy || { PRE_ERR="cluster not healthy"; return 1; }
  not_paused || { PRE_ERR="cluster is paused"; return 1; }
  wait_until 30 "load unit active on every node and writing on the primary" load_running || { PRE_ERR="load unit not running on every node, or the primary not written in 90 s"; return 1; }
  for n in "${NODES[@]}"; do
    [ "$(fault_table_state "$n")" = absent ] || { PRE_ERR="nftables table obenhub_fault left over on $n, or $n unreachable"; return 1; }
  done
}
