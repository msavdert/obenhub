#!/usr/bin/env bash
# Scenario slot-near-loss: create a physical slot on the primary that nothing consumes and write WAL at about 1 MiB/s for 7 minutes (a background psql \watch of pg_logical_emit_message of 1 MB a second, one transaction each, so the WAL rate is steady and not a burst), up to 420 MiB in all. max_slot_wal_keep_size = 1GB in lab/slice1/compose.yaml is read from pg_settings, so the slot's safe_wal_size starts near 1 GiB and falls with the writes; at 1 MiB/s the projected time to loss is about 12 to 17 minutes, under the alert's 1 h default. The slot never gets near lost and never retains the 512 MiB of PostgresReplicationSlotRetainingWAL: after_detect fails the run unless the slot is still reserved or extended, safe_wal_size is above zero and retained WAL is below 512 MiB, so the alert comes well before the slot is invalidated. Expect PostgresReplicationSlotNearLoss for pg-primary, plus PostgresPhysicalSlotInactive for pg-primary (the slot is inactive for as long as the fault lasts, over the 120 s lab limit plus 1m), so it is expected and the run waits for both. Any other alert is unexpected. WAL volume also requests checkpoints, so max_wal_size is raised to 4GB for the inject and reset by revert, and the periodic pgBackRest backups are paused, as in slot-retaining-wal. Revert stops the writer, drops the slot, resets max_wal_size and runs one CHECKPOINT.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresReplicationSlotNearLoss:pg-primary" "PostgresPhysicalSlotInactive:pg-primary")
SLOT=obenhub_nearloss
WRITER=obenhub_nearloss_writer   # application_name of the background writer, so that revert can end it
SECONDS_WRITING=420              # about 1 MiB a second, 420 MiB at most: under the 512 MiB of PostgresReplicationSlotRetainingWAL
MIN_KEEP_MB=1024                 # the guard must be at least this: the time to loss stays above the writes at 1 MiB/s
WAL_SIZE=4GB                     # max_wal_size during the inject, reset by revert
KEEP_MB="" STATUS_AT_DETECT="" SAFE_AT_DETECT="" RETAINED_AT_DETECT="" REQ0="" REQ1="" WAL0="" WAL2=""

