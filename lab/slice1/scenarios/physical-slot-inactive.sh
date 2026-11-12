#!/usr/bin/env bash
# Scenario physical-slot-inactive: create a physical replication slot on the primary that nothing consumes (WAL reserved at creation); expect PostgresPhysicalSlotInactive for pg-primary once the slot has been inactive over 120 s (lab threshold). No other alert is expected: the slot retains almost nothing.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresPhysicalSlotInactive:pg-primary")
SLOT=obenhub_spare
inject() {
  local since
  psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null || return 1
  psql_p -c "SELECT slot_name FROM pg_create_physical_replication_slot('$SLOT', true)" >/dev/null || return 1
  since=$(psql_p -c "SELECT coalesce(inactive_since::text, 'NULL') FROM pg_replication_slots WHERE slot_name = '$SLOT'") || return 1
  log "inactive_since right after creation: $since"
  EXTRA_JSON=$(jq -n -c --arg s "$since" '{inactive_since_at_creation: $s}')
}
revert() { psql_p -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT'" >/dev/null; }
run_scenario physical-slot-inactive
