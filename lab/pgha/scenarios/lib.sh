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
CONFIG_FILES=("$LAB_DIR/mon/vmalert/inventory.yml" "$LAB_DIR/../packs/etcd/rules.yml" "$LAB_DIR/../packs/host/rules.yml" "$LAB_DIR/../packs/patroni/rules.yml" "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/../mon/alertmanager.yml")

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

# etcd_stop / etcd_start MEMBER...: stop or start etcd (systemctl) on the node
# of that name (shared scenarios etcd-member-down and quorum-lost). Stop quits
# at the first failure; start tries every member and fails if one failed.
etcd_stop() { local m; for m in "$@"; do rn "$m" systemctl stop etcd || return 1; done; }
etcd_start() { local m rc=0; for m in "$@"; do rn "$m" systemctl start --no-block etcd || rc=1; done; return $rc; }

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
  local n t cfg
  # first, so a left-over partition is named as such instead of as "etcd not healthy"
  for n in "${NODES[@]}"; do
    [ "$(fault_table_state "$n")" = absent ] || { PRE_ERR="nftables table obenhub_fault left over on $n, or $n unreachable"; return 1; }
  done
  # the synchronous-standby-cut scenario's second table, and its Patroni keys
  for n in "${NODES[@]}"; do
    t=$(rn "$n" nft list tables) || { PRE_ERR="cannot list nftables tables on $n"; return 1; }
    ! grep -qx 'table inet obenhub_fault2' <<<"$t" || { PRE_ERR="nftables table obenhub_fault2 left over on $n"; return 1; }
  done
  cfg=$(ptl show-config) || { PRE_ERR="patronictl show-config failed"; return 1; }
  ! grep -q '^synchronous_' <<<"$cfg" || { PRE_ERR="synchronous_* keys in the Patroni dynamic configuration (left over from synchronous-standby-cut?)"; return 1; }
  wait_until 120 "etcd healthy (three members, one leader)" etcd_healthy || { PRE_ERR="etcd not healthy"; return 1; }
  wait_until 180 "cluster healthy (one leader, two streaming replicas)" cluster_healthy || { PRE_ERR="cluster not healthy"; return 1; }
  not_paused || { PRE_ERR="cluster is paused"; return 1; }
  wait_until 30 "load unit active on every node and writing on the primary" load_running || { PRE_ERR="load unit not running on every node, or the primary not written in 90 s"; return 1; }
}

