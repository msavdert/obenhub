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
BACKUP_SVC=pgbackrest-backup
BACKUP_C=obenhub-slice1-pgbackrest-backup
PG_IMAGE=obenhub-slice1-postgres:18.7-pgbackrest-2.60.0
REPL_NET=obenhub-slice1_repl
LOGICAL_NET=obenhub-slice1_logical
SUBSCRIPTION=app_sub

# Same files, same order as the containers read them: rules/*.yml (sorted in
# the C locale, as the container sorts them), then the PostgreSQL pack, the
# pgBackRest pack, then alertmanager.yml.
_lc_collate=${LC_COLLATE-}
LC_COLLATE=C
CONFIG_FILES=("$LAB_DIR"/vmalert/rules/*.yml "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/../packs/pgbackrest/rules.yml" "$LAB_DIR/alertmanager/alertmanager.yml")
LC_COLLATE=$_lc_collate
unset _lc_collate
VMALERT_LOADED_CAT='cat /etc/vmalert/rules/*.yml /etc/vmalert/pack/rules.yml /etc/vmalert/pgbackrest/rules.yml'
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

# pgBackRest (ADR 0007). The repository is the volume pgbackrest-repo; pgbackrest
# runs as postgres in the primary container (local mode, same as the
# pgbackrest-backup service). PGBR_WAL_DIR is the repository directory that
# holds the archived WAL of the first PostgreSQL cluster of the stanza (18-1).
REPO_VOL=${PROJECT}_pgbackrest-repo
PGBR_WAL_DIR=/var/lib/pgbackrest/archive/slice1/18-1
pgbr() { docker exec -u postgres "$PRIMARY" pgbackrest --stanza=slice1 "$@"; }
# a completed backup is in the repository
backup_exists() { pgbr info --output=json 2>/dev/null | jq -e '.[0].backup | length > 0' >/dev/null; }
# BACKUP_INTERVAL of the pgbackrest-backup service, read from compose.yaml so
# the two cannot drift (seconds)
BACKUP_INTERVAL=$(docker compose -p obenhub-slice1 -f "$LAB_DIR/compose.yaml" config --format json 2>/dev/null \
  | jq -r '.services["pgbackrest-backup"].environment.BACKUP_INTERVAL // empty')
[ -n "$BACKUP_INTERVAL" ] || { echo "BACKUP_INTERVAL of pgbackrest-backup not found in compose.yaml" >&2; exit 1; }
# the archiver has no backlog: no .ready file, or the last attempt succeeded (or never failed)
archiver_clear() {
  [ "$(psql_p -c "SELECT ((SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready') = 0 OR last_failed_time IS NULL OR last_archived_time >= last_failed_time)::int FROM pg_stat_archiver")" = 1 ]
}
# the WAL segment that ends at LSN is archived (pg_stat_archiver)
archived_past() {
  [ "$(psql_p -c "SELECT (last_archived_wal >= pg_walfile_name('$1'::pg_lsn - 1))::int FROM pg_stat_archiver")" = 1 ]
}
# Seconds since the last completed backup, empty when none or unreadable.
backup_age() {
  pgbr info --output=json 2>/dev/null | jq -r '[.[0].backup[].timestamp.stop] | if length == 0 then empty else (now - max | floor) end'
}
# An incremental backup now, after the archiver has no backlog (a backup waits
# for the WAL it needs to be archived). Fails when either step fails. pgBackRest
# locks are per container (/tmp/pgbackrest), so this is NOT blocked by a backup
# of the pgbackrest-backup service: the caller stops that service first
# (pause_backups), which is the guard against two concurrent backups.
take_backup() {
  wait_until 120 "archiver without backlog" archiver_clear || return 1
  pgbr --type=incr backup >&2
}
# Stop the periodic backups and take one, so that the backup age is 0 and the
# backup's own (start-fast) checkpoint has happened before the scenario
# measures anything. Fails when the backup fails. Pair it with resume_backups
# in revert(); revert() also runs after a failed inject().
pause_backups() {
  dc stop "$BACKUP_SVC" >/dev/null || return 1
  take_backup
}
# Start the periodic backups again. The service schedules from the repository
# and does not back up at once, so when the last backup is older than the
# interval (a paused run, a fault) one is taken first, which must succeed.
# The service is started even when that backup fails.
resume_backups() {
  local age rc=0
  age=$(backup_age)
  if [ -z "$age" ] || [ "$age" -gt "$BACKUP_INTERVAL" ]; then take_backup || rc=1; fi
  dc start "$BACKUP_SVC" >/dev/null || rc=1
  return "$rc"
}
# the pgbackrest-backup service is running
backup_service_running() { [ "$(docker inspect -f '{{.State.Running}}' "$BACKUP_C" 2>/dev/null)" = true ]; }

# component versions recorded under "images" in runs.jsonl
component_versions() {
  docker compose -p obenhub-slice1 -f "$LAB_DIR/compose.yaml" config --images 2>/dev/null | sort -u \
    | jq -R . | jq -s -c .
}

# the init script of pg-subscriber gives up after a deadline and the image then
# skips init on restart: a healthy subscriber may have no subscription at all
subscription_enabled() {
  [ "$(psql_sa -c "SELECT count(*) FROM pg_subscription WHERE subname = '$SUBSCRIPTION' AND subenabled")" = 1 ]
}

lab_precondition() {
  wait_until 120 "subscription $SUBSCRIPTION enabled on pg-subscriber" subscription_enabled || { PRE_ERR="pg-subscriber is down or has no enabled subscription $SUBSCRIPTION (missing: its init gave up waiting for the primary, recover with mise run lab:down, then lab:up; disabled: a scenario revert failed, ALTER SUBSCRIPTION $SUBSCRIPTION ENABLE)"; return 1; }
  wait_until 120 "replication streaming" is_streaming || { PRE_ERR="replication not streaming"; return 1; }
  wait_until 120 "logical replication streaming" logical_streaming || { PRE_ERR="logical replication not streaming"; return 1; }
  wait_until 120 "app tables in sync" app_in_sync || { PRE_ERR="app tables differ between publisher and subscriber"; return 1; }
  backup_service_running || { PRE_ERR="the pgbackrest-backup service is not running (a killed scenario can leave it stopped: docker compose -p $PROJECT start $BACKUP_SVC)"; return 1; }
  wait_until 300 "a pgBackRest backup in the repository" backup_exists || { PRE_ERR="no completed pgBackRest backup (is the pgbackrest-backup service running?)"; return 1; }
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
