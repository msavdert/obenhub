#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Slice 1 and stage 2 adapter for the shared fault scenario machinery in
# lab/scenarios/lib-core.sh: it binds the core to the slice 1 Compose lab
# (docker exec into the PostgreSQL, PgBouncer and Collector containers) and
# holds the helpers its scenarios use. Source it from a scenario; do not run
# it. A scenario defines EXPECT, inject() and revert() and calls run_scenario
# (see standby-stopped.sh for the smallest example). The core's header lists
# what an adapter provides.
#
# There is no Patroni or etcd here: the core's ptl/members/etcd helpers stay
# undefined and no slice 1 scenario calls them.
#
# Needs: docker, curl, jq, the lab running (mise run lab:up).

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
RESULTS="$LAB_DIR/results/runs.jsonl"
PROJECT=obenhub-slice1
VL=${VL:-http://127.0.0.1:19428}
AM=${AM:-http://127.0.0.1:19093}
VM=${VM:-http://127.0.0.1:18428}
VMALERT=${VMALERT:-http://127.0.0.1:18880}
VMALERT_C=obenhub-slice1-vmalert
AM_C=obenhub-slice1-alertmanager
PRIMARY=obenhub-slice1-pg-primary
STANDBY=obenhub-slice1-pg-standby
SUBSCRIBER=obenhub-slice1-pg-subscriber
PGBOUNCER=obenhub-slice1-pgbouncer
REPL_NET=obenhub-slice1_repl
LOGICAL_NET=obenhub-slice1_logical
SUBSCRIPTION=app_sub

# Same files, same order as the containers read them: rules/*.yml (sorted in
# the C locale, as the container sorts them), then the PostgreSQL pack, then
# alertmanager.yml.
_lc_collate=${LC_COLLATE-}
LC_COLLATE=C
CONFIG_FILES=("$LAB_DIR"/vmalert/rules/*.yml "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/alertmanager/alertmanager.yml")
LC_COLLATE=$_lc_collate
unset _lc_collate
VMALERT_LOADED_CAT='cat /etc/vmalert/rules/*.yml /etc/vmalert/pack/rules.yml'
# the record carries crash_restarts; null until the check at the end ran
CRASH_RESTARTS=null

[ -r "$LAB_DIR/.env" ] && set -a && . "$LAB_DIR/.env" && set +a

# shellcheck source=lab/scenarios/lib-core.sh
. "$SC_DIR/../../scenarios/lib-core.sh"

dc() { docker compose -p "$PROJECT" -f "$LAB_DIR/compose.yaml" "$@"; }

# psql as superuser over the container's local socket (trust, no password).
psql_p() { docker exec -i "$PRIMARY" psql -U postgres -X -v ON_ERROR_STOP=1 -At "$@"; }
psql_s() { docker exec -i "$STANDBY" psql -U postgres -X -v ON_ERROR_STOP=1 -At "$@"; }

# Stage 2: the same, in database app (publisher) and on the subscriber.
psql_pa() { docker exec -i "$PRIMARY" psql -U postgres -X -v ON_ERROR_STOP=1 -At -d app "$@"; }
psql_sa() { docker exec -i "$SUBSCRIBER" psql -U postgres -X -v ON_ERROR_STOP=1 -At -d app "$@"; }

# Stage 2: a SHOW command on the PgBouncer console as the stats user, output as
# unaligned rows with a header; the password goes in on stdin, not argv.
pgb_console() {
  printf '%s\n' "$OTEL_MONITOR_PASSWORD" | docker exec -i "$PGBOUNCER" sh -c '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -v ON_ERROR_STOP=1 -A -d pgbouncer -c "$1"' sh "$1"
}

# Stage 2: app row of SHOW POOLS: field NAME (cl_active, cl_waiting, sv_active, maxwait).
# Prints 0 when the console answers without an app row (the pool is gone once
# idle), nothing when the console does not answer.
pool_field() {
  pgb_console "SHOW POOLS" | awk -F'|' -v f="$1" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == f) c = i }
    NR > 1 && $1 == "app" { print $c; found = 1 }
    END { if (c && !found) print 0 }'
}

# severity_seen ALERTNAME INSTANCE SINCE SEVERITY -> succeeds when a delivered notification since SINCE
# for that alert held a firing alert with that severity. Tiered rules (same alertname, one tier per
# series) need this: EXPECT matches alertname and instance only, not severity. commonLabels.severity
# is no use here: the group's notifications at an escalation are, in the order seen (2026-11-08), one
# with only the resolved warning, then one with only the firing critical, then one with both, so a
# notification's common severity is not reliable. The match is therefore inside one alert object of
# the alerts field (a JSON string): a firing alert whose labels carry the severity.
severity_seen() {
  [ -n "$(vl "_time:>$3 status:=firing commonLabels.alertname:=$1 commonLabels.service_instance_id:=$2 alerts:~\"firing[^{}]*.[^{}]*severity.{1,6}$4\" | limit 1 | fields _time" | head -n1)" ]
}

streaming_count() { psql_p -c "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming' AND application_name <> '$SUBSCRIPTION'"; }
is_streaming() { [ "$(streaming_count)" = 1 ]; }
# the logical walsender of the subscription is streaming on the publisher
logical_streaming() {
  [ "$(psql_p -c "SELECT count(*) FROM pg_stat_replication WHERE application_name = '$SUBSCRIPTION' AND state = 'streaming'")" = 1 ]
}
# both tables hold the same rows on publisher and subscriber (md5 over every row, ordered by key)
app_digest='SELECT (SELECT md5(coalesce(string_agg(t::text, chr(10) ORDER BY id), chr(32))) FROM orders t) || (SELECT md5(coalesce(string_agg(t::text, chr(10) ORDER BY id), chr(32))) FROM customers t)'
app_in_sync() {
  local a b
  a=$(psql_pa -c "$app_digest") && b=$(psql_sa -c "$app_digest") && [ -n "$a" ] && [ "$a" = "$b" ]
}

# component versions recorded under "images" in runs.jsonl
component_versions() {
  grep -E '^[[:space:]]+image:' "$LAB_DIR/compose.yaml" | sed 's/.*image: *//' | sort -u \
    | jq -R . | jq -s -c .
}

# the init script of pg-subscriber gives up after a deadline and the image then
# skips init on restart: a healthy subscriber may have no subscription at all
subscription_enabled() {
  [ "$(psql_sa -c "SELECT count(*) FROM pg_subscription WHERE subname = '$SUBSCRIPTION' AND subenabled")" = 1 ]
}

lab_precondition() {
  subscription_enabled || { PRE_ERR="pg-subscriber has no enabled subscription $SUBSCRIPTION (its init gave up waiting for the primary); recover with: mise run lab:down, then lab:up"; return 1; }
  wait_until 120 "replication streaming" is_streaming || { PRE_ERR="replication not streaming"; return 1; }
  wait_until 120 "logical replication streaming" logical_streaming || { PRE_ERR="logical replication not streaming"; return 1; }
  wait_until 120 "app tables in sync" app_in_sync || { PRE_ERR="app tables differ between publisher and subscriber"; return 1; }
}

# a scenario must not crash a PostgreSQL server: its postmaster logs this line
# when a child dies abnormally (an orphan killed by a revert, for example)
lab_final_checks() {
  local crash
  if crash=$(vl "_time:>$T_START _time:<=$T_END service.name:=postgresql _msg:=\"all server processes terminated; reinitializing\" | stats count() n" | jq -r '.n // 0'); then
    CRASH_RESTARTS=$crash
    if [ "$crash" != 0 ]; then FAILS+=("PostgreSQL crash restart logged $crash time(s) during the run"); fi
  else
    FAILS+=("crash restart query against VictoriaLogs failed")
  fi
}
