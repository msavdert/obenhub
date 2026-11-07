#!/usr/bin/env bash
# Scenario subscription-disabled: ALTER SUBSCRIPTION ... DISABLE and write on the publisher; expect LogicalSlotRetainingWal for pg-primary only. A disabled subscription must not raise LogicalSubscriptionNotStreaming (enabled 0 never matches), so any other delivered alert fails the run.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("LogicalSlotRetainingWal:pg-primary")
DISABLED=0
inject() {
  psql_sa -c "ALTER SUBSCRIPTION $SUBSCRIPTION DISABLE" >/dev/null || return 1
  DISABLED=1
  psql_pa -c "INSERT INTO orders (id, customer_id, amount) SELECT 1000000 + g, 1, 1.00 FROM generate_series(1, 20000) g" >/dev/null || return 1
}
after_detect() {
  local r
  r=$(psql_pa -c "SELECT active || ' ' || pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint FROM pg_replication_slots WHERE slot_name = '$SUBSCRIPTION'") || return 1
  log "slot active and unconfirmed bytes: $r"
  EXTRA_JSON=$(jq -n -c --arg r "$r" '{slot_active_and_unconfirmed_bytes: $r}')
}
revert() {
  [ "$DISABLED" = 1 ] || return 0
  psql_sa -c "ALTER SUBSCRIPTION $SUBSCRIPTION ENABLE" >/dev/null || return 1
  wait_until 180 "subscription caught up" app_in_sync || return 1
  psql_pa -c "DELETE FROM orders WHERE id > 1000000" >/dev/null || return 1
  wait_until 180 "delete applied on the subscriber" app_in_sync
}
run_scenario subscription-disabled
