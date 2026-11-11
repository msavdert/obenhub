#!/usr/bin/env bash
# Scenario network-partition: isolate the current Patroni leader from the two other nodes, both directions, with an nftables table "inet obenhub_fault" on the leader dropping packets from and to the two peer addresses, and the same table on each peer dropping packets from and to the leader (isolate_node in lib.sh; input and output hooks; ssh from this box and OTLP to the gateway stay open, so telemetry about the isolated node keeps arriving until it dies). The tables on the peers exist because the first version had the table on the leader only, and nftables rules do not survive a reset: in suite-3 (runs.jsonl, network-partition row of 2026-11-10 21:25, pass=false) the leader's reset ended the partition, the old leader (pgha-1) came back, won the leader race again (timeline 10 to 11, last writable sample after the reboot, no other node ever writable) and the run failed with "poller never saw a new writable leader"; in the earlier smoke runs the majority had promoted first, so the outcome was a race. A real partition survives a reboot of one side, so the peers' tables keep the old leader isolated until revert. The partition is proven before and after (probes in both directions, nft drop counters of both chains on all three nodes). First attempt, 2026-11-10 (VictoriaLogs, host.name pgha-1, not in runs.jsonl): the leader's VM was reset during Patroni's offline demotion; Patroni's last good loop was 18:47:50, the 18:48:00 loop spent about 10 s in etcd retries, "Demoting self (offline)" was logged at 18:48:10 and the new boot's kernel started at 18:48:23. Most likely cause: the hardware watchdog (mode required). HYPOTHESIS, not confirmed from Patroni source: with packets dropped silently every etcd call waits for its timeout, the HA loop overruns the watchdog timeout (Patroni sets it to ttl - safety_margin; here ttl 30, loop_wait 10, retry_timeout 10, so loop_wait + 2 * retry_timeout = ttl) and the demotion does not finish before the reset. quorum-lost, where connections are refused at once, demoted without a reset. Patroni timings are left as they are: this is the behaviour to document. The old leader is classified by boot id only: reset when its boot id differs from the one read before the fault; no reset when ssh answered with the unchanged boot id at least 90 s after the partition (90 s: well past ttl 30 and past the reset seen about 30 s after the partition in the first attempt). A failed ssh decides nothing. EXPECT follows: reset gives PatroniFailoverHappened and HostRebooted for the old leader; no reset gives PatroniFailoverHappened, and EtcdNoLeader and StandbyNotStreaming for the old leader are allowed, not expected, in both branches (the replica scenario shows they fire for an isolated running node, and after a reset the peers' tables keep the old leader isolated until revert). The no-reset branch has never run; nothing is asserted about PostgreSQL on the old leader after an offline demotion that finishes. One independent poller per node (a sample about every 0.9 s on a healthy node: 0.5 s sleep plus an ssh round trip, 4 s timeout; 127 samples in about 113 s in the smoke run) asks pg_is_in_recovery() from this box and runs from inject until the cluster is healthy again, so the pg_rewind rejoin is covered; a sample counts as writable for 3 s. Two nodes writable at once (dual primary) fails the run, as does a reboot of a node other than the old leader. The poller is summarised in revert, which runs on every path, together with the other evidence: err samples and the longest blind window (last good sample to next good sample) per node, new leader and its first writable time, the writable gap seen by the poller and by patroni_primary, boot ids, Patroni's "Demoting self" line and the new boot's first kernel line (VictoriaLogs), pg_rewind from the old leader's Patroni journal. Revert deletes the tables on all three nodes (retrying while the node boots) and waits for a healthy cluster.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# EXPECT is set in inject() from what the old leader does (see the header).
# - PatroniFailoverHappened: the new leader's timeline is above the one-hour maximum from 3 m ago; no "for".
# - HostRebooted:<old leader>: system.uptime < 300 on the old leader's host (lab/packs/host/rules.yml).
# Not expected: EtcdMemberAbsent and the target-absent alerts (scrapes are local to each node and their windows outlast the reset), EtcdInsufficientMembers (counts scrapes), PatroniNoWritablePrimary (for 90s), CollectorAbsent (absent window [2m] plus for 1m; the reset and restart stayed inside it in the first attempt and the smoke run).
EXPECT=()
ALLOW=()
OLD="" TL0="" STATE=""
EXTRA_JSON=null
FINALIZED=0
declare -A BOOT0=()

# classify: for wait_until, runs in this shell. Sets STATE to reset (boot id changed) or
# no_reset (ssh answered with the unchanged boot id at or after partition start + 90 s).
classify() {
  local b
  b=$(boot_id "$OLD") && [ -n "$b" ] || return 1
  if [ "$b" != "${BOOT0[$OLD]}" ]; then STATE=reset; return 0; fi
  if [ "$(date +%s)" -ge $((PART_EPOCH + 90)) ]; then STATE=no_reset; return 0; fi
  return 1
}

inject() {
  local n b
  OLD=$(leader_name)
  [ -n "$OLD" ] || return 1
  TL0=$(timeline)
  for n in "${NODES[@]}"; do b=$(boot_id_retry "$n") && BOOT0[$n]=$b || return 1; done
  start_poll
  log "partitioning leader $OLD (timeline $TL0) from the other two nodes"
  isolate_node "$OLD" || return 1
  wait_until 240 "old leader's boot id changed, or unchanged 90 s after the partition" classify || { FAILS+=("old leader $OLD not classified within 240 s"); return 1; }
  if [ "$STATE" = reset ]; then
    EXPECT=("PatroniFailoverHappened:" "HostRebooted:$OLD")
  else
    EXPECT=("PatroniFailoverHappened:")
  fi
  # the peers' tables keep the old leader isolated after its reset (or while it runs), so these may fire before the revert
  # (the replica scenario shows the order and times: EtcdNoLeader, StandbyNotStreaming,
  # PatroniReplicaNotEligible; PhysicalSlotInactive for the new leader is added in finalize)
  ALLOW=("EtcdNoLeader:$OLD" "StandbyNotStreaming:$OLD" "PatroniReplicaNotEligible:$OLD")
  log "old leader $OLD: $STATE; expecting ${EXPECT[*]}"
}

