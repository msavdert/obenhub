#!/usr/bin/env bash
# Scenario pgbouncer-pool-saturated: hold more open transactions through PgBouncer than the pool has server connections (default_pool_size); the extra clients queue. Expect PgbouncerClientsWaiting, PgbouncerPoolSaturated (a correct reaction: the pool sits at its size for the whole run, detected after the 5 m window fills, about 6 min, inside DETECT_TIMEOUT and query_wait_timeout) and PostgresIdleInTransaction for pg-primary; PostgresConnectionSaturation on the primary must not fire (the pool is far below max_connections). PostgresIdleInTransaction is a correct reaction, not a side effect: the pool is saturated by sessions idle in a transaction, held for as long as it takes to detect, which is past the 60 s threshold plus its window; run_scenario waits for every EXPECT entry before it reverts. Ending the run releases the queued clients, whose whole wait then lands in the SHOW STATS wait time without an assignment; PgbouncerWaitTime ignores that (see the rule).
# One psql per client, each in an open transaction (BEGIN; SELECT 1; then idle), so the server connection stays linked to its client.
# Idle in transaction rather than pg_sleep: no snapshot is held, so PostgresSnapshotHeldTooLong stays out of this scenario.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgbouncerClientsWaiting:pgbouncer" "PgbouncerPoolSaturated:pgbouncer" "PostgresIdleInTransaction:pg-primary")
CLIENTS_EXTRA=${CLIENTS_EXTRA:-3}   # clients beyond the pool size
CLIENT_PID=""
POOL_SIZE=0
CLIENTS=0

inject() {
  [ -n "${APP_PASSWORD:-}" ] && [ -n "${OTEL_MONITOR_PASSWORD:-}" ] || { echo "passwords missing: run lab/slice1/scripts/gen-env.sh" >&2; return 1; }
  POOL_SIZE=$(pgb_console "SHOW DATABASES" | awk -F'|' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "pool_size") c = i } $1 == "app" { print $c }')
  case "$POOL_SIZE" in ''|*[!0-9]*) echo "cannot read pool_size from the console: '$POOL_SIZE'" >&2; return 1 ;; esac
  CLIENTS=$((POOL_SIZE + CLIENTS_EXTRA))
  log "pool_size=$POOL_SIZE -> opening $CLIENTS clients through PgBouncer"
  docker exec "$PGBOUNCER" pkill -x psql 2>/dev/null
  docker exec "$PGBOUNCER" pkill -x sleep 2>/dev/null
  # the password is read from stdin, not argv or env of docker
  printf '%s\n' "$APP_PASSWORD" | docker exec -i "$PGBOUNCER" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    i=0
    while [ "$i" -lt '"$CLIENTS"' ]; do
      ( printf "BEGIN;\nSELECT 1;\n"; sleep 1500 ) | psql -h 127.0.0.1 -p 6432 -U app -X -d app >/dev/null 2>&1 &
      i=$((i + 1))
      sleep 0.2
    done
    wait' >/dev/null 2>&1 &
  CLIENT_PID=$!
  sleep 10
  local w
  w=$(pool_field cl_waiting) || return 1
  log "clients waiting: $w"
  [ "${w:-0}" -ge 1 ]
}

after_detect() {
  local rc=0 act wait sva mw
  act=$(pool_field cl_active); wait=$(pool_field cl_waiting); sva=$(pool_field sv_active); mw=$(pool_field maxwait)
  log "app pool: cl_active=$act cl_waiting=$wait sv_active=$sva maxwait=${mw}s (pool_size $POOL_SIZE)"
  [ "${sva:-0}" = "$POOL_SIZE" ] || { FAILS+=("pool not at pool_size: sv_active=$sva"); rc=1; }
  [ "${wait:-0}" -ge 1 ] || { FAILS+=("no client waiting"); rc=1; }
  EXTRA_JSON=$(jq -n -c --argjson p "$POOL_SIZE" --argjson c "$CLIENTS" --arg w "${wait:-}" --arg s "${sva:-}" --arg m "${mw:-}" \
    '{pool_size: $p, clients: $c, cl_waiting: $w, sv_active: $s, maxwait: $m}')
  return "$rc"
}

revert() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  docker exec "$PGBOUNCER" pkill -x psql 2>/dev/null
  # the feeders (sleep 1500) write nothing, so no SIGPIPE ends them
  docker exec "$PGBOUNCER" pkill -x sleep 2>/dev/null
  local n=0
  while [ "$n" -lt 12 ]; do
    [ "$(pool_field cl_waiting)" = 0 ] && [ "$(pool_field cl_active)" = 0 ] && return 0
    sleep 5; n=$((n + 1))
  done
  return 1
}
run_scenario pgbouncer-pool-saturated
