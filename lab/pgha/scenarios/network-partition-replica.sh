#!/usr/bin/env bash
# Scenario network-partition-replica: isolate the first replica from the two other nodes (the leader and the other replica), both directions, with the nftables table "inet obenhub_fault" (isolate_node in lib.sh, which also proves the partition before and after, with probes in both directions and the drop counters of both chains) on that replica, and the same table on the leader and the other replica dropping packets from and to it (so the isolation would survive a reset of the replica). ssh from this box and OTLP to the gateway stay open. Same fault as network-partition on the leader, which resets the leader's VM; here no reset is expected. ASSUMPTION: the hardware watchdog is armed on the leader only; the boot ids of one run are consistent with it, they do not verify it. The replica's etcd is a one-member minority and its WAL receiver loses the primary; the leader keeps its quorum with the third node, so there is no failover. Expect EtcdNoLeader, StandbyNotStreaming and PatroniReplicaNotEligible for that replica, PhysicalSlotInactive for its slot on the leader, and nothing else (derived in the comment below; the last two were added after runs). Evidence: boot ids of all nodes, leader and timeline unchanged, nft drop counters. Revert deletes the tables and waits for a healthy cluster.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Derived from the rules before the first run (lab/packs/etcd/rules.yml, lab/packs/postgresql/rules.yml):
# - EtcdNoLeader:<replica>. etcd_server_has_leader == 0 for 1m. A follower that gets no heartbeats becomes a pre-candidate and reports no leader (the etcd journal of the first leader attempt shows the pre-vote rounds; not re-read for this scenario). The series is scraped by the replica's own Collector, whose path to the gateway is open.
# - StandbyNotStreaming:<replica>. postgresql.wal_receiver.streaming == 0 and the node in recovery and some node not in recovery (the leader), for 1m. The replica's WAL receiver cannot reach the leader.
# - PatroniReplicaNotEligible:<replica>. Listed as possible in the first derivation, added after the first run (VictoriaLogs, 2026-11-10 19:14:26 firing, "20.14MiB behind the leader", threshold 16 MiB, for 1m; resolved 19:15:26 at 34MiB; not in runs.jsonl): the leader keeps writing under the pgbench load while the isolated replica receives nothing.
# - PhysicalSlotInactive:<leader>. Added after the second attempt (VictoriaLogs, 2026-11-10 19:21:28, the leader's slot pgha_1 on pgha-3 inactive for 3m 2s at firing; not in runs.jsonl): the leader's physical slot for the isolated replica has no consumer; the rule needs inactive_seconds > 120 plus for 1m. The first attempt was reverted at about 3 minutes (VictoriaLogs/VictoriaMetrics, 2026-11-10 19:11 to 19:15) before it could fire. The alert is labelled with the leader's instance, not the replica's.
# Not expected: PatroniFailoverHappened (the leader keeps its key through the two reachable etcd members), the target-absent alerts (local scrapes).
EXPECT=()
VICTIM="" LEADER0="" TL0=""
EXTRA_JSON=null
declare -A BOOT0=()

inject() {
  local n b
  VICTIM=$(first_replica)
  LEADER0=$(leader_name)
  [ -n "$VICTIM" ] && [ -n "$LEADER0" ] || return 1
  TL0=$(timeline)
  for n in "${NODES[@]}"; do b=$(boot_id_retry "$n") && BOOT0[$n]=$b || return 1; done
  EXPECT=("EtcdNoLeader:$VICTIM" "StandbyNotStreaming:$VICTIM" "PatroniReplicaNotEligible:$VICTIM" "PhysicalSlotInactive:$LEADER0")
  log "partitioning replica $VICTIM (leader $LEADER0, timeline $TL0) from the other two nodes"
  isolate_node "$VICTIM"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  DROPS_REVERT=$(drops_now)
  clear_fault_tables || return 1
  wait_until 300 "cluster healthy" cluster_healthy
}
extra_checks() {
  local n b rebooted=() unknown=() leader1 tl1
  for n in "${NODES[@]}"; do
    b=$(boot_id_retry "$n") || { unknown+=("$n"); continue; }
    [ "$b" = "${BOOT0[$n]}" ] || { rebooted+=("$n"); FAILS+=("$n rebooted"); }
  done
  [ "${#unknown[@]}" -eq 0 ] || FAILS+=("boot id unreadable on: ${unknown[*]}")
  leader1=$(leader_name); tl1=$(timeline)
  [ "$leader1" = "$LEADER0" ] || FAILS+=("leader changed from $LEADER0 to ${leader1:-none}")
  [ "${tl1:-0}" = "${TL0:-0}" ] || FAILS+=("timeline changed from $TL0 to ${tl1:-?}")
  EXTRA_JSON=$(jq -n -c --arg v "$VICTIM" --arg l0 "$LEADER0" --arg l1 "$leader1" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" \
    --arg reb "${rebooted[*]:-}" --arg unk "${unknown[*]:-}" --arg part "${PART_T:-}" --argjson drops "${DROPS_JSON:-null}" --argjson drev "${DROPS_REVERT:-null}" \
    '{isolated_replica: $v, partition_start: $part, nft_drops: $drops, nft_drops_at_revert: $drev, leader_before: $l0, leader_after: $l1, timeline_before: $tl0, timeline_after: $tl1,
      rebooted_nodes: ($reb | split(" ") | map(select(length>0))), boot_id_unknown_nodes: ($unk | split(" ") | map(select(length>0)))}')
  log "extra: $EXTRA_JSON"
}
run_scenario network-partition-replica
