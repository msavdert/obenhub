#!/usr/bin/env bash
# Scenario connections-exhausted: open more app sessions than the ordinary capacity (max_connections - superuser_reserved - reserved_connections). Some attempts must be rejected, otel_monitor must still get a new connection through its reserved slot (pg_use_reserved_connections), ConnectionSaturation must fire for pg-primary and PostgresTargetAbsent must not.
# One psql per client: pgbench aborts the whole run when one connection fails.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("ConnectionSaturation:pg-primary")
CLIENTS_EXTRA=${CLIENTS_EXTRA:-11}   # attempts beyond the capacity
CLIENT_PID=""
CAPACITY=0
CLIENTS=0

inject() {
  [ -n "${APP_PASSWORD:-}" ] && [ -n "${OTEL_MONITOR_PASSWORD:-}" ] || { echo "passwords missing: run lab/slice1/scripts/gen-env.sh" >&2; return 1; }
  local maxc sres res
  maxc=$(psql_p -c "SHOW max_connections") && sres=$(psql_p -c "SHOW superuser_reserved_connections") \
    && res=$(psql_p -c "SHOW reserved_connections") || return 1
  CAPACITY=$((maxc - sres - res))
  CLIENTS=$((CAPACITY + CLIENTS_EXTRA))
  log "max_connections=$maxc superuser_reserved=$sres reserved=$res -> ordinary capacity $CAPACITY, opening $CLIENTS app sessions"
  # app role: created once, password set every run (it may have been
  # regenerated in .env); the password goes in on stdin
  if [ "$(psql_p -c "SELECT count(*) FROM pg_roles WHERE rolname = 'app'")" = 0 ]; then
    psql_p -c "CREATE ROLE app LOGIN" >/dev/null || return 1
  fi
  printf "ALTER ROLE app PASSWORD '%s';\n" "$APP_PASSWORD" | psql_p >/dev/null || return 1
  docker exec "$PRIMARY" rm -f /tmp/app-clients.log
  # one background psql per client; the password is read from stdin, not argv or env of docker
  printf '%s\n' "$APP_PASSWORD" | docker exec -i "$PRIMARY" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    i=0
    while [ "$i" -lt '"$CLIENTS"' ]; do
      psql -h pg-primary -U app -X -d postgres -c "SELECT pg_sleep(1500)" >/dev/null 2>>/tmp/app-clients.log &
      i=$((i + 1))
    done
    wait' >/dev/null 2>&1 &
  CLIENT_PID=$!
  sleep 15
  local n
  n=$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'app'") || return 1
  log "app sessions open: $n"
  [ "$n" -gt 0 ]
}

# while the ordinary slots are full: (a) attempts were rejected, (b) otel_monitor still gets in
after_detect() {
  local rc=0 rejected n probe
  rejected=$(docker exec "$PRIMARY" sh -c 'grep -c "remaining connection slots are reserved" /tmp/app-clients.log') || rejected=0
  n=$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'app'") || n="?"
  log "app attempts rejected for full ordinary slots: $rejected; app sessions open: $n (capacity $CAPACITY)"
  if [ "$rejected" -lt 1 ]; then FAILS+=("no app connection attempt was rejected"); rc=1; fi
  probe=$(printf '%s\n' "$OTEL_MONITOR_PASSWORD" | docker exec -i "$PRIMARY" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    psql -h pg-primary -U otel_monitor -X -At -d postgres -c "SELECT 1"' 2>&1)
  log "new otel_monitor TCP connection while full: ${probe:-no output}"
  if [ "$probe" != 1 ]; then FAILS+=("otel_monitor could not open a new connection while full: $probe"); rc=1; fi
  EXTRA_JSON=$(jq -n -c --argjson c "$CAPACITY" --argjson a "$CLIENTS" --argjson r "${rejected:-0}" '{capacity: $c, attempts: $a, rejected: $r, monitor_probe: "ok"}')
  return "$rc"
}

extra_checks() {
  local out
  if ! out=$(vl "_time:>$T_INJECT _time:<=$T_END commonLabels.alertname:=PostgresTargetAbsent | stats count() n"); then
    FAILS+=("PostgresTargetAbsent check: VictoriaLogs query failed")
    return 0
  fi
  [ "$(printf '%s\n' "$out" | jq -r '.n')" = 0 ] || FAILS+=("PostgresTargetAbsent was delivered during exhaustion")
}

revert() {
  psql_p -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'app'" >/dev/null || return 1
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  docker exec "$PRIMARY" pkill -x psql 2>/dev/null
  sleep 2
  [ "$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'app'")" = 0 ]
}
run_scenario connections-exhausted
