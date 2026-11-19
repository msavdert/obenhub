#!/usr/bin/env bash
# shellcheck disable=SC2034
# Lab-independent machinery of the fault scenarios, shared by the lab adapters
# lab/slice1/scenarios/lib.sh, lab/stage3/scenarios/lib.sh (Compose),
# lab/pgha/scenarios/lib.sh (VMs) and lab/k8s/scenarios/lib.sh.
# Source it from a lab adapter, never from a scenario and never run it. A
# scenario defines EXPECT, inject() and revert() and calls run_scenario (see
# lab/stage3/scenarios/cluster-paused.sh for the smallest example). EXPECT may
# be (re)set inside inject(): the node a scenario picks is only known then,
# and nodes are named, never roles.
#
# Slice 1 has no Patroni: its adapter defines only what its scenarios use and
# leaves the Patroni and etcd helpers below undefined (they are called at run
# time, by scenarios that need them).
#
# Every record carries `suite` (SUITE_ID exported by lab/scenarios/run-suite.sh,
# null for a single scenario run) and `detected_at` (EXPECT entry as written ->
# time of its first firing notification, null when never seen). A scenario
# refuses to start while another run, suite or single, holds the host-wide lock
# (guard.sh).
#
# Sink = VictoriaLogs; every Alertmanager notification is one record whose
# commonLabels.alertname / commonLabels.service_instance_id identify the group.
# Cluster-level alerts have no service_instance_id (expected as "Name:").
#
# Contract: the adapter sets these BEFORE sourcing this file
#   LAB_DIR        lab directory (git provenance, config files)
#   RESULTS        runs.jsonl path
#   VL AM VM VMALERT   backend URLs
#   VMALERT_C AM_C     container names, for the loaded-config hash
#   CONFIG_FILES   array: the repository's alerting config files, in the
#                  order the containers read them (config_hash)
#   NODES          array of node names
#   CLUSTER        Patroni scope
#   ETCD_MEMBERS   array of etcd member names (as they appear as
#                  service.instance.id)
# and may set these
#   VMALERT_LOADED_CAT  shell command run in the vmalert container that prints
#                  the files of CONFIG_FILES that vmalert reads, in the same
#                  order (default: inventory.yml, then pack/*.yml)
#   CRASH_RESTARTS initial value of the optional crash_restarts field, a JSON
#                  value (e.g. null); the field is omitted when unset
# and defines these functions (before or after, they are called at run time)
#   ptl ARGS...        patronictl on the first node that answers
#   psql_n NODE ARGS.. psql as superuser on the node's local socket
#   etcd_status        one line per answering member, first field the member
#                      name, then the etcdctl `endpoint status` columns
#                      (id, version, storage version, db size, in use, %,
#                      quota, is leader, ...)
#   etcd_move_leader TARGET
#   load_running       the load generator runs on every node that needs it
#   component_versions JSON array of component version strings
#   lab_precondition   lab part of the pre-flight (sets PRE_ERR, returns 1)
# and optionally
#   running_images     one line per running container: NAME, running image
#                      ID or digest, declared one (tab separated, no empty
#                      field in the middle; the declared one empty = record
#                      only); the precondition fails when they differ and the
#                      record carries the rows as running_images. Labs without
#                      it keep recording what component_versions says.
#   lab_final_checks   run after the unexpected-alert check, before extra_checks
#
# Needs: curl, jq, the lab running.

# shellcheck source=lab/scenarios/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard.sh"

