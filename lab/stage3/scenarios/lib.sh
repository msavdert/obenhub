#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared helpers for the stage 3 (Patroni) fault scenarios. Source it from a
# scenario; do not run it. A scenario defines EXPECT, inject() and revert() and
# calls run_scenario (see cluster-paused.sh for the smallest example). The
# bookkeeping part from "run bookkeeping" on is the one in
# lab/slice1/scenarios/lib.sh; it is copied, not sourced, because the top of
# that file is bound to the slice 1 containers, and slice 1 stays unchanged.
# EXPECT may be (re)set inside inject(): the node a scenario picks is only
# known then, and nodes are named, never roles.
#
# Needs: docker, curl, jq, the lab running (mise run lab:stage3:up).
# Sink = VictoriaLogs; every Alertmanager notification is one record whose
# commonLabels.alertname / commonLabels.service_instance_id identify the group.
# Cluster-level alerts have no service_instance_id (expected as "Name:").

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
RESULTS="$LAB_DIR/results/runs.jsonl"
PROJECT=obenhub-stage3
VL=${VL:-http://127.0.0.1:29428}
AM=${AM:-http://127.0.0.1:29093}
VM=${VM:-http://127.0.0.1:28428}
NODES=(pg-1 pg-2 pg-3)
REPL_NET=obenhub-stage3_repl
LOAD=obenhub-stage3-load
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
later() { awk -v a="$(epoch "$1")" -v b="$(epoch "$2")" 'BEGIN{exit !(a>b)}'; }

cname() { printf 'obenhub-stage3-%s' "$1"; }
# static address of a node on the repl network (compose.yaml)
repl_ip() { printf '10.216.0.1%s' "${1#pg-}"; }

# psql as superuser over the node's local socket (trust, no password).
psql_n() { local n=$1; shift; docker exec -i "$(cname "$n")" psql -U postgres -X -v ON_ERROR_STOP=1 -At "$@"; }

# patronictl on the first node that answers (a stopped node cannot).
ptl() {
  local n
  for n in "${NODES[@]}"; do
    docker exec "$(cname "$n")" patronictl "$@" 2>/dev/null && return 0
  done
  return 1
}
# cluster members as JSON (Member, Role, State, TL, Lag in MB, Pending restart)
members() { ptl list -f json; }
leader_name() { members | jq -r '[.[] | select(.Role == "Leader")] | if length == 1 then .[0].Member else empty end'; }
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
# etcd members, queried from whichever member answers (a stopped one cannot).
# `endpoint status` prints one line per answering member:
# endpoint, id, version, storage version, db size, in use, %, quota, is leader, ...
ETCD_MEMBERS=(etcd-1 etcd-2 etcd-3)
ETCD_EPS=http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379
etcd_status() {
  local m out
  for m in "${ETCD_MEMBERS[@]}"; do
    out=$(docker exec "$(cname "$m")" etcdctl --endpoints="$ETCD_EPS" endpoint status 2>/dev/null)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  done
  return 1
}
etcd_leader() { etcd_status | awk -F', ' '$9 == "true" { sub("http://", "", $1); sub(":2379", "", $1); print $1 }'; }
etcd_member_id() { etcd_status | awk -F', ' -v m="http://$1:2379" '$1 == m { print $2 }'; }
# three members answer and exactly one is leader
etcd_healthy() {
  local st; st=$(etcd_status) || return 1
  [ "$(printf '%s\n' "$st" | wc -l)" = 3 ] && [ "$(printf '%s\n' "$st" | awk -F', ' '$9 == "true"' | wc -l)" = 1 ]
}
# etcd_move_leader TARGET: ask the current leader to hand over to TARGET
etcd_move_leader() {
  local l id; l=$(etcd_leader); id=$(etcd_member_id "$1")
  [ -n "$l" ] && [ -n "$id" ] || return 1
  docker exec "$(cname "$l")" etcdctl --endpoints="http://$l:2379" move-leader "$id" >/dev/null
}

load_running() { [ "$(docker inspect -f '{{.State.Running}}' "$LOAD" 2>/dev/null)" = true ]; }

vl() { curl -fsS "$VL/select/logsql/query" --data-urlencode "query=$1"; }

# first_record STATUS ALERTNAME INSTANCE SINCE -> _time of the earliest match
first_record() {
  local q="_time:>$4 status:=$1 commonLabels.alertname:=$2"
  [ -n "$3" ] && q="$q commonLabels.service_instance_id:=$3"
  vl "$q | sort by (_time) | limit 1 | fields _time" | jq -r '._time // empty' | head -n1
}

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

image_versions() {
  { grep -E '^[[:space:]]+image:' "$LAB_DIR/compose.yaml" | sed 's/.*image: *//'; grep -E '^FROM ' "$LAB_DIR/postgres/Dockerfile" | sed 's/^FROM //'; } | sort -u \
    | jq -R . | jq -s -c .
}

# Pre-flight shared by all scenarios.
precondition() {
  wait_until "$SETTLE_TIMEOUT" "only Watchdog active in Alertmanager" am_clean || { PRE_ERR="Alertmanager not clean: $(am_active | tr '\n' ' ')"; return 1; }
  wait_until 120 "etcd healthy (three members, one leader)" etcd_healthy || { PRE_ERR="etcd not healthy"; return 1; }
  wait_until 180 "cluster healthy (one leader, two streaming replicas)" cluster_healthy || { PRE_ERR="cluster not healthy"; return 1; }
  not_paused || { PRE_ERR="cluster is paused"; return 1; }
  load_running || { PRE_ERR="load container not running"; return 1; }
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
EXPECT=()          # entries "AlertName:instance" (instance may be empty)
ALLOW=()           # delivered alerts that are a known consequence of the fault; not waited for, not unexpected

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
  cat "$LAB_DIR"/vmalert/rules/*.yml "$LAB_DIR/alertmanager/alertmanager.yml" 2>/dev/null | sha256sum | cut -c1-12
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
    --arg gsha "$(git_sha)" --argjson gdirty "$(git_dirty)" --arg chash "$(config_hash)" \
    --argjson expected "$exp" --argjson unexpected "$UNEXPECTED" \
    --argjson pass "$pass" --argjson reasons "$reasons" \
    --argjson images "$(image_versions)" --arg extra "${EXTRA_JSON:-null}" '
    def nz: if . == "" then null else . end;
    {scenario: $scenario, start: ($start|nz), inject: ($inject|nz), detected: ($detected|nz),
     resolved: ($resolved|nz), end: ($end|nz),
     seconds_to_detect: ($tdetect|nz|if . then tonumber else . end),
     seconds_to_resolve: ($tresolve|nz|if . then tonumber else . end),
     inject_seconds: ($tinject|nz|if . then tonumber else . end), hold_seconds: ($hold|tonumber),
     git_sha: $gsha, git_dirty: $gdirty, config_sha256: $chash,
     expected_alert: $expected, unexpected_alerts: $unexpected,
     pass: $pass, failure_reasons: $reasons, extra: ($extra|fromjson), images: $images}' \
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
  UNEXPECTED=$(printf '%s\n' "$rows" | awk -F'\t' -v want="$(printf '%s,' "${EXPECT[@]}" "${ALLOW[@]}")" '
    NF >= 4 { key = $1 ":" $2; if (index("," want, "," key ",") == 0) print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {alertname: .[0], instance: .[1], status: .[2], count: (.[3]|tonumber)})')
  if [ "$UNEXPECTED" != "[]" ]; then FAILS+=("unexpected alerts delivered: $UNEXPECTED"); fi

  if declare -F extra_checks >/dev/null; then extra_checks || true; fi
  exit 0
}
