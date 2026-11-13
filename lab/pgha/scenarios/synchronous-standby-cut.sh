#!/usr/bin/env bash
# Scenario synchronous-standby-cut: Patroni synchronous_mode with synchronous_mode_strict on (set by this scenario, removed again in revert; the lab runs asynchronously otherwise), then the synchronous standby is cut off in two steps. Step 1: the standby is isolated from the two other nodes with isolate_node (lib.sh, as network-partition-replica); the question is whether Patroni picks the other replica as synchronous standby and for how long commits wait. Step 2, once that is known: the leader and the other replica drop tcp 5432 between them (table "inet obenhub_fault2", etcd stays reachable, so the leader keeps its key and there is no failover); now no standby can be synchronous and, in strict mode, commits wait until revert. Strict is part of the scenario because without it Patroni empties synchronous_standby_names after a loop and PostgresSynchronousStandbyMissing (which reads pg_stat_replication and that setting) has nothing to see; the non-strict behaviour is taken from the Patroni documentation, not run. A sampler on the leader records once per second synchronous_standby_names, the sync_state of every WAL sender and how long a transactional pg_logical_emit_message commit takes (the client gives up after 8 s; statement_timeout does not cut a commit wait, seen in the first run, so a wait shows as 8.0). Expect (derived from network-partition-replica and the pack, see the comments below) EtcdNoLeader and PostgresStandbyNotStreaming for the first standby, PostgresStandbyNotStreaming for the other, PostgresPhysicalSlotInactive for the leader, PostgresSynchronousStandbyMissing for the leader. Evidence: sampler summary, boot ids, leader and timeline unchanged, nft drop counters, Patroni config restored. Revert deletes both tables, removes the two keys with patronictl edit-config, and waits for a healthy cluster and a writing load.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Derived from the rules and network-partition-replica before the first run:
# - EtcdNoLeader:<first standby>, PostgresStandbyNotStreaming:<first standby>, PostgresPhysicalSlotInactive:<leader>: as in network-partition-replica (the leader's slot for the isolated standby has no consumer; the alert carries the leader's instance).
# - PostgresStandbyNotStreaming:<other standby>: step 2 drops its WAL receiver's connection; the node is in recovery and the leader is writable.
# - PostgresSynchronousStandbyMissing:<leader>: synchronous_standby_names stays set (strict) and pg_stat_replication has no sync row once the walsenders time out (wal_sender_timeout, default 60 s: assumption, the sampler shows it).
# - PatroniReplicaNotEligible for the first standby may fire (it lags while the other standby carries the writes); allowed, not waited for. Not expected: PatroniFailoverHappened, the target-absent alerts.
# - PostgresSnapshotHeldTooLong and PostgresBlockedSessions for the leader appeared in the first two runs (one each, not both in the same run): commits wait for the standby while their transactions still hold snapshots and row locks, so the load sessions queue behind them. Allowed, not waited for.
EXPECT=()
ALLOW=()
VICTIM="" OTHER="" LEADER0="" TL0=""
SYNC_ON=0 FAULT2=0
SAMP_DIR="" SAMP_PID=""
T_STEP2="" T_SWITCH="" REV_EPOCH=""
EXTRA_JSON=null
declare -A BOOT0=()

# sync_keys_removed: true only when patronictl show-config answered and lists no synchronous_* key
# (the keys this scenario sets are absent from the lab's dynamic configuration otherwise).
# A failing show-config is not "removed".
sync_keys_removed() { local c; c=$(ptl show-config) || return 1; ! grep -q '^synchronous_' <<<"$c"; }

# jq -e: no output exits 4, so wait_until keeps waiting until Patroni names a Sync Standby
sync_standby_member() { members | jq -er '[.[] | select(.Role == "Sync Standby")] | if length == 1 then .[0].Member else empty end'; }

