#!/usr/bin/env bash
# Scenario pgbouncer-client-limit: fill max_client_conn with idle app clients (no transaction, so no server connection is used and the pool stays idle). The next app client is refused with "no more connections allowed (max_client_conn)" while the console still admits the stats user (decide_startup_pool, src/client.c:1086, PgBouncer 1.26.1 commit f03e9bf). Expect PgbouncerClientSaturation, as critical (used_clients jumps past 0.95 within one scrape, so the warning normally does not fire; EXPECT does not judge severity, so the critical is asserted in after_detect). Nothing else may fire: the scenario asserts that no client waits (cl_waiting 0, maxwait 0), which is why no other alert sees this fault; PgbouncerTargetAbsent in particular must not fire, because the Collector's console connections are exempt from the limit.
# One psql per client, fed by sleep; the password is read from stdin, not argv or env of docker.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgbouncerClientSaturation:pgbouncer")
CLIENT_PID=""
MAXC=0

# value of one SHOW CONFIG key, one SHOW LISTS item. The console connection that
# reads used_clients is itself one of them (first run, 2026-11-08: used_clients
# read 50 of 50 and an app client was still admitted), so "limit reached" means
# a reading of max_client_conn + 1: max_client_conn other clients are connected
# and the next app client is the 51st, which is refused.
cfg_value() { pgb_console "SHOW CONFIG" | awk -F'|' -v k="$1" '$1 == k { print $2 }'; }
list_items() { pgb_console "SHOW LISTS" | awk -F'|' -v k="$1" '$1 == k { print $2 }'; }

# open K idle app clients in the PgBouncer container (they stay until revert)
open_clients() {
  printf '%s\n' "$APP_PASSWORD" | docker exec -i "$PGBOUNCER" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    i=0
    while [ "$i" -lt '"$1"' ]; do
      ( sleep 1500 ) | psql -h 127.0.0.1 -p 6432 -U app -X -d app >/dev/null 2>&1 &
      i=$((i + 1))
      sleep 0.1
    done
    wait' >/dev/null 2>&1 &
  CLIENT_PID=$!
}

# The Collector's console connections come and go: top up with idle app clients
# until used_clients >= max_client_conn + 1. Sets USED. Every open_clients call
# overwrites CLIENT_PID; revert relies on the in-container pkill for the rest.
USED=0
fill_to_limit() {
  local tries=0
  while [ "$tries" -lt 6 ]; do
    sleep 5
    USED=$(list_items used_clients)
    log "used_clients=$USED"
    case "$USED" in ''|*[!0-9]*) echo "console gave no used_clients: '$USED'" >&2; return 1 ;; esac
    [ "$USED" -ge $((MAXC + 1)) ] && return 0
    open_clients $((MAXC + 1 - USED))
    tries=$((tries + 1))
  done
  return 1
}

inject() {
  [ -n "${APP_PASSWORD:-}" ] && [ -n "${OTEL_MONITOR_PASSWORD:-}" ] || { echo "passwords missing: run lab/slice1/scripts/gen-env.sh" >&2; return 1; }
  MAXC=$(cfg_value max_client_conn)
  case "$MAXC" in ''|*[!0-9]*) echo "cannot read max_client_conn: '$MAXC'" >&2; return 1 ;; esac
  docker exec "$PGBOUNCER" pkill -x psql 2>/dev/null
  docker exec "$PGBOUNCER" pkill -x sleep 2>/dev/null
  local used k
  used=$(list_items used_clients)
  k=$((MAXC + 1 - used))
  log "max_client_conn=$MAXC used_clients=$used (including the reading console connection) -> opening $k idle app clients"
  open_clients "$k"
  fill_to_limit || { echo "used_clients did not reach max_client_conn + 1 ($USED of $MAXC)" >&2; return 1; }
}

after_detect() {
  local rc=0 err cons cw mw used
  # the Collector's connections may have left since inject: top up again right before the refusal
  fill_to_limit || { FAILS+=("used_clients below max_client_conn + 1 before the extra client ($USED of $MAXC)"); rc=1; }
  used=$USED
  # one more app client: must be refused; capture the error text (the password goes in on stdin)
  err=$(printf '%s\n' "$APP_PASSWORD" | docker exec -i "$PGBOUNCER" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    psql -h 127.0.0.1 -p 6432 -U app -X -At -d app -c "SELECT 1"' 2>&1)
  if [ "$err" = 1 ]; then FAILS+=("the extra app client got in at used_clients=$used"); rc=1; err="(connected)"; fi
  log "extra app client: $err"
  case "$err" in *"no more connections allowed (max_client_conn)"*) ;; *) FAILS+=("unexpected error text for the extra app client: $err"); rc=1 ;; esac
  # one more console connection as the stats user: must succeed
  if cons=$(pgb_console "SHOW VERSION" 2>&1); then cons=$(printf '%s\n' "$cons" | sed -n 2p); else FAILS+=("console connection refused at the limit: $cons"); rc=1; fi
  log "extra console client as otel_monitor: ${cons:-failed}"
  cw=$(pool_field cl_waiting); mw=$(pool_field maxwait)
  log "app pool: cl_waiting=$cw maxwait=${mw}s used_clients=$used"
  [ "${cw:-1}" = 0 ] && [ "${mw:-1}" = 0 ] || { FAILS+=("a client waits (cl_waiting=$cw maxwait=$mw): not the pure refusal case"); rc=1; }
  wait_until 120 "PgbouncerClientSaturation critical delivered" severity_seen PgbouncerClientSaturation pgbouncer "$T_INJECT" critical || { FAILS+=("PgbouncerClientSaturation was not delivered as critical"); rc=1; }
  EXTRA_JSON=$(jq -n -c --argjson m "$MAXC" --arg u "${used:-}" --arg e "$err" --arg c "${cons:-}" --arg w "${cw:-}" --arg x "${mw:-}" \
    '{max_client_conn: $m, used_clients: $u, app_client_error: $e, console_client: $c, cl_waiting: $w, maxwait: $x}')
  return "$rc"
}

revert() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  docker exec "$PGBOUNCER" pkill -x psql 2>/dev/null
  docker exec "$PGBOUNCER" pkill -x sleep 2>/dev/null
  local n=0 u
  while [ "$n" -lt 12 ]; do
    u=$(list_items used_clients)
    [ -n "$u" ] && [ "$u" -le 5 ] && return 0
    sleep 5; n=$((n + 1))
  done
  return 1
}
run_scenario pgbouncer-client-limit