nreq() { psql_p -c "SELECT num_requested FROM pg_stat_checkpointer"; }
walused() { docker exec "$PRIMARY" sh -c 'du -sb "$PGDATA/pg_wal" 2>/dev/null || du -sb /var/lib/postgresql/data/pg_wal' | awk '{print $1}'; }
wal_size_set() { [ "$(psql_p -c "SHOW max_wal_size")" = "$WAL_SIZE" ]; }
# no ALTER SYSTEM value for max_wal_size in effect (count: sourcefile is NULL for a default)
wal_size_reset() { [ "$(psql_p -c "SELECT count(*) FROM pg_settings WHERE name = 'max_wal_size' AND sourcefile LIKE '%postgresql.auto.conf'")" = 0 ]; }
writer_running() { [ "$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$WRITER'")" -ge 1 ]; }
stop_writer() { psql_p -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$WRITER'" >/dev/null; }

inject() {
  local seg
  pause_backups || { FAILS+=("could not pause the pgBackRest backups"); return 1; }
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || return 1
  KEEP_MB=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size'") || return 1
  seg=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'wal_segment_size'") || return 1
  [ "$KEEP_MB" -ge "$MIN_KEEP_MB" ] 2>/dev/null \
    || { FAILS+=("max_slot_wal_keep_size is $KEEP_MB MB (unlimited, unreadable or under $MIN_KEEP_MB): no finite safe_wal_size to project from"); return 1; }
  wal_size_reset || { FAILS+=("max_wal_size already set by ALTER SYSTEM (a revert that did not finish?): $(psql_p -c "SHOW max_wal_size")"); return 1; }
  psql_p -c "ALTER SYSTEM SET max_wal_size = '$WAL_SIZE'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  wait_until 30 "max_wal_size $WAL_SIZE in effect" wal_size_set \
    || { FAILS+=("max_wal_size not raised: $(psql_p -c "SHOW max_wal_size")"); return 1; }
  REQ0=$(nreq) || return 1
  WAL0=$(walused)
  psql_p -c "SELECT slot_name FROM pg_create_physical_replication_slot('$SLOT', true)" >/dev/null || return 1
  # the writer is detached: the inject returns at once and the detection phase runs while WAL is written
  # one statement a second through \watch, not one DO block: a block is one transaction, and its
  # snapshot held for 7 minutes would raise PostgresSnapshotHeldTooLong (first run, 2026-11-27)
  docker exec -d -e PGAPPNAME="$WRITER" "$PRIMARY" sh -c "printf '%s\n' \"SELECT pg_logical_emit_message(false, 'obenhub', repeat('x', 1000000)) \\\\watch i=1 c=$SECONDS_WRITING\" | psql -U postgres -X -q -o /dev/null" \
    || { FAILS+=("could not start the WAL writer"); return 1; }
  wait_until 30 "the WAL writer is running" writer_running || { FAILS+=("the WAL writer did not start"); return 1; }
  log "slot $SLOT created, max_slot_wal_keep_size ${KEEP_MB} MB (segment ${seg} B), writing about 1 MiB/s for ${SECONDS_WRITING} s"
}
after_detect() {
  STATUS_AT_DETECT=$(psql_p -c "SELECT wal_status FROM pg_replication_slots WHERE slot_name = '$SLOT'") || STATUS_AT_DETECT=""
  SAFE_AT_DETECT=$(psql_p -c "SELECT coalesce(safe_wal_size::text, '') FROM pg_replication_slots WHERE slot_name = '$SLOT'") || SAFE_AT_DETECT=""
  RETAINED_AT_DETECT=$(psql_p -c "SELECT (pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1048576)::bigint FROM pg_replication_slots WHERE slot_name = '$SLOT'") || RETAINED_AT_DETECT=""
  log "slot at detection: wal_status $STATUS_AT_DETECT, safe_wal_size $SAFE_AT_DETECT, retained ${RETAINED_AT_DETECT} MiB"
  case "$STATUS_AT_DETECT" in
    reserved | extended) ;;
    *) FAILS+=("slot not reserved or extended at detection: '$STATUS_AT_DETECT'") ;;
  esac
  [[ "$SAFE_AT_DETECT" =~ ^[0-9]+$ ]] && [ "$SAFE_AT_DETECT" -gt 0 ] \
    || FAILS+=("safe_wal_size at detection is not above zero: '$SAFE_AT_DETECT'")
  [[ "$RETAINED_AT_DETECT" =~ ^[0-9]+$ ]] && [ "$RETAINED_AT_DETECT" -lt 512 ] \
    || FAILS+=("retained WAL at detection is not under 512 MiB: '$RETAINED_AT_DETECT'")
}
revert() {
  local rc=0
  stop_writer || rc=1
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || rc=1
  # the reset runs even when the drop fails: a 4GB max_wal_size left in
  # postgresql.auto.conf would skew every later scenario
  psql_p -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" >/dev/null || rc=1
  wait_until 30 "max_wal_size reset" wal_size_reset || rc=1
  psql_p -c "CHECKPOINT" >/dev/null || rc=1
  WAL2=$(walused)
  REQ1=$(nreq)
  resume_backups || rc=1
  return "$rc"
}
extra_checks() {
  EXTRA_JSON=$(jq -n -c --argjson keep "${KEEP_MB:-null}" --arg st "$STATUS_AT_DETECT" --arg safe "$SAFE_AT_DETECT" --arg ret "$RETAINED_AT_DETECT" \
    --arg r0 "$REQ0" --arg r1 "$REQ1" --arg w0 "$WAL0" --arg w2 "$WAL2" '
    def n: if . == "" then null else tonumber end;
    {max_slot_wal_keep_size_mb: $keep, slot_wal_status_at_detection: ($st|if . == "" then null else . end),
     safe_wal_size_at_detection: ($safe|n), retained_mib_at_detection: ($ret|n),
     num_requested_delta: (if $r0 == "" or $r1 == "" then null else ($r1|tonumber) - ($r0|tonumber) end),
     pg_wal_bytes_before: ($w0|n), pg_wal_bytes_after_revert: ($w2|n)}')
  log "extra: $EXTRA_JSON"
}
run_scenario slot-near-loss