# one sample per second on the leader: epoch|elapsed|synchronous_standby_names|app:state,app:state
# A commit that waits keeps its backend until the wait ends (the client's 8 s
# timeout does not cancel it), so the commit probe stops after MAX_WAITING
# waiting samples (elapsed "skipped" from then on) and a long
# HOLD_AFTER_DETECT cannot exhaust the connections.
MAX_WAITING=20
sampler() {
  local l=$1 parent=$2 t0 out el waiting=0 stmts
  while kill -0 "$parent" 2>/dev/null; do
    t0=$(date +%s.%N)
    stmts=("SELECT current_setting('synchronous_standby_names') || '|' || coalesce((SELECT string_agg(application_name || ':' || sync_state, ',' ORDER BY application_name) FROM pg_stat_replication), '');")
    [ "$waiting" -lt "$MAX_WAITING" ] && stmts+=("SELECT pg_logical_emit_message(true, 'obenhub', 'probe') IS NOT NULL;")
    out=$(printf '%s\n' "${stmts[@]}" \
      | timeout 8 ssh "${SSH_OPTS[@]}" "$l" "sudo $(printf '%q ' -u postgres psql -h /var/run/postgresql -X -q -At -f -)" 2>/dev/null | sed -n 1p | tr -d ' ')
    el=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')
    if [ "${#stmts[@]}" -eq 1 ]; then el=skipped; elif awk -v e="$el" 'BEGIN{exit !(e > 1.8)}'; then waiting=$((waiting + 1)); fi
    echo "$t0|$el|${out:-unreadable}" >>"$SAMP_DIR/s"
    sleep 1
  done
}
# sync_listed: true when the newest sample lists member $1 with state sync
sync_listed() { tail -n 1 "$SAMP_DIR/s" 2>/dev/null | grep -Eq "[|,]$1:sync"; }

fault2_add() {
  local a=$1 b=$2 n
  for n in "$a" "$b"; do
    local peer; [ "$n" = "$a" ] && peer=$(node_ip "$b") || peer=$(node_ip "$a")
    fault_table_add "$n" <<NFT || return 1
table inet obenhub_fault2 {
  chain in {
    type filter hook input priority 0; policy accept;
    ip saddr $peer tcp dport 5432 counter drop
    ip saddr $peer tcp sport 5432 counter drop
  }
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr $peer tcp dport 5432 counter drop
    ip daddr $peer tcp sport 5432 counter drop
  }
}
NFT
  done
}
fault2_del() {
  local n
  for n in "${NODES[@]}"; do
    wait_until 120 "second fault table cleared on $n" rn "$n" sh -c 'nft list table inet obenhub_fault2 >/dev/null 2>&1 && nft delete table inet obenhub_fault2; true' || return 1
  done
}
fault2_present() {
  local n
  for n in "${NODES[@]}"; do rn "$n" nft list tables | grep -qx 'table inet obenhub_fault2' && return 0; done
  return 1
}
fault2_drops() { # total packets dropped by obenhub_fault2 on the node
  rn "$1" nft list table inet obenhub_fault2 | awk '/counter packets/{for(i=1;i<=NF;i++) if($i=="packets") s+=$(i+1)} END{print s+0}'
}

