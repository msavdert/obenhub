#!/usr/bin/env bash
# Scenario slot-invalidated: create a physical slot on the primary that nothing consumes, push the current LSN past its restart_lsn by more than max_slot_wal_keep_size (read from pg_settings) with WAL segment switches, then CHECKPOINT so PostgreSQL removes the WAL and invalidates the slot (wal_status lost, invalidation_reason wal_removed). The inject starts only with enough time before the next timed checkpoint, and the active slots (standby1, app_sub) are kept close to the current LSN first, so no checkpoint can invalidate them. Expect PostgresReplicationSlotInvalidated for pg-primary. The slot is inactive and retains no WAL once invalidated, so PostgresPhysicalSlotInactive must not fire; any other alert is unexpected (PostgresCheckpointsRequested is the risk: WAL volume also requests checkpoints, so max_wal_size is raised for the inject and reset by revert; see extra.num_requested_delta).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresReplicationSlotInvalidated:pg-primary")
SLOT=obenhub_inval
BATCH=10   # WAL segment switches per psql call
# The slot stays inactive past PostgresPhysicalSlotInactive's 120 s + 1m after the
# detection, so the run shows that the invalidated slot does not raise it.
HOLD_AFTER_DETECT=200
GAP_MAX=24 # segments since the last checkpoint's redo; see inject
WAL_SIZE=4GB # max_wal_size during the inject, reset by revert
CATCHUP_MAX=180 # seconds for standby1 and app_sub to catch up after the switches
# generation (about 15 s in the lab) plus the catch-up wait plus a margin
CKPT_MARGIN=$((CATCHUP_MAX + 60))

slot_field() { psql_p -c "SELECT coalesce($2::text, 'NULL') FROM pg_replication_slots WHERE slot_name = '$1'"; }
# the standby (flush position and its slot) and both logical positions are within $LAG_MAX bytes of the current LSN
actives_close() {
  local n
  n=$(psql_p -c "SELECT count(*) FROM pg_stat_replication r, pg_replication_slots p, pg_replication_slots s
    WHERE r.application_name <> '$SUBSCRIPTION' AND pg_wal_lsn_diff(pg_current_wal_lsn(), r.flush_lsn) < $LAG_MAX
      AND p.active_pid = r.pid AND pg_wal_lsn_diff(pg_current_wal_lsn(), p.restart_lsn) < $LAG_MAX
      AND r.state = 'streaming' AND s.slot_name = '$SUBSCRIPTION'
      AND pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) < $LAG_MAX
      AND pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn) < $LAG_MAX") || return 1
  [ "$n" = 1 ]
}
slot_lost() {
  [ "$(psql_p -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$SLOT' AND wal_status = 'lost' AND invalidation_reason = 'wal_removed'")" = 1 ]
}
redo_gap() { psql_p -c "SELECT floor(pg_wal_lsn_diff(pg_current_wal_lsn(), redo_lsn) / $1)::int FROM pg_control_checkpoint()"; }
redo_gap_small() { [ "$(redo_gap "$1")" -lt "$GAP_MAX" ] 2>/dev/null; }
# seconds until checkpoint_timeout has passed since the last checkpoint's start;
# negative once it is due (a timed checkpoint is skipped when nothing was written)
timed_ckpt_left() { psql_p -c "SELECT floor(extract(epoch FROM current_setting('checkpoint_timeout')::interval) - extract(epoch FROM now() - checkpoint_time))::int FROM pg_control_checkpoint()"; }
is_int() { case $1 in ''|-|*[!0-9-]*|?*-*) return 1 ;; esac; }
ckpt_left() { local l; l=$(timed_ckpt_left) || return 1; is_int "$l" || return 1; echo "$l"; }
# far enough, else one WAL record so that the next tick is not skipped as idle
timed_ckpt_far() {
  local l
  l=$(ckpt_left) || return 1
  [ "$l" -ge "$CKPT_MARGIN" ] && return 0
  psql_p -c "SELECT pg_logical_emit_message(false, 'obenhub', 'x')" >/dev/null
  return 1
}
wal_size_set() { [ "$(psql_p -c "SHOW max_wal_size")" = "$WAL_SIZE" ]; }
# no max_wal_size in postgresql.auto.conf, i.e. no ALTER SYSTEM value in effect
# (count, not a LIKE result: sourcefile is NULL for a default or command-line value)
wal_size_reset() { [ "$(psql_p -c "SELECT count(*) FROM pg_settings WHERE name = 'max_wal_size' AND sourcefile LIKE '%postgresql.auto.conf'")" = 0 ]; }
nreq() { psql_p -c "SELECT num_requested FROM pg_stat_checkpointer"; }
walused() { docker exec "$PRIMARY" sh -c 'du -sb "$PGDATA/pg_wal" 2>/dev/null || du -sb /var/lib/postgresql/data/pg_wal' | awk '{print $1}'; }

