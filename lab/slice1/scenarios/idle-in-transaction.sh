#!/usr/bin/env bash
# Scenario idle-in-transaction: leave a read committed transaction idle on the primary (BEGIN; SELECT 1; then nothing, so no snapshot and no xid is held); expect IdleInTransaction for pg-primary, first as warning (idle over 60 s) and then as critical (over 180 s). EXPECT matches alertname and instance only, so after_detect waits for the critical tier and checks both severities in the delivered notifications.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("IdleInTransaction:pg-primary")
APPNAME=slice1-idle-in-transaction
inject() {
  docker exec -d -e PGAPPNAME="$APPNAME" "$PRIMARY" sh -c \
    "{ echo 'BEGIN; SELECT 1;'; sleep 1203; } | psql -U postgres -X -q -o /dev/null" || return 1
  sleep 3
  [ "$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$APPNAME' AND state = 'idle in transaction' AND backend_xmin IS NULL AND backend_xid IS NULL")" = 1 ]
}
after_detect() {
  # the warning was delivered (EXPECT saw a firing record); now wait for the critical tier
  wait_until 300 "IdleInTransaction critical delivered" severity_seen IdleInTransaction pg-primary "$T_INJECT" critical \
    || { FAILS+=("IdleInTransaction critical was not delivered"); return 1; }
  severity_seen IdleInTransaction pg-primary "$T_INJECT" warning || { FAILS+=("IdleInTransaction warning was not delivered before the critical"); return 1; }
  EXTRA_JSON='{"tiers_seen": ["warning", "critical"]}'
}
revert() {
  psql_p -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name = '$APPNAME'" >/dev/null
  docker exec "$PRIMARY" pkill -f 'sleep 1203' 2>/dev/null
  return 0
}
run_scenario idle-in-transaction
