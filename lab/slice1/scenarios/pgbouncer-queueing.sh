#!/usr/bin/env bash
# Scenario pgbouncer-queueing: more busy clients than the pool has server connections, each transaction short (pg_sleep(0.1)), so clients queue for a fraction of a second at a time. Expect PgbouncerPoolSaturated (the pool sits at its size) and PgbouncerWaitTime (the average wait per server assignment is about 0.2 s: 15 clients, pool of 5, 0.1 s per transaction). PgbouncerClientsWaiting must not fire: the oldest waiter stays far below 5 s, which is the case this scenario exists for (many short waits that SHOW POOLS maxwait never shows); the unexpected-alert check of run_scenario covers it, and after_detect also fails on a maxwait of 5 s or more.
# pgbench runs inside pg-primary and connects to PgBouncer over the Compose network as the app role; the password is read from stdin, not argv or env of docker. pg_sleep in a short transaction holds no long snapshot, so PostgresSnapshotHeldTooLong stays out.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgbouncerPoolSaturated:pgbouncer" "PgbouncerWaitTime:pgbouncer")
CLIENTS=${CLIENTS:-15}
CLIENT_PID=""
PGB_LOG=""

inject() {
  [ -n "${APP_PASSWORD:-}" ] && [ -n "${OTEL_MONITOR_PASSWORD:-}" ] || { echo "passwords missing: run lab/slice1/scripts/gen-env.sh" >&2; return 1; }
  docker exec "$PRIMARY" sh -c "printf 'SELECT pg_sleep(0.1);\n' >/tmp/queue.sql" || return 1
  docker exec "$PRIMARY" pkill -x pgbench 2>/dev/null
  PGB_LOG=$(mktemp)
  printf '%s\n' "$APP_PASSWORD" | docker exec -i "$PRIMARY" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    exec pgbench -n -c '"$CLIENTS"' -j 3 -T 1200 -f /tmp/queue.sql -h pgbouncer -p 6432 -U app -d app' >"$PGB_LOG" 2>&1 &
  CLIENT_PID=$!
  sleep 15
  docker exec "$PRIMARY" pgrep -x pgbench >/dev/null || { echo "pgbench is not running: $(tail -n 3 "$PGB_LOG")" >&2; return 1; }
  log "pgbench running: $CLIENTS clients, pool_size $(pgb_console 'SHOW DATABASES' | awk -F'|' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "pool_size") c = i } $1 == "app" { print $c }')"
}

# field NAME of the app row of SHOW STATS (microseconds for the avg_*_time fields)
stats_field() {
  pgb_console "SHOW STATS" | awk -F'|' -v f="$1" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == f) c = i }
    NR > 1 && $1 == "app" { print $c }'
}

after_detect() {
  local rc=0 aw aq mw cw i m maxseen=0 sva
  aw=$(stats_field avg_wait_time); aq=$(stats_field avg_query_time)
  sva=$(pool_field sv_active); cw=$(pool_field cl_waiting)
  # the largest maxwait over 30 samples, in microseconds (maxwait whole seconds + maxwait_us)
  for i in $(seq 1 30); do
    m=$(pgb_console "SHOW POOLS" | awk -F'|' 'NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "maxwait") a = i; if ($i == "maxwait_us") b = i } } $1 == "app" { print $a * 1000000 + $b }')
    [ -n "$m" ] && [ "$m" -gt "$maxseen" ] && maxseen=$m
    sleep 0.5
  done
  log "app: avg_wait_time=${aw}us avg_query_time=${aq}us sv_active=$sva cl_waiting=$cw max maxwait seen=${maxseen}us"
  [ "$maxseen" -lt 5000000 ] || { FAILS+=("a client waited 5 s or more (maxwait ${maxseen}us): not the short-wait case"); rc=1; }
  [ -n "$aw" ] && [ "${aw%.*}" -gt 0 ] || { FAILS+=("avg_wait_time is not above zero: '$aw'"); rc=1; }
  EXTRA_JSON=$(jq -n -c --arg w "${aw:-}" --arg q "${aq:-}" --argjson m "$maxseen" --arg s "${sva:-}" --argjson c "$CLIENTS" \
    '{clients: $c, sv_active: $s, avg_wait_time_us: $w, avg_query_time_us: $q, max_maxwait_us: $m}')
  return "$rc"
}

revert() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  docker exec "$PRIMARY" pkill -x pgbench 2>/dev/null
  [ -n "$PGB_LOG" ] && rm -f "$PGB_LOG"
  local n=0
  while [ "$n" -lt 12 ]; do
    [ "$(pool_field cl_waiting)" = 0 ] && [ "$(pool_field cl_active)" = 0 ] && [ "$(pool_field sv_active)" = 0 ] && return 0
    sleep 5; n=$((n + 1))
  done
  return 1
}
run_scenario pgbouncer-queueing