inject() {
  local n b i
  fault2_present && { log "table obenhub_fault2 left over"; return 1; }
  LEADER0=$(leader_name); [ -n "$LEADER0" ] || return 1
  TL0=$(timeline)
  for n in "${NODES[@]}"; do b=$(boot_id_retry "$n") && BOOT0[$n]=$b || return 1; done
  log "enabling synchronous_mode and synchronous_mode_strict (leader $LEADER0, timeline $TL0)"
  SYNC_ON=1
  ptl edit-config --force -s synchronous_mode=true -s synchronous_mode_strict=true >/dev/null || return 1
  wait_until 120 "one Sync Standby in patronictl list" sync_standby_member || return 1
  VICTIM=$(sync_standby_member)
  OTHER=$(members | jq -r --arg v "$VICTIM" --arg l "$LEADER0" '[.[] | select(.Member != $v and .Member != $l)][0].Member')
  [ -n "$VICTIM" ] && [ -n "$OTHER" ] || return 1
  EXPECT=("EtcdNoLeader:$VICTIM" "PostgresStandbyNotStreaming:$VICTIM" "PostgresStandbyNotStreaming:$OTHER" "PostgresPhysicalSlotInactive:$LEADER0" "PostgresSynchronousStandbyMissing:$LEADER0")
  ALLOW=("PatroniReplicaNotEligible:$VICTIM" "PatroniReplicaNotEligible:$OTHER" "PostgresSnapshotHeldTooLong:$LEADER0" "PostgresBlockedSessions:$LEADER0")
  SAMP_DIR=$(mktemp -d)
  sampler "$LEADER0" "$$" & SAMP_PID=$!
  wait_until 30 "sampler sees $VICTIM as sync" sync_listed "$VICTIM" || return 1
  log "step 1: isolating the synchronous standby $VICTIM (other replica $OTHER)"
  isolate_node "$VICTIM" || return 1
  for i in $(seq 1 60); do sync_listed "$OTHER" && { T_SWITCH=$(date +%s.%N); break; }; sleep 3; done
  if [ -n "$T_SWITCH" ]; then log "step 1: $OTHER is listed as sync after $(awk -v a="$PART_EPOCH" -v b="$T_SWITCH" 'BEGIN{printf "%.0f", b-a}')s"; else log "step 1: $OTHER was not listed as sync within 180 s"; fi
  log "step 2: dropping tcp 5432 between the leader $LEADER0 and $OTHER"
  T_STEP2=$(date +%s.%N)
  FAULT2=1
  fault2_add "$LEADER0" "$OTHER"
}

revert() {
  local ok=0
  [ -n "$VICTIM" ] && DROPS_REVERT=$(drops_now)
  if [ "$FAULT2" = 1 ]; then F2_LEADER=$(fault2_drops "$LEADER0" 2>/dev/null); F2_OTHER=$(fault2_drops "$OTHER" 2>/dev/null); fi
  REV_EPOCH=$(date +%s.%N)
  fault2_del || ok=1
  clear_fault_tables || ok=1
  if [ "$SYNC_ON" = 1 ]; then
    ptl edit-config --force -s synchronous_mode=null -s synchronous_mode_strict=null >/dev/null || ok=1
  fi
  wait_until 300 "cluster healthy" cluster_healthy || ok=1
  wait_until 120 "synchronous_standby_names empty on the leader" sync_names_empty || ok=1
  wait_until 150 "load unit writing again" load_running || ok=1
  [ -n "$SAMP_PID" ] && { sleep 2; kill "$SAMP_PID" 2>/dev/null; wait "$SAMP_PID" 2>/dev/null; SAMP_PID=""; }
  return "$ok"
}
sync_names_empty() { [ -z "$(psql_n "$(leader_name)" -c "SHOW synchronous_standby_names")" ]; }

