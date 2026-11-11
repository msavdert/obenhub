#!/usr/bin/env bash
# Scenario replica-cut: cut the first replica from the primary at the network level (NetworkPolicy on the primary that excludes the replica's pod IP, then the replica's walsender is terminated; see cut_replica in lib.sh). The replica stays Running and Ready (the operator and the Collectors still reach it), its WAL receiver stops. Expect PostgresStandbyNotStreaming for the replica and PostgresPhysicalSlotInactive for the primary (the replica's HA slot _cnpg_<replica> turns inactive). Both are expected, not just the first one, so the result does not depend on when the run reverts: PostgresStandbyNotStreaming needs 1 m of not streaming, PostgresPhysicalSlotInactive needs 120 s inactive plus 1 m (lab/packs/postgresql/rules.yml), and the run holds the fault until both were delivered. The cut lets only the load client's WAL pile up (159 KB after 4 minutes in the smoke run), so PostgresReplicationSlotRetainingWAL must stay quiet; slot-retaining-wal.sh is the scenario that fires it. Pass needs both alerts, both resolved after the revert, and no other alert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
ALLOW=()
REP="" PRIM="" SLOT_STATE=""
inject() {
  REP=$(first_replica) && [ -n "$REP" ] || return 1
  PRIM=$(cut_replica "$REP") && [ -n "$PRIM" ] || return 1
  EXPECT=("PostgresStandbyNotStreaming:$REP" "PostgresPhysicalSlotInactive:$PRIM")
  log "replica $REP cut from primary $PRIM"
}
after_detect() {
  SLOT_STATE=$(psql_n "$PRIM" -d app -c "SELECT s.slot_name || ' active=' || s.active || ' ' || s.wal_status || ' retained=' || pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) FROM pg_replication_slots s WHERE s.slot_name = '_cnpg_' || replace('$REP', '-', '_')") || SLOT_STATE=""
  log "slot while cut: $SLOT_STATE"
}
revert() { uncut_replica; wait_until 300 "cluster healthy" cluster_healthy; }
extra_checks() {
  EXTRA_JSON=$(jq -n -c --arg rep "$REP" --arg prim "$PRIM" --arg slot "$SLOT_STATE" --argjson events "$(events_json "$T_INJECT" "$T_END")" \
    '{cut_replica: $rep, primary: $prim, slot_while_cut: ($slot|if . == "" then null else . end), kubernetes_events: $events}')
  log "extra: $EXTRA_JSON"
}
run_scenario replica-cut