# --- network partition helpers (network-partition*.sh) ----------------------
# boot_id NODE: the node's boot id, empty (and status 1) when ssh fails. An
# empty id is "unknown", never "rebooted".
boot_id() { rn "$1" cat /proc/sys/kernel/random/boot_id; }
# boot_id_retry NODE: boot_id, retried for up to 90 s (a node may be booting)
boot_id_retry() {
  local t0 b; t0=$(date +%s)
  while :; do
    b=$(boot_id "$1" 2>/dev/null) && [ -n "$b" ] && { echo "$b"; return 0; }
    [ $(($(date +%s) - t0)) -lt 90 ] || return 1
    sleep 3
  done
}
# probe_from NODE IP PORT: tcp connect from the node, 3 s limit. Status 0
# connected, 1 not connected (refused, timeout), 2 inconclusive (ssh failed,
# status 255). The bash -c program runs on the node, not in this shell.
# shellcheck disable=SC2016
probe_from() {
  local rc
  ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$1" \
    "sudo $(printf '%q ' timeout 3 bash -c 'exec 3<>/dev/tcp/$0/$1' "$2" "$3")" >/dev/null 2>&1
  rc=$?
  case $rc in 0) return 0 ;; 255) return 2 ;; *) return 1 ;; esac
}
# probe_box IP PORT: the same from this box (0 connected, 1 not)
# shellcheck disable=SC2016
probe_box() { timeout 3 bash -c 'exec 3<>/dev/tcp/$0/$1' "$1" "$2" 2>/dev/null; }
# run_probes WANT SPEC...: SPEC is FROM,IP,PORT (FROM a node name or "box"),
# WANT is open or closed. All probes run in parallel. Adds to FAILS and
# returns 1 when one is not as wanted or inconclusive.
run_probes() {
  local want=$1 d s i=0 from ip port rc bad=0 pids=() p
  shift
  d=$(mktemp -d)
  for s in "$@"; do
    i=$((i + 1))
    IFS=, read -r from ip port <<<"$s"
    ( if [ "$from" = box ]; then probe_box "$ip" "$port"; r=$?; [ "$r" -eq 0 ] || r=1; else probe_from "$from" "$ip" "$port"; r=$?; fi; echo "$r" >"$d/$i" ) &
    pids+=("$!")
  done
  # not a bare wait: a caller may have background jobs of its own (the poller)
  for p in "${pids[@]}"; do wait "$p"; done
  i=0
  for s in "$@"; do
    i=$((i + 1)); rc=$(cat "$d/$i" 2>/dev/null)
    case "$want:$rc" in
      open:0 | closed:1) ;;
      *:2 | *:) FAILS+=("probe $s inconclusive (ssh failed)"); bad=1 ;;
      open:1) FAILS+=("probe $s: not reachable, expected open"); bad=1 ;;
      closed:0) FAILS+=("probe $s: reachable, expected dropped"); bad=1 ;;
    esac
  done
  rm -rf "$d"
  return "$bad"
}
# fault_counters NODE: prints "in=N out=N", the packet counters of the two chains
fault_counters() {
  rn "$1" nft list table inet obenhub_fault | awk '/^[[:space:]]*chain /{c=$2} /counter packets/{for(i=1;i<=NF;i++) if($i=="packets") p[c]=$(i+1)} END{printf "in=%d out=%d\n", p["in"], p["out"]}'
}
# isolate_node NODE: nftables table "inet obenhub_fault" on NODE dropping, in
# both hooks, all packets from and to the other two nodes' addresses, and the
# same table on each of the two peers dropping packets from and to NODE's
# address (a real partition survives a reset of one side: the victim's table
# disappears with a reset, the peers' tables keep it isolated until revert;
# suite-3, 2026-11-10, showed that a victim-only table ends with the reset).
# Every other address (ssh from this box, OTLP to the gateway) stays open.
# Before: positive probes (node and peers reach each other on 2380 and 5432,
# this box reaches all three on 22). After: this box reaches the node on 22
# first, then the same probes in both directions must fail (connect failure,
# not an ssh failure), this box reaches all three again, and both chains of
# the victim's table and the output chain of each peer's table must have dropped
# packets. Sets PEERS, PART_T and
# PART_EPOCH (taken right after the victim's table is in place), CNT_IN and
# CNT_OUT (the victim's) and DROPS_JSON ({node: {in, out}} for all three).
# IPv4 only (ip saddr/daddr): the lab nodes talk over IPv4 (nodes.sh, etcd_eps).
isolate_node() {
  local v=$1 n peers="" p vip c specs_closed=() specs_open=() ci co
  PEERS=()
  vip=$(node_ip "$v")
  for n in "${NODES[@]}"; do
    [ "$n" = "$v" ] && continue
    PEERS+=("$n"); p=$(node_ip "$n"); peers="$peers${peers:+, }$p"
    specs_closed+=("$v,$p,2380" "$v,$p,5432" "$n,$vip,2380" "$n,$vip,5432")
  done
  for n in "${NODES[@]}"; do specs_open+=("box,$(node_ip "$n"),22"); done
  run_probes open "${specs_closed[@]}" "${specs_open[@]}" || return 1
  fault_table_add "$v" <<NFT || return 1
table inet obenhub_fault {
  chain in {
    type filter hook input priority 0; policy accept;
    ip saddr { $peers } counter drop
  }
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr { $peers } counter drop
  }
}
NFT
  PART_T=$(now_ts); PART_EPOCH=$(date +%s)
  for n in "${PEERS[@]}"; do
    fault_table_add "$n" <<NFT || return 1
