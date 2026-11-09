#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared helpers for the slice 1 and stage 2 fault scenarios. Source it from a scenario;
# do not run it. A scenario defines EXPECT, inject() and revert() and calls
# run_scenario (see standby-stopped.sh for the smallest example).
#
# Needs: docker, curl, jq, the lab running (mise run lab:up).
# Sink = VictoriaLogs; every Alertmanager notification is one record whose
# commonLabels.alertname / commonLabels.service_instance_id identify the group
# (alertmanager.yml groups by exactly those two labels).

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
DETECT_TIMEOUT=${DETECT_TIMEOUT:-600}
RESOLVE_TIMEOUT=${RESOLVE_TIMEOUT:-600}
SETTLE_TIMEOUT=${SETTLE_TIMEOUT:-300}

# shellcheck disable=SC1091
[ -r "$LAB_DIR/.env" ] && set -a && . "$LAB_DIR/.env" && set +a

dc() { docker compose -p "$PROJECT" -f "$LAB_DIR/compose.yaml" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
now_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
epoch() { date -u -d "$1" +%s.%N; }
secs() { awk -v a="$(epoch "$1")" -v b="$(epoch "$2")" 'BEGIN{printf "%.1f", b-a}'; }

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

vl() { curl -fsS "$VL/select/logsql/query" --data-urlencode "query=$1"; }

# first_record STATUS ALERTNAME INSTANCE SINCE -> _time of the earliest match
first_record() {
  local q="_time:>$4 status:=$1 commonLabels.alertname:=$2"
  [ -n "$3" ] && q="$q commonLabels.service_instance_id:=$3"
  vl "$q | sort by (_time) | limit 1 | fields _time" | jq -r '._time // empty' | head -n1
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

# am_active -> names of alerts that are active and not inhibited or silenced
am_active() {
  curl -fsS "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false" \
    | jq -r '.[] | .labels.alertname + (if .labels.service_instance_id then ":" + .labels.service_instance_id else "" end)' | sort
}
am_clean() { [ "$(am_active)" = "Watchdog" ]; }

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
later() { awk -v a="$(epoch "$1")" -v b="$(epoch "$2")" 'BEGIN{exit !(a>b)}'; }

wait_until() { # TIMEOUT description command...
  local limit=$1 what=$2 t0 s
  shift 2
  t0=$(date +%s)
  while ! "$@" 2>/dev/null; do
    s=$(($(date +%s) - t0))
    if [ "$s" -ge "$limit" ]; then log "timeout after ${s}s waiting for: $what"; return 1; fi
    sleep 5
  done
}

image_versions() {
  grep -E '^[[:space:]]+image:' "$LAB_DIR/compose.yaml" | sed 's/.*image: *//' | sort -u \
    | jq -R . | jq -s -c .
}

# The rule and Alertmanager files are bind-mounted, but both services keep
# what they loaded at start. Reload them so that config_sha256 describes the
# configuration that actually ran. A failed vmalert reload keeps the old rules
# and only shows in its metrics. vmalert v1.155.0 counts every reload in
# _total but moves the success timestamp only when the files changed (lab
# run 2026-11-09), so wait for _total to move, then require _successful and
# no new reload error. _total may move before the files are parsed
# (unverified, vmalert source not read). In the lab the three metrics always
# changed in the same scrape, about 20 ms after the request (2026-11-09), so
# the one-second pause is a margin, not a measured bound. A single-file bind mount keeps the old
# inode when an edit replaces the file, so the reload can succeed on stale
# content: compare what the containers read with the repository, and record
# that hash at reload time rather than at the end of the scenario.
vmalert_metric() { curl -fsS "$VMALERT/metrics" | awk -v m="$1" '$1==m {print $2}'; }
vmalert_reload_done() { [ "$(vmalert_metric vmalert_config_last_reload_total)" -gt "$1" ] 2>/dev/null; }
reload_config() {
  local n e
  curl -fsS -X POST "$AM/-/reload" >/dev/null || { PRE_ERR="Alertmanager reload failed"; return 1; }
  n=$(vmalert_metric vmalert_config_last_reload_total) && [ -n "$n" ] || { PRE_ERR="vmalert metrics unreadable"; return 1; }
  e=$(vmalert_metric vmalert_config_last_reload_errors_total) && [ -n "$e" ] || { PRE_ERR="vmalert metrics unreadable"; return 1; }
  curl -fsS -X POST "$VMALERT/-/reload" >/dev/null || { PRE_ERR="vmalert reload request failed"; return 1; }
  wait_until 30 "vmalert reload" vmalert_reload_done "$n" || { PRE_ERR="vmalert did not reload"; return 1; }
  sleep 1
  local e2 ok
  e2=$(vmalert_metric vmalert_config_last_reload_errors_total) && ok=$(vmalert_metric vmalert_config_last_reload_successful) \
    && [ -n "$e2" ] && [ -n "$ok" ] || { PRE_ERR="vmalert metrics unreadable after reload"; return 1; }
  [ "$e2" = "$e" ] && [ "$ok" = 1 ] || { PRE_ERR="vmalert rejected the rule files"; return 1; }
  CONFIG_HASH=$(loaded_config_hash) && [ -n "$CONFIG_HASH" ] || { CONFIG_HASH=""; PRE_ERR="cannot read the alerting config inside the containers"; return 1; }
  [ "$CONFIG_HASH" = "$(config_hash)" ] || { PRE_ERR="containers read a different alerting config than the repository (recreate vmalert and alertmanager)"; return 1; }
}

# Pre-flight shared by all scenarios.
precondition() {
  reload_config || return 1
  wait_until "$SETTLE_TIMEOUT" "only Watchdog active in Alertmanager" am_clean || { PRE_ERR="Alertmanager not clean: $(am_active | tr '\n' ' ')"; return 1; }
  wait_until 120 "replication streaming" is_streaming || { PRE_ERR="replication not streaming"; return 1; }
  wait_until 120 "logical replication streaming" logical_streaming || { PRE_ERR="logical replication not streaming"; return 1; }
  wait_until 120 "app tables in sync" app_in_sync || { PRE_ERR="app tables differ between publisher and subscriber"; return 1; }
}

# --- run bookkeeping -------------------------------------------------------
SCENARIO=""
T_START="" T_INJECT="" T_DETECT="" T_RESOLVE="" T_END="" T_REVERT=""
S_INJECT="" S_HOLD=0
HOLD_AFTER_DETECT=${HOLD_AFTER_DETECT:-0}
FAILS=()
UNEXPECTED="[]"
REVERTED=0
WRITTEN=0
CONFIG_HASH=""   # alerting config as loaded by the containers (reload_config); empty = not checked
CRASH_RESTARTS=null   # PostgreSQL crash restarts logged during the run (null = not checked)
EXPECT=()          # entries "AlertName:instance" (instance may be empty)

do_revert() {
  [ "$REVERTED" = 1 ] && return 0
  REVERTED=1
  log "revert"
  revert || FAILS+=("revert failed")
}

# window_alerts SINCE UNTIL -> TSV: alertname instance status count, no Watchdog
# Fails (non-zero, no output) when the query or its parsing fails; zero rows
# is a success with empty output.
window_alerts() {
  local out
  out=$(vl "_time:>$1 _time:<=$2 status:* -commonLabels.alertname:=Watchdog | stats by (commonLabels.alertname, commonLabels.service_instance_id, status) count() n") || return 1
  printf '%s\n' "$out" | jq -r '[.["commonLabels.alertname"], (.["commonLabels.service_instance_id"] // ""), .status, .n] | @tsv'
}

# provenance: git HEAD, dirty flag, hash of the alerting configuration
git_sha() { git -C "$LAB_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown; }
git_dirty() { [ -n "$(git -C "$LAB_DIR" status --porcelain 2>/dev/null)" ] && echo true || echo false; }
config_hash() {
  ( export LC_ALL=C
    cat "$LAB_DIR"/vmalert/rules/*.yml "$LAB_DIR/../packs/postgresql/rules.yml" "$LAB_DIR/alertmanager/alertmanager.yml" 2>/dev/null | sha256sum | cut -c1-12 )
}
# The same files as the containers see them, in the same order. No output
# and status 1 when a container cannot be read.
loaded_config_hash() {
  local h
  h=$( ( set -o pipefail
    { docker exec "$VMALERT_C" sh -c 'export LC_ALL=C; cat /etc/vmalert/rules/*.yml /etc/vmalert/pack/rules.yml' \
        && docker exec "$AM_C" cat /etc/alertmanager/alertmanager.yml; } | sha256sum | cut -c1-12 ) 2>/dev/null ) || return 1
  printf '%s\n' "$h"
}

write_result() {
  [ "$WRITTEN" = 1 ] && return 0
  WRITTEN=1
  local pass=true reasons="[]" exp
  if [ "${#FAILS[@]}" -gt 0 ]; then
    pass=false
    reasons=$(printf '%s\n' "${FAILS[@]}" | jq -R . | jq -s -c .)
  fi
  exp=$(printf '%s\n' "${EXPECT[@]}" | jq -R . | jq -s -c 'map(select(length>0))')
  mkdir -p "$(dirname "$RESULTS")"
  jq -n -c \
    --arg scenario "$SCENARIO" --arg start "$T_START" --arg inject "$T_INJECT" \
    --arg detected "$T_DETECT" --arg resolved "$T_RESOLVE" --arg end "$T_END" \
    --arg tdetect "${S_DETECT:-}" --arg tresolve "${S_RESOLVE:-}" \
    --arg tinject "${S_INJECT:-}" --arg hold "${S_HOLD:-0}" \
    --arg gsha "$(git_sha)" --argjson gdirty "$(git_dirty)" --arg chash "$CONFIG_HASH" \
    --argjson expected "$exp" --argjson unexpected "$UNEXPECTED" \
    --argjson pass "$pass" --argjson reasons "$reasons" \
    --argjson images "$(image_versions)" --arg extra "${EXTRA_JSON:-null}" --argjson crash "$CRASH_RESTARTS" '
    def nz: if . == "" then null else . end;
    {scenario: $scenario, start: ($start|nz), inject: ($inject|nz), detected: ($detected|nz),
     resolved: ($resolved|nz), end: ($end|nz),
     seconds_to_detect: ($tdetect|nz|if . then tonumber else . end),
     seconds_to_resolve: ($tresolve|nz|if . then tonumber else . end),
     inject_seconds: ($tinject|nz|if . then tonumber else . end), hold_seconds: ($hold|tonumber),
     git_sha: $gsha, git_dirty: $gdirty, config_sha256: ($chash|nz),
     expected_alert: $expected, unexpected_alerts: $unexpected,
     pass: $pass, failure_reasons: $reasons, crash_restarts: $crash, extra: ($extra|fromjson), images: $images}' \
    >>"$RESULTS"
  log "result appended to $RESULTS (pass=$pass)"
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  do_revert
  [ -n "$T_START" ] || T_START=$(now_ts)
  [ "$rc" -ne 0 ] && [ "${#FAILS[@]}" -eq 0 ] && FAILS+=("script aborted with status $rc")
  write_result
  [ "${#FAILS[@]}" -eq 0 ] || { printf 'FAIL %s: %s\n' "$SCENARIO" "$(printf '%s; ' "${FAILS[@]}")" >&2; exit 1; }
  exit 0
}

# run_scenario NAME
# Uses: EXPECT, inject(), revert(); optional HOLD_AFTER_DETECT, after_detect()
# and extra_checks(). With an empty EXPECT nothing is waited for (control).
run_scenario() {
  SCENARIO=$1
  trap on_exit EXIT
  trap 'exit 130' INT TERM

  if ! precondition; then FAILS+=("precondition: ${PRE_ERR:-failed}"); exit 1; fi

  T_START=$(now_ts)
  log "scenario $SCENARIO: start; expecting ${EXPECT[*]:-none}"
  T_INJECT=$(now_ts)   # set once: time to detect counts from the start of the fault
  local ti; ti=$(date +%s.%N)
  inject || { FAILS+=("inject failed"); exit 1; }
  S_INJECT=$(awk -v a="$ti" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
  log "injected (inject() took ${S_INJECT}s)"

  if [ "${#EXPECT[@]}" -gt 0 ]; then
    local e name inst t last=""
    for e in "${EXPECT[@]}"; do
      name=${e%%:*}; inst=${e#*:}; [ "$inst" = "$e" ] && inst=""
      t=""
      local t0; t0=$(date +%s)
      while [ -z "$t" ]; do
        t=$(first_record firing "$name" "$inst" "$T_INJECT" || true)
        [ -n "$t" ] && break
        if [ $(($(date +%s) - t0)) -ge "$DETECT_TIMEOUT" ]; then break; fi
        sleep 5
      done
      if [ -z "$t" ]; then FAILS+=("not detected: $e within ${DETECT_TIMEOUT}s"); continue; fi
      log "delivered firing $e at $t"
      if [ -z "$last" ] || later "$t" "$last"; then last=$t; fi
    done
    if [ -n "$last" ]; then T_DETECT=$last; S_DETECT=$(secs "$T_INJECT" "$T_DETECT"); log "time to detect ${S_DETECT}s"; fi
  fi

  if [ -n "$T_DETECT" ] && [ "${#FAILS[@]}" -eq 0 ]; then
    if declare -F after_detect >/dev/null; then after_detect || FAILS+=("after_detect checks failed"); fi
    if [ "$HOLD_AFTER_DETECT" -gt 0 ]; then
      log "holding the fault for ${HOLD_AFTER_DETECT}s"
      sleep "$HOLD_AFTER_DETECT"
      S_HOLD=$HOLD_AFTER_DETECT
    fi
  fi

  T_REVERT=$(now_ts)   # taken before revert: a resolution during revert() still counts
  do_revert

  if [ "${#EXPECT[@]}" -gt 0 ] && [ -n "$T_DETECT" ]; then
    local e name inst t last="" t0
    for e in "${EXPECT[@]}"; do
      name=${e%%:*}; inst=${e#*:}; [ "$inst" = "$e" ] && inst=""
      t=""; t0=$(date +%s)
      while [ -z "$t" ]; do
        t=$(first_record resolved "$name" "$inst" "$T_REVERT" || true)
        [ -n "$t" ] && break
        if [ $(($(date +%s) - t0)) -ge "$RESOLVE_TIMEOUT" ]; then break; fi
        sleep 5
      done
      if [ -z "$t" ]; then FAILS+=("not resolved: $e within ${RESOLVE_TIMEOUT}s after revert"); continue; fi
      log "delivered resolved $e at $t"
      if [ -z "$last" ] || later "$t" "$last"; then last=$t; fi
    done
    if [ -n "$last" ]; then T_RESOLVE=$last; S_RESOLVE=$(secs "$T_REVERT" "$T_RESOLVE"); log "time to resolve ${S_RESOLVE}s (from revert)"; fi
  fi

  # let the system settle so alerts caused by the revert are inside the window
  wait_until "$SETTLE_TIMEOUT" "Alertmanager clean again" am_clean || FAILS+=("Alertmanager not clean after revert: $(am_active | tr '\n' ' ')")
  sleep 25
  T_END=$(now_ts)

  # unexpected = any delivered group (firing or resolved) that is not expected
  local rows
  if ! rows=$(window_alerts "$T_START" "$T_END"); then
    FAILS+=("unexpected-alert query against VictoriaLogs failed")
    rows=""
  fi
  UNEXPECTED=$(printf '%s\n' "$rows" | awk -F'\t' -v want="$(printf '%s,' "${EXPECT[@]}")" '
    NF >= 4 { key = $1 ":" $2; if (index("," want, "," key ",") == 0) print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {alertname: .[0], instance: .[1], status: .[2], count: (.[3]|tonumber)})')
  if [ "$UNEXPECTED" != "[]" ]; then FAILS+=("unexpected alerts delivered: $UNEXPECTED"); fi

  # a scenario must not crash a PostgreSQL server: its postmaster logs this line
  # when a child dies abnormally (an orphan killed by a revert, for example)
  local crash
  if crash=$(vl "_time:>$T_START _time:<=$T_END service.name:=postgresql _msg:=\"all server processes terminated; reinitializing\" | stats count() n" | jq -r '.n // 0'); then
    CRASH_RESTARTS=$crash
    if [ "$crash" != 0 ]; then FAILS+=("PostgreSQL crash restart logged $crash time(s) during the run"); fi
  else
    FAILS+=("crash restart query against VictoriaLogs failed")
  fi

  if declare -F extra_checks >/dev/null; then extra_checks || true; fi
  exit 0
}
