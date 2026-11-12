#!/usr/bin/env bash
# Scenario logical-conflict: insert a row on the subscriber, then the same key on the publisher (insert_exists, the apply worker fails and retries every 5 s); expect PostgresLogicalApplyErrors for pg-subscriber only. Neither PostgresLogicalSubscriptionNotStreaming (suppressed in the rule while errors rise) nor PostgresLogicalSlotStalled (the walsender restarts every 5 s, so the slot is never inactive for 3 m, and a few rows are far below 128 MiB) may fire: any other delivered alert fails the run.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresLogicalApplyErrors:pg-subscriber")
KEY=900001
INSERTED=0
inject() {
  psql_sa -c "INSERT INTO orders (id, customer_id, amount) VALUES ($KEY, 1, 1.00)" >/dev/null || return 1
  INSERTED=1
  psql_pa -c "INSERT INTO orders (id, customer_id, amount) VALUES ($KEY, 1, 2.00)" >/dev/null || return 1
}
after_detect() {
  local n
  n=$(psql_sa -c "SELECT apply_error_count || ' ' || confl_insert_exists FROM pg_stat_subscription_stats WHERE subname = '$SUBSCRIPTION'") || return 1
  log "apply_error_count and confl_insert_exists on the subscriber: $n"
  EXTRA_JSON=$(jq -n -c --arg n "$n" '{apply_errors_and_insert_exists: $n}')
}
revert() {
  [ "$INSERTED" = 1 ] || return 0
  # remove the local row; the retrying worker then applies the publisher's row
  psql_sa -c "DELETE FROM orders WHERE id = $KEY AND amount = 1.00" >/dev/null || return 1
  wait_until 120 "publisher row applied on the subscriber" app_in_sync || return 1
  psql_pa -c "DELETE FROM orders WHERE id = $KEY" >/dev/null || return 1
  wait_until 120 "delete applied on the subscriber" app_in_sync
}
run_scenario logical-conflict