table inet obenhub_fault {
  chain in {
    type filter hook input priority 0; policy accept;
    ip saddr $vip counter drop
  }
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr $vip counter drop
  }
}
NFT
  done
  run_probes open "box,$vip,22" || return 1
  run_probes closed "${specs_closed[@]}" || return 1
  run_probes open "${specs_open[@]}" || return 1
  DROPS_JSON="{}"
  for n in "$v" "${PEERS[@]}"; do
    c=$(fault_counters "$n") || { FAILS+=("cannot read the nft counters on $n"); return 1; }
    ci=${c#in=}; ci=${ci%% *}; co=${c##*out=}
    # Every output chain must have dropped packets. The input chains are recorded
    # only: once all three tables are in place each side drops what it sends, so
    # an input chain counts just the moments between the adds (or, on a peer,
    # what a reset victim sends after its own table is gone).
    [ "${co:-0}" -gt 0 ] 2>/dev/null || { FAILS+=("nft counters on $n: out=$co, the output chain must have dropped packets"); return 1; }
    DROPS_JSON=$(jq -c --arg n "$n" --argjson i "$ci" --argjson o "$co" '. + {($n): {in: $i, out: $o}}' <<<"$DROPS_JSON")
    [ "$n" = "$v" ] && { CNT_IN=$ci; CNT_OUT=$co; }
  done
  log "partition verified: $v and ${PEERS[*]} cannot reach each other on 2380 and 5432 (drops $DROPS_JSON), the box reaches all three nodes"
}
# clear_fault_tables: delete the table on every node, retrying while a node is
# still booting. Used by revert only: the precondition (lab_precondition)
# already refuses a left-over table, so inject does not clear.
clear_fault_tables() {
  local n
  local rc=0
  # every node is tried even when one fails: a victim still booting must not
  # leave the peers' tables, and so the partition, in place
  for n in "${NODES[@]}"; do wait_until 180 "fault table cleared on $n" fault_table_del "$n" || rc=1; done
  return "$rc"
}
# drops_now: the nft drop counters of every node that still has the table, as
# JSON {node: {in, out}}; nodes without the table (a reset victim) or unreachable
# are left out. Read in revert, before the tables are deleted.
drops_now() {
  local n c ci co j="{}"
  for n in "${NODES[@]}"; do
    c=$(fault_counters "$n" 2>/dev/null) || continue
    ci=${c#in=}; ci=${ci%% *}; co=${c##*out=}
    [[ $ci =~ ^[0-9]+$ && $co =~ ^[0-9]+$ ]] || continue
    j=$(jq -c --arg n "$n" --argjson i "$ci" --argjson o "$co" '. + {($n): {in: $i, out: $o}}' <<<"$j")
  done
  printf '%s' "$j"
}

# --- poller (network-partition.sh, leader-killed.sh) -----------------------
# Globals: POLL_DIR, POLL_PIDS;
# poll_summary reads OLD (the old leader) and POLL_AFTER (epoch of the fault, optional).
POLL_DIR="" POLL_PIDS=()
# poll_node NODE PARENT: one sample line "epoch node t|f|down|err" per answer, the epoch
# taken when the answer arrived. down: ssh worked but psql did not answer (the node is
# not writable); err: ssh failed or timed out (unknown). Stops when PARENT is gone, so a
# killed scenario does not leave pollers behind.
poll_node() {
  local n=$1 parent=$2 r rc
  while kill -0 "$parent" 2>/dev/null; do
    r=$(timeout 4 ssh -n -o BatchMode=yes -o ConnectTimeout=2 "$n" "sudo $(printf '%q ' -u postgres psql -h /var/run/postgresql -X -v ON_ERROR_STOP=1 -At -c 'SELECT pg_is_in_recovery()')" 2>/dev/null)
    rc=$?
    case "$r" in t | f) ;; *) if [ "$rc" = 255 ] || [ "$rc" = 124 ]; then r=err; else r=down; fi ;; esac
    echo "$(date +%s.%N) $n $r" >>"$POLL_DIR/$n"
    sleep 0.5
  done
}
start_poll() {
  local n
  POLL_DIR=$(mktemp -d)
  for n in "${NODES[@]}"; do poll_node "$n" "$$" & POLL_PIDS+=("$!"); done
}
stop_poll() {
  local p
  for p in "${POLL_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  POLL_PIDS=()
}

