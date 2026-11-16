#!/usr/bin/env bash
# Scenario slot-retaining-wal: create a physical slot on the primary that nothing consumes and push the current LSN 640 MiB past its restart_lsn with WAL segment switches (a pg_switch_wal advances one segment and writes no data pages, so it needs no table; the volume holds the WAL of the slot, max_slot_wal_keep_size = 1GB in lab/slice1/compose.yaml is the guard and is read from pg_settings: the run refuses to start without a limit above the target plus a margin). The alert threshold is 512 MiB (PostgresReplicationSlotRetainingWAL, lab/packs/postgresql/rules.yml), so the slot is still valid (reserved or extended) when it fires: after_detect fails the run otherwise. Expect PostgresReplicationSlotRetainingWAL for pg-primary, plus PostgresPhysicalSlotInactive for pg-primary: the slot is inactive for as long as the fault lasts (120 s plus a 1m hold, shorter than the 2m hold of the WAL alert from the moment the retention passes the threshold), so it necessarily fires and is expected, and the run waits for both. Any other alert is unexpected. WAL volume also requests checkpoints, and PostgresCheckpointsRequested fires on more than 3 requested in 5 minutes, so max_wal_size is raised to 4GB for the inject and reset by revert, and the periodic pgBackRest backups (each one a requested checkpoint) are paused as in slot-invalidated; see extra.num_requested_delta. Revert drops the slot, resets max_wal_size and runs one CHECKPOINT, which releases the WAL the slot held; the segment files stay in pg_wal as recycled future segments (trial 2026-11-16: 738 MB on disk before and after, 84 MB before the run, see extra.pg_wal_bytes_after_revert), reused by later writes.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresReplicationSlotRetainingWAL:pg-primary" "PostgresPhysicalSlotInactive:pg-primary")
SLOT=obenhub_retain
TARGET_MIB=640   # retained WAL to reach, above the 512 MiB alert threshold
MARGIN_MIB=256   # the guard must be at least this far above the target
BATCH=10         # WAL segment switches per psql call
WAL_SIZE=4GB     # max_wal_size during the inject, reset by revert
KEEP_MB="" RETAINED_MIB="" STATUS_AT_DETECT="" SWITCHES=0 REQ0="" REQ1="" WAL0="" WAL1="" WAL2=""

