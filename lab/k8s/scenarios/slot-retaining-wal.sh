#!/usr/bin/env bash
# Scenario slot-retaining-wal: the HA slot of a replica that cannot consume WAL retains it. The first replica is cut from the primary (cut_replica in lib.sh, as in replica-cut.sh), then the primary writes a bounded amount of WAL: a scratch table filled in 100000-row chunks (about 100 MB of WAL each, text padding, no TOAST; autovacuum is off on the table: in the first smoke run, 2026-11-11, the autovacuum of the fresh table roughly doubled the WAL, the slot went from 703 to 1395 MiB, past the guard, status unreserved, and the run failed its own validity check) until the replica's slot _cnpg_<replica> retains 640 MiB, then pg_switch_wal. The bound is the cluster's guard max_slot_wal_keep_size = 1GB (lab/k8s/cnpg/cluster.yaml; it was -1, unlimited, until 2026-11-11, and local-path does not enforce the 1Gi claim, so a stuck slot would have been limited by the host disk only); the writer stops at 900 MiB. The alert threshold is 512 MiB (PostgresReplicationSlotRetainingWAL, lab/packs/postgresql/rules.yml), so the slot stays valid when the alert fires. Expect PostgresReplicationSlotRetainingWAL for the primary, plus the two alerts of the cut itself, PostgresStandbyNotStreaming for the replica and PostgresPhysicalSlotInactive for the primary: both necessarily fire while the fault lasts (the cut is older than 3 m when the 2 m hold of the WAL alert has passed), so they are expected, and the run waits for all three. Revert drops the scratch table, removes the policy and waits for the replica to stream again; it then replays the WAL it missed; in the smoke runs (2026-11-11) its replay backlog peaked at 680 bytes, far below PostgresReplayBacklog's 16 MiB, so nothing is allowed for it. Pass needs the three alerts, all resolved after the revert, and no other alert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET_MIB=640
LIMIT_MIB=900
EXPECT=()
ALLOW=()
REP="" PRIM="" SLOT="" KEEP_BEFORE="" RETAINED_MIB="" STATUS_AT_DETECT="" ROWS=0
# empty output (slot gone, or restart_lsn NULL after invalidation) is an error, not 0: the writer must stop
retained_bytes() {
  local b
  b=$(psql_n "$PRIM" -d app -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint FROM pg_replication_slots WHERE slot_name = '$SLOT'") || return 1
  [[ "$b" =~ ^[0-9]+$ ]] || { log "slot $SLOT has no retained WAL figure ('$b')"; return 1; }
  echo "$b"
}
inject() {
  REP=$(first_replica) && [ -n "$REP" ] || return 1
  SLOT="_cnpg_${REP//-/_}"
  PRIM=$(leader_name)
  KEEP_BEFORE=$(psql_n "$PRIM" -d app -c "SHOW max_slot_wal_keep_size")
  log "max_slot_wal_keep_size on $PRIM: $KEEP_BEFORE; slot $SLOT"
  [ "$KEEP_BEFORE" != "-1" ] || { log "no guard: refusing to fill the volume"; return 1; }
  PRIM=$(cut_replica "$REP") && [ -n "$PRIM" ] || return 1
  EXPECT=("PostgresReplicationSlotRetainingWAL:$PRIM" "PostgresStandbyNotStreaming:$REP" "PostgresPhysicalSlotInactive:$PRIM")
  psql_n "$PRIM" -d app -c "DROP TABLE IF EXISTS obenhub_wal_scratch; CREATE TABLE obenhub_wal_scratch (id bigint, pad text) WITH (autovacuum_enabled = false)" >/dev/null || return 1
  local b
  while :; do
    b=$(retained_bytes) || return 1
    [ "$((b / 1048576))" -lt "$TARGET_MIB" ] || break
    [ "$ROWS" -lt 1000000 ] || { log "slot still below target after $ROWS rows"; return 1; }
    psql_n "$PRIM" -d app -c "INSERT INTO obenhub_wal_scratch SELECT g, repeat(md5(g::text), 30) FROM generate_series($((ROWS + 1)), $((ROWS + 100000))) g" >/dev/null || return 1
    ROWS=$((ROWS + 100000))
    b=$(retained_bytes) || return 1
    log "wrote $ROWS rows; slot retains $((b / 1048576)) MiB"
  done
  psql_n "$PRIM" -d app -c "SELECT pg_switch_wal()" >/dev/null
  b=$(retained_bytes) || return 1
  RETAINED_MIB=$((b / 1048576))
  [ "$RETAINED_MIB" -lt "$LIMIT_MIB" ] || { FAILS+=("slot retains ${RETAINED_MIB} MiB, above the ${LIMIT_MIB} MiB limit"); }
  log "slot $SLOT retains $RETAINED_MIB MiB"
}
after_detect() {
  STATUS_AT_DETECT=$(psql_n "$PRIM" -d app -c "SELECT wal_status || ' retained_mib=' || (pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)/1048576)::bigint FROM pg_replication_slots WHERE slot_name = '$SLOT'") || STATUS_AT_DETECT=""
  log "slot at detection: $STATUS_AT_DETECT"
  case "$STATUS_AT_DETECT" in
    reserved*|extended*) ;;
    *) FAILS+=("slot not valid at detection: $STATUS_AT_DETECT") ;;
  esac
}
revert() {
  uncut_replica
  # the table holds about 700 MB: a failed drop fails the run instead of leaving it behind
  psql_n "$(leader_or "$PRIM")" -d app -c "DROP TABLE IF EXISTS obenhub_wal_scratch" >/dev/null || FAILS+=("scratch table obenhub_wal_scratch not dropped")
  wait_until 600 "cluster healthy" cluster_healthy
}
extra_checks() {
  EXTRA_JSON=$(jq -n -c --arg rep "$REP" --arg prim "$PRIM" --arg slot "$SLOT" --arg keep "$KEEP_BEFORE" --arg ret "$RETAINED_MIB" --arg st "$STATUS_AT_DETECT" --argjson rows "$ROWS" --argjson events "$(events_json "$T_INJECT" "$T_END")" \
    '{cut_replica: $rep, primary: $prim, slot: $slot, max_slot_wal_keep_size: $keep, scratch_rows: $rows, retained_mib_after_writes: ($ret|if . == "" then null else tonumber end), slot_at_detection: ($st|if . == "" then null else . end), kubernetes_events: $events}')
  log "extra: $EXTRA_JSON"
}
run_scenario slot-retaining-wal