VMALERT_LOADED_CAT=${VMALERT_LOADED_CAT:-cat /etc/vmalert/inventory.yml /etc/vmalert/pack/*.yml}
DETECT_TIMEOUT=${DETECT_TIMEOUT:-600}
# optional cap in seconds from the injection for the whole detection phase (all EXPECT entries together); empty = only the per-alert DETECT_TIMEOUT
DETECT_DEADLINE=${DETECT_DEADLINE:-}
RESOLVE_TIMEOUT=${RESOLVE_TIMEOUT:-600}
SETTLE_TIMEOUT=${SETTLE_TIMEOUT:-300}

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
now_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
epoch() { date -u -d "$1" +%s.%N; }
secs() { awk -v a="$(epoch "$1")" -v b="$(epoch "$2")" 'BEGIN{printf "%.1f", b-a}'; }
later() { awk -v a="$(epoch "$1")" -v b="$(epoch "$2")" 'BEGIN{exit !(a>b)}'; }

# cluster members as JSON (Member, Role, State, TL, Lag in MB, Pending restart)
members() { ptl list -f json; }
leader_name() { members | jq -r '[.[] | select(.Role == "Leader")] | if length == 1 then .[0].Member else empty end'; }
# leader_or NAME: the current leader, or NAME when there is none (leader_name
# succeeds with empty output then, so `leader_name || echo` would not fall back)
leader_or() { local l; l=$(leader_name); echo "${l:-$1}"; }
first_replica() { members | jq -r '[.[] | select(.Role != "Leader")] | .[0].Member // empty'; }
timeline() { members | jq -r '[.[] | select(.Role == "Leader")][0].TL // empty'; }
# three members, one running leader, two streaming replicas, no pending restart
cluster_healthy() {
  members | jq -e '
    length == 3
    and ([.[] | select(.Role == "Leader" and .State == "running")] | length) == 1
    and ([.[] | select(.Role != "Leader" and .State == "streaming")] | length) == 2
    and ([.[] | select(has("Pending restart"))] | length) == 0' >/dev/null
}
cluster_paused() { ptl list 2>/dev/null | grep -q 'Maintenance mode: on'; }
not_paused() { ! cluster_paused; }
# etcd members. etcd_status is the adapter's (see the contract above).
etcd_leader() { etcd_status | awk -F', ' '$9 == "true" { print $1 }'; }
etcd_member_id() { etcd_status | awk -F', ' -v m="$1" '$1 == m { print $2 }'; }
# three members answer and exactly one is leader
etcd_healthy() {
  local st; st=$(etcd_status) || return 1
  [ "$(printf '%s\n' "$st" | wc -l)" = 3 ] && [ "$(printf '%s\n' "$st" | awk -F', ' '$9 == "true"' | wc -l)" = 1 ]
}

vl() { curl -fsS "$VL/select/logsql/query" --data-urlencode "query=$1"; }

# first_record STATUS ALERTNAME INSTANCE SINCE -> _time of the earliest match
first_record() {
  local q="_time:>$4 status:=$1 commonLabels.alertname:=$2"
  [ -n "$3" ] && q="$q commonLabels.service_instance_id:=$3"
  vl "$q | sort by (_time) | limit 1 | fields _time" | jq -r '._time // empty' | head -n1
}

# last_record STATUS ALERTNAME INSTANCE SINCE -> _time of the latest match
last_record() {
  local q="_time:>$4 status:=$1 commonLabels.alertname:=$2"
  [ -n "$3" ] && q="$q commonLabels.service_instance_id:=$3"
  vl "$q | sort by (_time desc) | limit 1 | fields _time" | jq -r '._time // empty' | head -n1
}
# resolution_record ALERTNAME INSTANCE SINCE -> _time of the first resolved
# record after SINCE that no firing record follows (a resolve that is
# followed by a new firing is not a resolution); empty while there is none
resolution_record() {
  local f
  f=$(last_record firing "$1" "$2" "$3") || return 1
  first_record resolved "$1" "$2" "${f:-$3}"
}

# vl_count QUERY -> number of records QUERY selects
vl_count() {
  local out n
  out=$(vl "$1 | stats count() n") || return 1
  n=$(printf '%s\n' "$out" | jq -r '.n') || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}
# extra_set KEY JSON: add a field to the record's "extra"
extra_set() { EXTRA_JSON=$(jq -c --arg k "$1" --argjson v "$2" '(. // {}) + {($k): $v}' <<<"${EXTRA_JSON:-null}"); }

# am_active -> names of alerts that are active and not inhibited or silenced
am_active() {
  curl -fsS "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false" \
    | jq -r '.[] | .labels.alertname + (if .labels.service_instance_id then ":" + .labels.service_instance_id else "" end)' | sort
}
am_clean() { [ "$(am_active)" = "Watchdog" ]; }

# vm_query EXPR -> first value of an instant query, empty when none
vm_query() { curl -fsS "$VM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'; }
# primary_gap_seconds SINCE_EPOCH: seconds (15 s steps) with no node reporting itself primary
primary_gap_seconds() {
  local now; now=$(date +%s)
  curl -fsS "$VM/api/v1/query_range" --data-urlencode 'query=sum(patroni_primary)' \
    --data-urlencode "start=$1" --data-urlencode "end=$now" --data-urlencode step=15 \
    | jq '[.data.result[0].values[] | select(.[1] == "0")] | length * 15'
}

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

# What runs is what the files declare: running_images (adapter, optional)
# lists every running container with the image it runs and the one the
# repository declares; a difference fails the pre-flight. Without the hook
# the record only carries the declared references (component_versions).
RUNNING_IMAGES=null   # JSON array {name, running, declared}; null = not checked
check_running_images() {
  declare -F running_images >/dev/null || return 0
  local rows name run decl bad=""
  rows=$(running_images) || { PRE_ERR="cannot read the running images"; return 1; }
  [ -n "$rows" ] || { PRE_ERR="no running container found for the declared services"; return 1; }
  RUNNING_IMAGES=$(printf '%s\n' "$rows" | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {name: .[0], running: .[1], declared: ((.[2] // "") | if . == "" then null else . end)})') || { PRE_ERR="cannot parse the running images"; return 1; }
  while IFS=$'\t' read -r name run decl; do
    [ -n "$name" ] && [ -n "$decl" ] || continue
    [ "$run" = "$decl" ] || bad="$bad${bad:+; }$name runs $run, declared $decl"
  done <<<"$rows"
  [ -z "$bad" ] || { PRE_ERR="running image differs from the declared one: $bad"; return 1; }
}
# running_images for the Compose labs (slice1, stage3): needs dc and PROJECT.
# Running container image ID against the ID the tag in the Compose file has now
# (a rebuilt obenhub-* image or a re-pulled tag moves its ID). Assumption: the
# ID `docker inspect` gives a container equals the `docker image inspect` ID of
# the same image (checked 2026-11-19 on the box's containerd image store for
# every running slice1 and stage3 service).
compose_running_images() {
  local cfg svc ref cid run decl
  cfg=$(dc config --format json) || return 1
  while IFS=$'\t' read -r svc ref; do
    [ -n "$ref" ] || ref="$PROJECT-$svc"
    decl=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null) || decl=missing
    for cid in $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$svc"); do
      run=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null) || run=""
      printf '%s\t%s\t%s\n' "$svc" "${run:-none}" "$decl"
    done
  done < <(jq -r '.services | to_entries[] | [.key, (.value.image // "")] | @tsv' <<<"$cfg")
}

# Pre-flight shared by all scenarios; lab_precondition is the adapter's part
# (etcd, cluster, pause state, load; sets PRE_ERR and returns 1 on failure).
precondition() {
  check_running_images || return 1
  reload_config || return 1
  wait_until "$SETTLE_TIMEOUT" "only Watchdog active in Alertmanager" am_clean || { PRE_ERR="Alertmanager not clean: $(am_active | tr '\n' ' ')"; return 1; }
  lab_precondition || return 1
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
CRASH_RESTARTS=${CRASH_RESTARTS-}   # PostgreSQL crash restarts logged during the run; empty = field not recorded, null = not checked
# One unexpected-alert window over a whole suite: run-suite.sh creates
# SUITE_STATE_FILE with the suite start; every scenario reads the previous
# scenario's end and its EXPECT and ALLOW from it, and rewrites it with its own
# T_END, so the gap between two scenarios (the next pre-flight included) is in
# some scenario's window. A resolved notification of the previous scenario's
# alerts may land in that gap and is allowed (anywhere in the window, not only
# the gap); a firing record of them there is not. Outside a suite the window
# starts at T_START.
SUITE_STATE_FILE=${SUITE_STATE_FILE:-}
WINDOW_START="" PREV_ALLOW=""
RESOLVED_BEFORE_REVERT=""   # true when the resolution came before the revert
DETECTED_AT="{}"   # EXPECT entry -> first firing notification time
SUITE_ID=${SUITE_ID:-}   # set by run-suite.sh; empty = single scenario run
EXPECT=()          # entries "AlertName:instance" (instance may be empty)
ALLOW=()           # delivered alerts that are a known consequence of the fault; not waited for, not unexpected

# Nothing to revert before inject() started (a failed pre-flight leaves the
# lab as it found it). REVERTED is set only after revert() returned, so a
# revert interrupted by a signal runs again from on_exit.
do_revert() {
  [ "$REVERTED" = 1 ] && return 0
  if [ -z "$T_INJECT" ]; then REVERTED=1; log "no fault injected, no revert"; return 0; fi
  log "revert"
  revert || FAILS+=("revert failed")
  REVERTED=1
}

# window_alerts SINCE UNTIL -> TSV: alertname instance status count, no Watchdog
# Fails (non-zero, no output) when the query or its parsing fails; zero rows
# is a success with empty output.
window_alerts() {
  local out
  out=$(vl "_time:>$1 _time:<=$2 status:* -commonLabels.alertname:=Watchdog | stats by (commonLabels.alertname, commonLabels.service_instance_id, status) count() n") || return 1
  printf '%s\n' "$out" | jq -r '[.["commonLabels.alertname"], (.["commonLabels.service_instance_id"] // ""), .status, .n] | @tsv'
}

read_suite_state() {
  [ -n "$SUITE_STATE_FILE" ] || return 0
  WINDOW_START=$(jq -er '.end' "$SUITE_STATE_FILE" 2>/dev/null) || return 1
  PREV_ALLOW=$(jq -er '.allow | join(",")' "$SUITE_STATE_FILE" 2>/dev/null) || return 1
}
write_suite_state() {
  [ -n "$SUITE_STATE_FILE" ] || return 0
  printf '%s\n' "${EXPECT[@]}" "${ALLOW[@]}" | jq -R . \
    | jq -s -c --arg end "$T_END" '{end: $end, allow: map(select(length>0))}' >"$SUITE_STATE_FILE.tmp" \
    && mv "$SUITE_STATE_FILE.tmp" "$SUITE_STATE_FILE" || FAILS+=("cannot write the suite state file $SUITE_STATE_FILE")
}

# Sink probe (control): a synthetic alert goes to Alertmanager and must come
# back as a firing and a resolved record in VictoriaLogs, which proves the
# notification path (Alertmanager, webhook, VictoriaLogs) is alive and that the
# unexpected-alert check could have seen something. Start it early in
# inject(), call sink_probe_check from extra_checks, and ALLOW
# ObenhubSinkProbe: in the scenario.
SINK_PROBE_TIMEOUT=${SINK_PROBE_TIMEOUT:-90}
SINK_PROBE_SINCE="" SINK_PROBE_RUN=""
sink_probe_start() {
  local ends
  ends=$(date -u -d '+30 seconds' +%Y-%m-%dT%H:%M:%S.%3NZ)
  SINK_PROBE_RUN="${SUITE_ID:-single}/$SCENARIO"
  SINK_PROBE_SINCE=$(now_ts)
  if ! jq -n -c --arg run "$SINK_PROBE_RUN" --arg s "$SINK_PROBE_SINCE" --arg e "$ends" \
      '[{labels: {alertname: "ObenhubSinkProbe", probe_run: $run}, annotations: {summary: "synthetic alert of the scenario harness"}, startsAt: $s, endsAt: $e}]' \
      | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$AM/api/v2/alerts" >/dev/null; then
    FAILS+=("sink probe: Alertmanager did not accept the synthetic alert")
    SINK_PROBE_SINCE=""
  fi
}
sink_probe_seen() { # STATUS
  [ -n "$(vl "_time:>$SINK_PROBE_SINCE status:=$1 commonLabels.alertname:=ObenhubSinkProbe commonLabels.probe_run:=\"$SINK_PROBE_RUN\" | limit 1 | fields _time" | head -n1)" ]
}
sink_probe_check() {
  [ -n "$SINK_PROBE_SINCE" ] || { [ "${#FAILS[@]}" -gt 0 ] || FAILS+=("sink probe was not started"); return 0; }
  local t0 f=0 r=0
  t0=$(date +%s)
  while :; do
    [ "$f" = 1 ] || { sink_probe_seen firing && f=1; } || true
    [ "$r" = 1 ] || { sink_probe_seen resolved && r=1; } || true
    [ "$f" = 1 ] && [ "$r" = 1 ] && break
    [ $(($(date +%s) - t0)) -lt "$SINK_PROBE_TIMEOUT" ] || break
    sleep 5
  done
  if [ "$f" = 1 ] && [ "$r" = 1 ]; then
    extra_set sink_probe true
    log "sink probe: firing and resolved record found"
  else
    extra_set sink_probe false
    FAILS+=("sink probe: no $([ "$f" = 1 ] || echo firing)$([ "$f$r" = 00 ] && echo ' and ')$([ "$r" = 1 ] || echo resolved) record in VictoriaLogs within ${SINK_PROBE_TIMEOUT}s")
  fi
}
# pg_log_records_check [SERVICE]: control proves the log path of the database
# (default service.name postgresql): at least one record in the run's window
pg_log_records_check() {
  local svc=${1:-postgresql} n
  if ! n=$(vl_count "_time:>$T_START _time:<=$T_END service.name:=$svc"); then
    FAILS+=("$svc log records: VictoriaLogs query failed or unparsable")
    return 0
  fi
  log "$svc log records in the window: $n"
  extra_set "${svc}_log_records" "$n"
  [ "$n" -gt 0 ] || FAILS+=("no $svc log records in the window: the log path is not alive")
}

# provenance: git_sha and git_dirty (guard.sh: dirty = changes outside
# lab/*/results/), hash of the alerting configuration
config_hash() {
  ( export LC_ALL=C
    cat "${CONFIG_FILES[@]}" 2>/dev/null | sha256sum | cut -c1-12 )
}
# The same files as the containers see them, in the same order (the vmalert
# pack files sort by name, the order each adapter's CONFIG_FILES lists them in;
# VMALERT_LOADED_CAT says where the container reads them). No output and status 1
# when a container cannot be read.
loaded_config_hash() {
  local h
  h=$( ( set -o pipefail
    { docker exec "$VMALERT_C" sh -c "export LC_ALL=C; $VMALERT_LOADED_CAT" \
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
    --argjson components "$(component_versions)" --argjson running "$RUNNING_IMAGES" --arg wstart "$WINDOW_START" --arg rbr "$RESOLVED_BEFORE_REVERT" --arg extra "${EXTRA_JSON:-null}" \
    --arg suite "$SUITE_ID" --arg ssize "${SUITE_SIZE:-}" --argjson det "$DETECTED_AT" --arg crash "$CRASH_RESTARTS" '
    def nz: if . == "" then null else . end;
    {scenario: $scenario, start: ($start|nz), inject: ($inject|nz), detected: ($detected|nz),
     resolved: ($resolved|nz), end: ($end|nz),
     seconds_to_detect: ($tdetect|nz|if . then tonumber else . end),
     seconds_to_resolve: ($tresolve|nz|if . then tonumber else . end),
     inject_seconds: ($tinject|nz|if . then tonumber else . end), hold_seconds: ($hold|tonumber),
     git_sha: $gsha, git_dirty: $gdirty, config_sha256: ($chash|nz),
     expected_alert: $expected, unexpected_alerts: $unexpected,
     pass: $pass, failure_reasons: $reasons, extra: ($extra|fromjson), images: $components,
     running_images: $running, window_start: ($wstart|nz), resolved_before_revert: ($rbr|nz|if . then (. == "true") else . end),
     suite: ($suite|nz), suite_size: ($ssize|nz|if . then tonumber else . end), detected_at: (reduce $expected[] as $e ({}; .[$e] = ($det[$e] // null)))}
    + (if $crash == "" then {} else {crash_restarts: ($crash|fromjson)} end)' \
    >>"$RESULTS"
  log "result appended to $RESULTS (pass=$pass)"
}

on_exit() {
  local rc=$?
  # INT, TERM and HUP are ignored from here on: a second Ctrl-C or a closed
  # terminal must not cut the revert short and leave the fault in place
  # (SIGKILL still stops it)
  trap - EXIT
  trap '' INT TERM HUP
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
  # one run at a time on the host (guard.sh): inside a suite SUITE_ID is kept,
  # otherwise the lock is taken here and the run is a smoke run (suite null)
  scenario_lock || { echo "refusing to start $SCENARIO: another lab run holds $SUITE_LOCK_FILE" >&2; exit 3; }
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  [ -n "$SUITE_ID" ] || SUITE_STATE_FILE=""
  read_suite_state || { FAILS+=("cannot read the suite state file $SUITE_STATE_FILE"); exit 1; }

  if ! precondition; then FAILS+=("precondition: ${PRE_ERR:-failed}"); exit 1; fi

  T_START=$(now_ts)
  [ -n "$WINDOW_START" ] || WINDOW_START=$T_START
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
        if [ -n "$DETECT_DEADLINE" ] && [ $(($(date +%s) - ${ti%.*})) -ge "$DETECT_DEADLINE" ]; then break; fi
        sleep 5
      done
      if [ -z "$t" ]; then FAILS+=("not detected: $e within ${DETECT_DEADLINE:-$DETECT_TIMEOUT}s"); continue; fi
      log "delivered firing $e at $t"
      DETECTED_AT=$(jq -c --arg k "$e" --arg v "$t" '.[$k] = $v' <<<"$DETECTED_AT")
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
    # searched from the alert's own detection: an alert that resolved before the
    # revert (or during it) counts, a resolve followed by a new firing does not
    local e name inst t last="" t0 since
    for e in "${EXPECT[@]}"; do
      name=${e%%:*}; inst=${e#*:}; [ "$inst" = "$e" ] && inst=""
      since=$(jq -r --arg k "$e" '.[$k] // empty' <<<"$DETECTED_AT"); [ -n "$since" ] || since=$T_DETECT
      t=""; t0=$(date +%s)
      while [ -z "$t" ]; do
        t=$(resolution_record "$name" "$inst" "$since" || true)
        [ -n "$t" ] && break
        if [ $(($(date +%s) - t0)) -ge "$RESOLVE_TIMEOUT" ]; then break; fi
        sleep 5
      done
      if [ -z "$t" ]; then FAILS+=("not resolved: $e within ${RESOLVE_TIMEOUT}s after revert"); continue; fi
      log "delivered resolved $e at $t"
      if [ -z "$last" ] || later "$t" "$last"; then last=$t; fi
    done
    if [ -n "$last" ]; then T_RESOLVE=$last; S_RESOLVE=$(secs "$T_REVERT" "$T_RESOLVE"); log "time to resolve ${S_RESOLVE}s (from revert)"
      if later "$T_REVERT" "$T_RESOLVE"; then RESOLVED_BEFORE_REVERT=true; else RESOLVED_BEFORE_REVERT=false; fi
    fi
  fi

  # let the system settle so alerts caused by the revert are inside the window
  wait_until "$SETTLE_TIMEOUT" "Alertmanager clean again" am_clean || FAILS+=("Alertmanager not clean after revert: $(am_active | tr '\n' ' ')")
  sleep 25
  T_END=$(now_ts)
  write_suite_state

  # unexpected = any delivered group (firing or resolved) that is not expected,
  # from the end of the previous scenario of the suite (WINDOW_START)
  local rows
  if ! rows=$(window_alerts "$WINDOW_START" "$T_END"); then
    FAILS+=("unexpected-alert query against VictoriaLogs failed")
    rows=""
  fi
  UNEXPECTED=$(printf '%s\n' "$rows" | awk -F'\t' -v want="$(printf '%s,' "${EXPECT[@]}" "${ALLOW[@]}")" -v prev="$PREV_ALLOW" '
    NF >= 4 { key = $1 ":" $2; if (index("," want, "," key ",") == 0 && !($3 == "resolved" && index("," prev ",", "," key ",") > 0)) print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {alertname: .[0], instance: .[1], status: .[2], count: (.[3]|tonumber)})')
  if [ "$UNEXPECTED" != "[]" ]; then FAILS+=("unexpected alerts delivered: $UNEXPECTED"); fi

  if declare -F lab_final_checks >/dev/null; then lab_final_checks || true; fi

  if declare -F extra_checks >/dev/null; then extra_checks || true; fi
  exit 0
}