slot_retained() { psql_p -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint FROM pg_replication_slots WHERE slot_name = '$SLOT'"; }
nreq() { psql_p -c "SELECT num_requested FROM pg_stat_checkpointer"; }
walused() { docker exec "$PRIMARY" sh -c 'du -sb "$PGDATA/pg_wal" 2>/dev/null || du -sb /var/lib/postgresql/data/pg_wal' | awk '{print $1}'; }
wal_size_set() { [ "$(psql_p -c "SHOW max_wal_size")" = "$WAL_SIZE" ]; }
# no ALTER SYSTEM value for max_wal_size in effect (count: sourcefile is NULL for a default)
wal_size_reset() { [ "$(psql_p -c "SELECT count(*) FROM pg_settings WHERE name = 'max_wal_size' AND sourcefile LIKE '%postgresql.auto.conf'")" = 0 ]; }

inject() {
  local seg target retained n
  pause_backups || { FAILS+=("could not pause the pgBackRest backups"); return 1; }
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || return 1
  KEEP_MB=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size'") || return 1
  seg=$(psql_p -c "SELECT setting FROM pg_settings WHERE name = 'wal_segment_size'") || return 1
  [ "$KEEP_MB" -ge $((TARGET_MIB + MARGIN_MIB)) ] 2>/dev/null \
    || { FAILS+=("max_slot_wal_keep_size is $KEEP_MB MB (unlimited, unreadable or under ${TARGET_MIB}+${MARGIN_MIB}): refusing to fill the volume or to invalidate the slot"); return 1; }
  wal_size_reset || { FAILS+=("max_wal_size already set by ALTER SYSTEM (a revert that did not finish?): $(psql_p -c "SHOW max_wal_size")"); return 1; }
  psql_p -c "ALTER SYSTEM SET max_wal_size = '$WAL_SIZE'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
  wait_until 30 "max_wal_size $WAL_SIZE in effect" wal_size_set \
    || { FAILS+=("max_wal_size not raised: $(psql_p -c "SHOW max_wal_size")"); return 1; }
  REQ0=$(nreq) || return 1
  WAL0=$(walused)
  psql_p -c "SELECT slot_name FROM pg_create_physical_replication_slot('$SLOT', true)" >/dev/null || return 1
  target=$((TARGET_MIB * 1048576))
  retained=0
  while [ "$retained" -lt "$target" ]; do
    # each switch advances about one segment; never overshoot by a batch
    n=$(( (target - retained + seg - 1) / seg )); [ "$n" -le "$BATCH" ] || n=$BATCH; [ "$n" -ge 1 ] || n=1
    psql_p -c "DO \$\$ BEGIN FOR i IN 1..$n LOOP PERFORM pg_logical_emit_message(false, 'obenhub', 'x'); PERFORM pg_switch_wal(); END LOOP; END \$\$" >/dev/null || return 1
    SWITCHES=$((SWITCHES + n))
    retained=$(slot_retained) || return 1
    [[ "$retained" =~ ^[0-9]+$ ]] || { FAILS+=("slot $SLOT has no retained WAL figure ('$retained')"); return 1; }
    [ "$SWITCHES" -le 200 ] || { FAILS+=("$retained bytes retained after $SWITCHES switches, target $target not reached"); return 1; }
  done
  WAL1=$(walused)
  RETAINED_MIB=$((retained / 1048576))
  log "slot $SLOT retains $RETAINED_MIB MiB after $SWITCHES switches (max_slot_wal_keep_size ${KEEP_MB} MB)"
}
after_detect() {
  STATUS_AT_DETECT=$(psql_p -c "SELECT wal_status || ' retained_mib=' || (pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)/1048576)::bigint FROM pg_replication_slots WHERE slot_name = '$SLOT'") || STATUS_AT_DETECT=""
  log "slot at detection: $STATUS_AT_DETECT"
  case "$STATUS_AT_DETECT" in
    reserved*|extended*) ;;
    *) FAILS+=("slot not valid at detection: $STATUS_AT_DETECT") ;;
  esac
}
revert() {
  local rc=0
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || rc=1
  # the reset runs even when the drop fails: a 4GB max_wal_size left in
  # postgresql.auto.conf would skew every later scenario
  psql_p -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" >/dev/null || rc=1
  wait_until 30 "max_wal_size reset" wal_size_reset || rc=1
  # the checkpoint releases the WAL the slot held (the files are recycled, not removed)
  psql_p -c "CHECKPOINT" >/dev/null || rc=1
  WAL2=$(walused)
  REQ1=$(nreq)
  resume_backups || rc=1
  return "$rc"
}
extra_checks() {
  EXTRA_JSON=$(jq -n -c --argjson keep "${KEEP_MB:-null}" --arg ret "$RETAINED_MIB" --arg st "$STATUS_AT_DETECT" --argjson sw "$SWITCHES" \
    --arg r0 "$REQ0" --arg r1 "$REQ1" --arg w0 "$WAL0" --arg w1 "$WAL1" --arg w2 "$WAL2" '
    def n: if . == "" then null else tonumber end;
    {max_slot_wal_keep_size_mb: $keep, retained_mib_after_writes: ($ret|n), wal_switches: $sw,
     slot_at_detection: ($st|if . == "" then null else . end),
     num_requested_delta: (if $r0 == "" or $r1 == "" then null else ($r1|tonumber) - ($r0|tonumber) end),
     pg_wal_bytes_before: ($w0|n), pg_wal_bytes_at_peak: ($w1|n), pg_wal_bytes_after_revert: ($w2|n)}')
  log "extra: $EXTRA_JSON"
}
run_scenario slot-retaining-wal