extra_checks() {
  local n b rebooted=() unknown=() leader1 tl1 summ
  for n in "${NODES[@]}"; do
    b=$(boot_id_retry "$n") || { unknown+=("$n"); continue; }
    [ "$b" = "${BOOT0[$n]}" ] || { rebooted+=("$n"); FAILS+=("$n rebooted"); }
  done
  [ "${#unknown[@]}" -eq 0 ] || FAILS+=("boot id unreadable on: ${unknown[*]}")
  leader1=$(leader_name); tl1=$(timeline)
  [ "$leader1" = "$LEADER0" ] || FAILS+=("leader changed from $LEADER0 to ${leader1:-none}")
  [ "${tl1:-0}" = "${TL0:-0}" ] || FAILS+=("timeline changed from $TL0 to ${tl1:-?}")
  sync_keys_removed || FAILS+=("synchronous_* keys still in the Patroni dynamic configuration, or patronictl show-config failed")
  [ -n "$T_SWITCH" ] || FAILS+=("the other replica $OTHER never became sync standby within 180 s of the cut")
  # seconds are relative to the start of step 1 (PART_EPOCH); a sample with elapsed over 1.8 s is a commit that waited
  # (the client gives up after 8 s, so 8.0 means "still waiting"; statement_timeout does not cut a commit wait)
  summ=$(awk -F'|' -v part="${PART_EPOCH:-0}" -v st2="${T_STEP2:-0}" -v rev="${REV_EPOCH:-0}" -v other="$OTHER" -v victim="$VICTIM" '
    $1 >= part && part > 0 {
      n++; gsub(/"/, "", $3)
      probed = ($2 != "skipped"); blocked = (probed && $2 + 0 > 1.8 && $3 != "unreadable")
      if ($3 == "unreadable") u++
      if (blocked) { b++; if (!bf) bf = $1 }
      else if (probed && bf && !fc) fc = $1
      if (index($4, other ":sync") && !os) os = $1
      if ($1 < st2 && index($4, victim ":sync")) vs = $1
      if ($1 >= st2 && $1 < rev && $4 !~ /:sync|:quorum/ && !ns) ns = $1
      if ($1 >= st2 && $1 < rev && $3 == "*" && !ss) ss = $1
      if ($1 >= st2 && $1 < rev) { last_names = $3; last_states = $4; if (probed && !blocked) nb++ }
    }
    function f(x) { return x ? sprintf("%.1f", x - part) : "null" }
    END { printf "{\"samples\":%d,\"unreadable\":%d,\"blocked_samples\":%d,\"first_blocked_s\":%s,\"first_unblocked_after_that_s\":%s,\"victim_last_sync_s\":%s,\"other_first_sync_s\":%s,\"no_sync_row_from_s\":%s,\"names_star_from_s\":%s,\"unblocked_samples_in_step2\":%d,\"names_before_revert\":\"%s\",\"states_before_revert\":\"%s\"}\n", n, u, b, f(bf), f(fc), f(vs), f(os), f(ns), f(ss), nb, last_names, last_states }' "$SAMP_DIR/s" 2>/dev/null)
  [ -n "$summ" ] || summ=null
  jq -e '.samples > 0' <<<"$summ" >/dev/null 2>&1 || FAILS+=("the sampler recorded no samples after the cut")
  jq -e '.blocked_samples > 0' <<<"$summ" >/dev/null 2>&1 || FAILS+=("no commit waited for the synchronous standby (zero blocked samples): the fault did not bite or the probe did not work")
  EXTRA_JSON=$(jq -n -c --argjson s "$summ" --arg v "$VICTIM" --arg o "$OTHER" --arg l0 "$LEADER0" --arg l1 "$leader1" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" \
    --arg part "${PART_T:-}" --arg pe "${PART_EPOCH:-}" --arg t2 "${T_STEP2:-}" --arg ts "${T_SWITCH:-}" --arg rev "${REV_EPOCH:-}" \
    --argjson drops "${DROPS_JSON:-null}" --argjson drev "${DROPS_REVERT:-null}" --arg f2l "${F2_LEADER:-}" --arg f2o "${F2_OTHER:-}" \
    --arg reb "${rebooted[*]:-}" \
    '{first_sync_standby: $v, other_replica: $o, partition_start: $part, partition_epoch: $pe, step2_epoch: $t2, other_listed_sync_epoch: $ts, revert_epoch: $rev,
      nft_drops: $drops, nft_drops_at_revert: $drev, fault2_drops_leader: $f2l, fault2_drops_other: $f2o,
      leader_before: $l0, leader_after: $l1, timeline_before: $tl0, timeline_after: $tl1,
      rebooted_nodes: ($reb | split(" ") | map(select(length>0))), sampler: $s}')
  log "extra: $EXTRA_JSON"
  if [ -n "${SYNC_SAMPLES_KEEP:-}" ]; then mkdir -p "$SYNC_SAMPLES_KEEP" && cp "$SAMP_DIR/s" "$SYNC_SAMPLES_KEEP/samples.txt"; fi
}
run_scenario synchronous-standby-cut