# poll_summary: one JSON object from the per-node sample files. Dual primary =
# at some sample, two nodes whose newest sample (at most 3 s old) says writable.
# The 3 s validity errs towards a false dual primary (a node that demoted right
# after its last "f" still counts for up to 3 s); harmless here, where the
# writable gap is over 15 s, but not for a graceful handover. It can also miss
# one: an err or down sample replaces a node's last "f", so a writable node
# whose ssh fails stops counting. Blind windows
# count err samples only (ssh failed: unknown); down samples (psql refused) are
# evidence that the node is not writable.
# Additive fields for a fault after which the old leader itself may become
# writable again (set POLL_AFTER to the epoch of the fault): old_first_unwritable_after
# is the old leader's first sample after POLL_AFTER that is not writable (err, down
# or in recovery); old_last_writable_before_that and resumed_first_writable /
# resumed_node bound the longest interval without any writable sample that ends
# after POLL_AFTER (the old leader itself is the resumed node in the race it wins).
# All null when POLL_AFTER is unset. The fields above are unchanged.
poll_summary() {
  cat "$POLL_DIR"/* 2>/dev/null | LC_ALL=C sort -n | awk -v old="$OLD" -v after="${POLL_AFTER:-0}" '
    { t = $1; n = $2; v = $3; cnt[n]++; lastt[n] = t
      if (v == "err") { errc[n]++; if (!inerr[n]) { inerr[n] = 1; lgs[n] = (n in lg) ? lg[n] : t } }
      else { if (inerr[n]) { b = t - lgs[n]; if (b > blind[n]) blind[n] = b; inerr[n] = 0 } lg[n] = t }
      st[n] = v; stt[n] = t
      w = 0; for (k in st) if (st[k] == "f" && t - stt[k] <= 3) w++
      if (w >= 2) dual++
      if (n == old && v == "f") oldw = t
      if (n == old && v == "t" && oldw && !oldro) oldro = t
      if (n != old && v == "f" && !nw) { nw = t; nn = n }
      if (after > 0 && n == old && t > after && v != "f" && !gs) gs = t
      if (after > 0 && v == "f") { nf++; ft[nf] = t; fn[nf] = n }
      total++ }
    END {
      # the outage: the longest interval between two consecutive writable samples (any
      # node) that ends after POLL_AFTER. Writable samples only, so neither a transient
      # err sample of the old leader nor the order in which slow answers arrive moves it.
      for (i = 2; i <= nf; i++) if (ft[i] > after && ft[i] - ft[i - 1] > mg) { mg = ft[i] - ft[i - 1]; gl = ft[i - 1]; rs = ft[i]; rnode = fn[i] }
      for (n in cnt) if (inerr[n]) { b = lastt[n] - lgs[n]; if (b > blind[n]) blind[n] = b }
      printf "{\"samples\":%d,\"dual_samples\":%d,\"new_leader\":%s,\"old_last_writable\":%s,\"old_first_readonly\":%s,\"new_first_writable\":%s,\"old_first_unwritable_after\":%s,\"old_last_writable_before_that\":%s,\"resumed_first_writable\":%s,\"resumed_node\":%s,\"nodes\":{", total, dual, (nn ? "\"" nn "\"" : "null"), (oldw ? oldw : "null"), (oldro ? oldro : "null"), (nw ? nw : "null"), (gs ? gs : "null"), (gl ? gl : "null"), (rs ? rs : "null"), (rs ? "\"" rnode "\"" : "null")
      c = 0; for (n in cnt) { printf "%s\"%s\":{\"samples\":%d,\"err\":%d,\"longest_blind_seconds\":%.1f}", (c++ ? "," : ""), n, cnt[n], errc[n], blind[n] }
      printf "}}\n" }'
}