# first VictoriaLogs line of NODE after SINCE matching the filter words
first_line_time() { vl "host.name:=$1 _time:>$2 $3 | sort by (_time) | limit 1 | fields _time" | jq -r '._time // empty' | head -n1; }

have_boot_line() { [ -n "$(first_line_time "$OLD" "$T_INJECT" '"Linux version"')" ]; }

# finalize: stop the poller and build the evidence; runs once, from revert, on every path
finalize() {
  [ "$FINALIZED" = 0 ] || return 0
  FINALIZED=1
  stop_poll
  [ -n "$POLL_DIR" ] || return 0
  local nl n b summary='null' dual new_t gap since rw rewinds demote_t boot_t tl1 old_reb=null oth_reb=false unknown=() rb
  summary=$(poll_summary) || summary=null
  [ -n "$summary" ] || summary=null
  rm -rf "$POLL_DIR"; POLL_DIR=""
  # the new leader keeps a slot for the old leader that stays inactive while it is isolated
  nl=$(jq -r '.new_leader // empty' <<<"$summary" 2>/dev/null)
  [ -z "$nl" ] || ALLOW+=("PhysicalSlotInactive:$nl")
  dual=$(jq -r '.dual_samples // empty' <<<"$summary" 2>/dev/null)
  new_t=$(jq -r '.new_first_writable // empty' <<<"$summary" 2>/dev/null)
  if [ "$(jq -r '.samples // 0' <<<"$summary" 2>/dev/null)" -eq 0 ] 2>/dev/null || [ -z "$dual" ]; then
    FAILS+=("poller produced no samples"); summary=null
  else
    [ "$dual" = 0 ] || FAILS+=("two nodes writable at once in $dual samples: dual primary")
    [ -n "$new_t" ] || FAILS+=("poller never saw a new writable leader")
  fi
  for n in "${NODES[@]}"; do
    b=$(boot_id_retry "$n") || { unknown+=("$n"); continue; }
    if [ "$b" != "${BOOT0[$n]}" ]; then
      if [ "$n" = "$OLD" ]; then old_reb=true; else oth_reb=true; FAILS+=("$n rebooted"); fi
    elif [ "$n" = "$OLD" ]; then old_reb=false; fi
  done
  [ "${#unknown[@]}" -eq 0 ] || FAILS+=("boot id unreadable on: ${unknown[*]}")
  tl1=$(timeline)
  since=$(date -u -d "$T_INJECT" +%s)
  gap=$(primary_gap_seconds "$since" 2>/dev/null) || gap=null
  rw=$(rn "$OLD" sh -c "journalctl -u patroni --since @$since --no-pager | grep -ci 'running pg_rewind' || true" 2>/dev/null) || rw=""
  [[ $rw =~ ^[0-9]+$ ]] && rewinds=$rw || rewinds=null
  demote_t=$(first_line_time "$OLD" "$T_INJECT" '"Demoting self"' || true)
  boot_t=""
  if [ "$STATE" = reset ]; then wait_until 60 "new boot's kernel line in VictoriaLogs" have_boot_line; boot_t=$(first_line_time "$OLD" "$T_INJECT" '"Linux version"' || true); fi
  EXTRA_JSON=$(jq -n -c --arg old "$OLD" --arg state "$STATE" --argjson tl0 "${TL0:-0}" --argjson tl1 "${tl1:-0}" \
    --arg part "${PART_T:-}" --arg demote "$demote_t" --arg boot "$boot_t" --argjson gap "${gap:-null}" \
    --argjson poll "$summary" --argjson oldreb "$old_reb" --argjson othreb "$oth_reb" --argjson rewinds "$rewinds" \
    --argjson drops "${DROPS_JSON:-null}" --argjson drev "${DROPS_REVERT:-null}" '
    def nz: if . == "" then null else . end;
    {old_leader: $old, old_leader_state: ($state|nz), timeline_before: $tl0, timeline_after: $tl1,
     partition_start: ($part|nz), nft_drops: $drops, nft_drops_at_revert: $drev,
     patroni_demoting_self_line: ($demote|nz), new_boot_first_kernel_line: ($boot|nz),
     old_leader_rebooted: $oldreb, other_nodes_rebooted: $othreb,
     new_leader: $poll.new_leader,
     old_leader_last_writable_epoch: $poll.old_last_writable, old_leader_first_in_recovery_epoch: $poll.old_first_readonly,
     new_leader_first_writable_epoch: $poll.new_first_writable,
     seconds_without_writable_primary_poller: (if $poll != null and $poll.old_last_writable != null and $poll.new_first_writable != null then ($poll.new_first_writable - $poll.old_last_writable) else null end),
     poll_samples: $poll.samples, samples_with_two_writable: $poll.dual_samples, poll_nodes: $poll.nodes,
     primary_gap_seconds: $gap,
     pg_rewind_ran: (if $rewinds == null then null else $rewinds > 0 end), pg_rewind_journal_lines: $rewinds}')
  log "extra: $EXTRA_JSON"
}

revert() {
  local rc=0
  if [ -n "$OLD" ]; then
    DROPS_REVERT=$(drops_now)
    clear_fault_tables || rc=1
    wait_until 300 "cluster healthy" cluster_healthy || rc=1
  fi
  finalize
  return "$rc"
}
run_scenario network-partition