inject() {
  local n gap0 gap left0 left keep_mb seg target restart diff switches=0 req0 req1 wal0 wal1 st1 st2 st3 reason
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || return 1
  keep_mb=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size'") || return 1
  seg=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'wal_segment_size'") || return 1
  [ "$keep_mb" -gt 0 ] 2>/dev/null || { FAILS+=("max_slot_wal_keep_size is $keep_mb (unlimited or unreadable): no invalidation possible"); return 1; }
  # Two segments past the limit are enough. WAL volume also requests
  # checkpoints (about every max_wal_size / (1 + checkpoint_completion_target)
  # since the last redo, from the docs), and PostgresCheckpointsRequested fires on more
  # than 3 requested in 5 minutes. With the lab's 1GB, 67 switches counted 3
  # requested from a gap of 0 and 4 in another run (2026-11-10), so max_wal_size
  # is raised to WAL_SIZE for the inject: then 67 segments plus a gap under
  # GAP_MAX stay below one WAL-volume checkpoint and only the CHECKPOINT below
  # counts. A larger gap waits for the next timed checkpoint (not requested).
  target=$((keep_mb * 1024 * 1024 + 2 * seg))
  LAG_MAX=$((8 * seg))
  gap0=$(redo_gap "$seg") || return 1
  if [ "$gap0" -ge "$GAP_MAX" ]; then
    log "$gap0 segments since the last redo; waiting for the next timed checkpoint"
    wait_until 330 "fewer than $GAP_MAX segments since the last redo" redo_gap_small "$seg" \
      || { FAILS+=("still $(redo_gap "$seg") segments since the last redo"); return 1; }
  fi
  # A timed checkpoint during the generation or the catch-up wait below removes
  # the WAL before app_sub's restart_lsn has moved and invalidates app_sub too
  # (2026-11-12: one started 4 s after the switches). Start only with
  # CKPT_MARGIN seconds left before the next one, else wait for it to pass.
  # An idle primary skips timed checkpoints and checkpoint_time stays old, so
  # every poll writes one WAL record; the next tick then comes within
  # checkpoint_timeout (lab check 2026-11-12: after two idle hours one started
  # 48 s after a record). The limit allows for a second round when a poll
  # missed the window after the first one.
  left0=$(ckpt_left) || { FAILS+=("seconds to the next timed checkpoint unreadable: '$(timed_ckpt_left)'"); return 1; }
  if [ "$left0" -lt "$CKPT_MARGIN" ]; then
    log "${left0}s to the next timed checkpoint; waiting for it to pass"
    wait_until 660 "at least ${CKPT_MARGIN}s to the next timed checkpoint" timed_ckpt_far \
      || { FAILS+=("only $(timed_ckpt_left)s to the next timed checkpoint"); return 1; }
  fi
  left=$(ckpt_left) || { FAILS+=("seconds to the next timed checkpoint unreadable: '$(timed_ckpt_left)'"); return 1; }
  gap=$(redo_gap "$seg") || return 1
  wal_size_reset || { FAILS+=("max_wal_size already set by ALTER SYSTEM (a revert that did not finish?): $(psql_p -c "SHOW max_wal_size")"); return 1; }
  psql_p -c "ALTER SYSTEM SET max_wal_size = '$WAL_SIZE'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  wait_until 30 "max_wal_size $WAL_SIZE in effect" wal_size_set \
    || { FAILS+=("max_wal_size not raised: $(psql_p -c "SHOW max_wal_size")"); return 1; }
  req0=$(nreq) || return 1
  wal0=$(walused)
  psql_p -c "SELECT slot_name FROM pg_create_physical_replication_slot('$SLOT', true)" >/dev/null || return 1
  restart=$(slot_field "$SLOT" restart_lsn) || return 1
  log "max_slot_wal_keep_size ${keep_mb} MB, segment ${seg} B, restart_lsn $restart, generating >= $target bytes"
  diff=0
  while [ "${diff%.*}" -le "$target" ]; do
    # each switch advances about one segment; never overshoot by a batch
    n=$(( (target - ${diff%.*} + seg - 1) / seg )); [ "$n" -le "$BATCH" ] || n=$BATCH; [ "$n" -ge 1 ] || n=1
    psql_p -c "DO \$\$ BEGIN FOR i IN 1..$n LOOP PERFORM pg_logical_emit_message(false, 'obenhub', 'x'); PERFORM pg_switch_wal(); END LOOP; END \$\$" >/dev/null || return 1
    switches=$((switches + n))
    diff=$(psql_p -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '$restart')::bigint") || return 1
    [ "$switches" -le 400 ] || { FAILS+=("generated $diff bytes in $switches switches, target $target not reached"); return 1; }
  done
  wal1=$(walused)
  log "generated $diff bytes in $switches switches; waiting for standby1 and app_sub to catch up"
  wait_until "$CATCHUP_MAX" "standby and app_sub within 8 segments of the current LSN" actives_close \
    || { FAILS+=("active slots did not catch up before the checkpoint"); return 1; }
  psql_p -c "CHECKPOINT" >/dev/null || return 1
  # No second CHECKPOINT if the slot is not lost yet: every requested one
  # counts toward PostgresCheckpointsRequested (see above).
  wait_until 10 "$SLOT invalidated" slot_lost \
    || { FAILS+=("$SLOT not invalidated after checkpoint: $(psql_p -c "SELECT wal_status, coalesce(invalidation_reason,'NULL') FROM pg_replication_slots WHERE slot_name = '$SLOT'")"); return 1; }
  st1=$(slot_field standby1 wal_status); st2=$(slot_field "$SUBSCRIPTION" wal_status)
  st3=$(slot_field standby1 invalidation_reason); reason=$(slot_field "$SUBSCRIPTION" invalidation_reason)
  log "after checkpoint: standby1 $st1 ($st3), $SUBSCRIPTION $st2 ($reason)"
  [ "$st3" = NULL ] && [ "$reason" = NULL ] && [ "$st1" != lost ] && [ "$st2" != lost ] \
    || { FAILS+=("an active slot was invalidated: standby1 $st1/$st3, $SUBSCRIPTION $st2/$reason"); return 1; }
  req1=$(nreq)
  EXTRA_JSON=$(jq -n -c --argjson keep "$keep_mb" --argjson bytes "$diff" --argjson sw "$switches" \
    --arg ws "$(slot_field "$SLOT" wal_status)" --arg ir "$(slot_field "$SLOT" invalidation_reason)" \
    --arg s1 "$st1" --arg s2 "$st2" --argjson r0 "$req0" --argjson r1 "$req1" \
    --argjson w0 "$wal0" --argjson w1 "$wal1" --argjson g0 "$gap0" --argjson g "$gap" --argjson tl0 "$left0" --argjson tl "$left" '
    {max_slot_wal_keep_size_mb: $keep, generated_bytes: $bytes, wal_switches: $sw,
     slot_wal_status: $ws, slot_invalidation_reason: $ir, standby1_wal_status: $s1, app_sub_wal_status: $s2,
     segments_since_redo_seen: $g0, segments_since_redo_at_start: $g, seconds_to_timed_checkpoint_seen: $tl0, seconds_to_timed_checkpoint_at_start: $tl, num_requested_delta: ($r1 - $r0), pg_wal_bytes_before: $w0, pg_wal_bytes_at_peak: $w1}')
}
revert() {
  local inactive
  # inactive age at the end of the hold: shows whether PostgresPhysicalSlotInactive
  # had something to exclude (the pack query coalesces a NULL to 0)
  inactive=$(psql_p -c "SELECT coalesce(extract(epoch FROM clock_timestamp() - inactive_since)::int::text, 'NULL') FROM pg_replication_slots WHERE slot_name = '$SLOT'")
  [ -n "${EXTRA_JSON:-}" ] && EXTRA_JSON=$(jq -c --arg i "${inactive:-absent}" '. + {slot_inactive_seconds_at_revert: $i}' <<<"$EXTRA_JSON")
  # the reset runs even when the drop fails: a 4GB max_wal_size left in
  # postgresql.auto.conf would skew every later scenario
  local rc=0
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || rc=1
  psql_p -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" >/dev/null || rc=1
  wait_until 30 "max_wal_size reset" wal_size_reset || rc=1
  return "$rc"
}
run_scenario slot-invalidated
