# shellcheck shell=bash
# shellcheck disable=SC2154  # p_*, project, tcol are set by the sourcing script
# SPDX-License-Identifier: Apache-2.0
# Code both install tests of deploy/ share (roadmap G1): install-test.sh (the
# Collector as a container) and vm-test.sh (the Collector as a host binary on
# another machine). Sourced, not run. What is here is the throwaway backend of
# deploy/compose, the settle wait, the assertions (heartbeat, firing alerts,
# dead-man cadence, dashboard panels) and the summary and runs.jsonl line that
# the EXIT trap writes. Everything about the target (what is installed, how the
# Collector runs, how it is torn down) stays in the two scripts.
#
# A script that sources this file sets TEST_NAME, then calls lib_init, and sets
#   project            compose project name (TEST_NAME names the evidence line's test)
#   p_grafana p_vm p_vl p_vmalert p_am p_gw   host ports of the backend
#   EVIDENCE_IMAGES    space separated images to add to the line's "images"
#   EVIDENCE_EXTRA     JSON object merged into the line (default {})
# and defines teardown(), called from the EXIT trap before the summary and the
# evidence row (a teardown failure calls fail and so fails the run), and
# collector_alive / collector_diag for settle_wait.
# Shared state is global on purpose: the evidence row reads it from the EXIT
# trap, so a run that aborts early still produces a complete failed row.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# lib_init: temporary directory, counters, traps. The caller has set
# `set -euo pipefail` and TEST_NAME (install-test, vm-test).
lib_init() {
  set -E   # the ERR trap below must fire inside functions too (errtrace)
  t0=$(date +%s)
  tmp="$(mktemp -d)"
  cdir="$tmp/deploy/compose"
  failures=()
  max_for=0 settle=0 hb=0 firing="" pending="" ever_firing="" dm_n=0 gaps="" dm_age=-1
  p_ok=0 p_empty=0 p_fail=0 p_legit=0 empty_names='[]'
  finished=false
  completed=false
  aborted=""
  sig=""
  total_panels=0
  EVIDENCE_IMAGES="${EVIDENCE_IMAGES:-}"
  [ -n "${EVIDENCE_EXTRA:-}" ] || EVIDENCE_EXTRA='{}'
  trap 'aborted="line $LINENO: $BASH_COMMAND"' ERR
  # a signal ends the run as a failure; the EXIT trap still reports and tears down
  trap 'sig=SIGINT; exit 130' INT
  trap 'sig=SIGTERM; exit 143' TERM
  trap 'sig=SIGHUP; exit 129' HUP
  trap finish EXIT
}

fail() { failures+=("$1"); echo "FAIL: $1" >&2; }
log() { echo "[$(( $(date +%s) - t0 ))s] $*"; }

# lib_check_ports <hint>: refuse to start when a port of the backend is taken
lib_check_ports() {
  local p
  for p in "$p_grafana" "$p_vm" "$p_vl" "$p_vmalert" "$p_am" "$p_gw"; do
    if ss -ltn | awk '{print $4}' | grep -q ":$p\$"; then echo "$TEST_NAME: port $p is in use; $1" >&2; exit 2; fi
  done
}

# The summary line and the evidence row are written from the EXIT trap, so a
# command that fails under set -e (docker, curl -f, ...) still produces both.
finish() {
  local rc=$?
  set +e
  if ! $finished; then
    finished=true
    [ -z "$sig" ] || fail "interrupted by $sig (exit $rc)"
    [ -z "$aborted" ] || fail "aborted at $aborted (exit $rc)"
    # pass needs the script to have reached its last line
    $completed || [ ${#failures[@]} -gt 0 ] || fail "did not complete (exit $rc)"
    # teardown first: a failure of it must reach the summary and the evidence row
    teardown
    summarize
  fi
  if [ ${#failures[@]} -gt 0 ]; then
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
  fi
}
summarize() {
  local outcome=pass dur evvar=${TEST_NAME^^}
  evvar=${evvar//-/_}
  { $completed && [ ${#failures[@]} -eq 0 ]; } || outcome=fail
  dur=$(( $(date +%s) - t0 ))
  # INSTALL_TEST_EVIDENCE / VM_TEST_EVIDENCE=0 and *_SETTLE set: no evidence line
  local ev="${evvar}_EVIDENCE" st="${evvar}_SETTLE"
  if [ "${!ev:-1}" != 0 ] && [ -z "${!st:-}" ]; then
    write_evidence "$outcome" "$dur"
  fi
  if [ "$outcome" = pass ]; then
    echo "$TEST_NAME: PASS in ${dur}s, firing [$firing] (firing after startup besides Watchdog: [$ever_firing]), deadman x$dm_n newest ${dm_age}s old, panels ok=$p_ok empty=$p_empty accepted-empty=$p_legit fail=$p_fail, settle ${settle}s"
  else
    echo "$TEST_NAME: FAIL in ${dur}s (${#failures[@]}): $(IFS=';'; echo "${failures[*]}")" >&2
  fi
}
write_evidence() {
  local sha dirty
  mkdir -p "$repo/deploy/results"
  sha=$(git -C "$repo" rev-parse --short HEAD)
  dirty=false; [ -z "$(git -C "$repo" status --porcelain -- deploy packs scripts mise.toml lab/mon/grafana)" ] || dirty=true
  jq -nc --arg test "$TEST_NAME" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$sha" --argjson dirty "$dirty" --arg outcome "$1" \
    --arg firing "$firing" --arg pending "$pending" --arg ever "$ever_firing" --argjson dmn "$dm_n" --arg gaps "${gaps# }" --argjson dm_age_s "$dm_age" \
    --argjson ok "$p_ok" --argjson empty "$p_empty" --argjson legit "$p_legit" --argjson pfail "$p_fail" --argjson empty_names "$empty_names" \
    --argjson settle "$settle" --argjson maxfor "$max_for" --argjson dur "$2" --argjson hb "${hb:-0}" \
    --arg fails "$(IFS=';'; echo "${failures[*]:-}")" --arg extra_images "$EVIDENCE_IMAGES" --argjson extra "$EVIDENCE_EXTRA" \
    --arg images "$(grep -o 'image: *[^ ]*' "$repo/deploy/compose/compose.yaml" | sed 's/image: *//' | sort -u | tr '\n' ' ')" '
    {test: $test, ts: $ts, git_sha: $sha, git_dirty: $dirty, pass: ($outcome == "pass"), outcome: $outcome,
     failure_reasons: ($fails | split(";") | map(select(. != ""))),
     heartbeat_series: $hb, firing_alerts: ($firing | split(",") | map(select(. != ""))),
     pending_alerts: ($pending | split(",") | map(select(. != ""))),
     firing_after_startup_besides_watchdog: ($ever | split(",") | map(select(. != ""))),
     deadman_notifications: $dmn, deadman_gaps_seconds: ($gaps | split(" ") | map(select(. != "") | tonumber)),
     deadman_newest_age_seconds: $dm_age_s,
     panels_ok: $ok, panels_empty_allowed: $empty, panels_empty_accepted: $legit, panels_failed: $pfail, panels_empty_titles: $empty_names,
     max_for_seconds: $maxfor, settle_seconds: $settle, duration_seconds: $dur,
     images: (($extra_images | split(" ") | map(select(. != ""))) + ($images | split(" ") | map(select(. != ""))) | unique)} + $extra' >>"$repo/deploy/results/runs.jsonl"
}

# backend_up <tls.sh names...>: a fresh copy of deploy/compose under $tmp (the
# checkout stays clean), certificates for the names given, .env with the ports
# p_*, the gateway bound to $gateway_bind (default 127.0.0.1), compose up --wait.
backend_up() {
  local gpw
  mkdir -p "$tmp/deploy" "$tmp/lab/mon"
  cp -r "$repo/deploy/compose" "$tmp/deploy/"
  ln -s "$repo/packs" "$tmp/packs"
  ln -s "$repo/lab/mon/grafana" "$tmp/lab/mon/grafana"
  gpw="$(openssl rand -hex 12)"
  (
    cd "$cdir" || exit 1
    bash tls.sh "$@" >/dev/null
    cp .env.example .env
    sed -i -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$gpw/" \
      -e "s/^OBENHUB_UID=.*/OBENHUB_UID=$(id -u)/" -e "s/^OBENHUB_GID=.*/OBENHUB_GID=$(id -g)/" \
      -e "s/^OBENHUB_GRAFANA_PORT=.*/OBENHUB_GRAFANA_PORT=$p_grafana/" -e "s/^OBENHUB_VM_PORT=.*/OBENHUB_VM_PORT=$p_vm/" \
      -e "s/^OBENHUB_VL_PORT=.*/OBENHUB_VL_PORT=$p_vl/" -e "s/^OBENHUB_VMALERT_PORT=.*/OBENHUB_VMALERT_PORT=$p_vmalert/" \
      -e "s/^OBENHUB_ALERTMANAGER_PORT=.*/OBENHUB_ALERTMANAGER_PORT=$p_am/" -e "s/^OBENHUB_GATEWAY_PORT=.*/OBENHUB_GATEWAY_PORT=$p_gw/" \
      -e "s/^OBENHUB_GATEWAY_BIND=.*/OBENHUB_GATEWAY_BIND=${gateway_bind:-127.0.0.1}/" .env
  )
  log "backend: docker compose up"
  (cd "$cdir" && docker compose -p "$project" up -d --wait) >"$tmp/compose-up.log" 2>&1 || { cat "$tmp/compose-up.log" >&2; fail "docker compose up --wait"; }
}

backend_down() {
  [ -d "$cdir" ] && (cd "$cdir" && docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1)
}

# settle_wait <alive command> <diagnostics command>: the longest `for:` among
# the rules that can fire here, plus a margin, counted from $tcol (the
# Collector's start). Packs loaded with data: collector, host, postgresql.
# Other packs' rules watch components this setup does not run. Margin 120 s
# (assumption: vmalert evaluates every 15 s, Alertmanager group_wait 5 s, scrape
# and export lag). <alive command> failing ends the wait with a failure.
settle_wait() {
  local evvar=${TEST_NAME^^} st
  evvar=${evvar//-/_}
  st="${evvar}_SETTLE"
  max_for=$(grep -h '^ *for: *[0-9]' "$repo"/packs/{collector,host,postgresql}/rules.yml | sed 's/^ *for: *"\{0,1\}\([0-9]*\)\([sm]\).*/\1 \2/' |
    awk '{ s = ($2 == "m") ? $1 * 60 : $1; if (s > m) m = s } END { print m }')
  settle=$((max_for + 120))
  if [ -n "${!st:-}" ]; then settle=${!st}; fi
  log "settle: longest for: of the loaded packs is ${max_for}s, waiting ${settle}s from Collector start"
  while [ $(( $(date +%s) - tcol )) -lt "$settle" ]; do
    "$1" || { fail "host Collector exited"; "$2" >&2 || true; break; }
    sleep 15
  done
}

# assert_backend: heartbeat, firing alerts, alert history, dead-man cadence.
# Needs t0, tcol and the p_* ports.
assert_backend() {
  vm="http://127.0.0.1:$p_vm" vl="http://127.0.0.1:$p_vl" vma="http://127.0.0.1:$p_vmalert" gf="http://127.0.0.1:$p_grafana"

  # heartbeat
  hb=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode 'query=count(last_over_time({__name__="postgresql.collection.heartbeat","service.instance.id"="pg-1","obenhub.cluster.name"="main"}[2m]))' | jq -r '.data.result[0].value[1] // "0"')
  if [ "$hb" = 1 ]; then log "heartbeat of pg-1 (cluster main): present"; else fail "no postgresql.collection.heartbeat of pg-1 in the last 2m"; fi

  # alerts: only Watchdog may fire, and nothing may be pending
  local alerts ever startup_grace=120 name inst last off dm prev e g
  alerts=$(curl -fsS --max-time 20 "$vma/api/v1/alerts")
  firing=$(jq -r '[.data.alerts[] | select(.state == "firing") | .name] | sort | join(",")' <<<"$alerts")
  pending=$(jq -r '[.data.alerts[] | select(.state == "pending") | .name] | sort | join(",")' <<<"$alerts")
  log "firing: [$firing] pending: [$pending]"
  if [ "$firing" != Watchdog ]; then
    fail "firing set is [$firing], want [Watchdog]"
    jq -c '.data.alerts[] | select(.name != "Watchdog") | {name, state, labels, expression}' <<<"$alerts" >&2
  fi
  if [ -n "$pending" ]; then
    fail "pending alerts [$pending] (a longer for: would hide them as not yet firing)"
    jq -c '.data.alerts[] | select(.state == "pending") | {name, state, labels, expression}' <<<"$alerts" >&2
  fi
  # History, not a snapshot: vmalert writes ALERTS{alertstate="firing"} to
  # VictoriaMetrics (-remoteWrite.url in compose.yaml), so an alert that fired and
  # resolved during the run is still there. Every alert but Watchdog fails the
  # test, with one exception: CollectorAbsent of the host Collector
  # (service.instance.id otelcol-host-1, as in deploy/compose/inventory.yml) may
  # fire until STARTUP_GRACE seconds after that Collector starts. In a fresh
  # install the inventory expects a Collector that has not reported yet (debug
  # run: firing from 41 s before to 19 s after its start; offsets are printed).
  # The grace of 120 s is an assumption with that margin. Sample timestamps come
  # from /api/v1/export: timestamp() over last_over_time returned step-aligned
  # values that did not match them.
  ever=$(curl -fsS --max-time 30 "$vm/api/v1/export" --data-urlencode 'match[]={__name__="ALERTS",alertstate="firing",alertname!="Watchdog"}' --data-urlencode "start=$((t0 - 60))")
  while IFS=$'\t' read -r name inst last; do
    [ -n "$name" ] || continue
    off=$(( last / 1000 - tcol ))
    log "alert $name ($inst) last fired ${off}s after the Collector start"
    if [ "$name" = CollectorAbsent ] && [ "$inst" = otelcol-host-1 ] && [ "$off" -le "$startup_grace" ]; then
      continue
    fi
    ever_firing="${ever_firing:+$ever_firing,}$name"
    fail "alert $name ($inst) was firing, last ${off}s after the Collector start"
  done < <(jq -r '[.metric.alertname, (.metric["service.instance.id"] // "-"), (.timestamps[-1] | tostring)] | @tsv' <<<"$ever")

  # dead-man: Watchdog notifications of the deadman receiver in VictoriaLogs
  dm=$(curl -fsS --max-time 20 "$vl/select/logsql/query" --data-urlencode 'query={receiver="deadman"} _time:6m status:firing commonLabels.alertname:Watchdog | sort by (_time)' | jq -r '._time' | tail -6)
  dm_n=$(grep -c . <<<"$dm" || true)
  gaps=""; prev=""
  while read -r ts; do
    [ -n "$ts" ] || continue
    e=$(date -d "$ts" +%s)
    [ -n "$prev" ] && gaps="$gaps $((e - prev))"
    prev=$e
  done <<<"$dm"
  log "deadman notifications: $dm_n, gaps (s):${gaps:- none}"
  if [ -n "$prev" ]; then
    dm_age=$(( $(date +%s) - prev ))
    [ "$dm_age" -le 90 ] || fail "newest deadman notification is ${dm_age}s old, want at most 90 s"
  fi
  [ "$dm_n" -ge 2 ] || fail "Watchdog reached the deadman receiver $dm_n times, want at least 2"
  for g in $gaps; do { [ "$g" -ge 40 ] && [ "$g" -le 80 ]; } || fail "deadman gap ${g}s outside 40-80 s"; done
}

# assert_panels: the lab's own rule, as lab:pgha:panels runs it (no --strict-rows).
# check-panels.sh lets a panel be empty when it reads a log datasource, when its
# description starts with "Data only during a scenario", or when it sits in a
# row titled "(labs with ...)" (components this setup does not run:
# subscription, PgBouncer, pgBackRest); the category is recomputed here from the
# dashboard JSON so the report names the right reason. On top of that, panels
# that cannot have data on a plain PostgreSQL are listed below with the reason;
# a panel is accepted only when every failing query returned 0 rows (an error
# or a missing result stays a failure). check-panels.sh itself is unchanged.
assert_panels() {
  local -A legit_empty=(
    ["Replication slots: WAL retained"]="a plain server has no replication slot"
    ["Replication slots: active and inactive time"]="a plain server has no replication slot"
  )
  local -A category=()
  local panels_out="$tmp/panels.txt" envf="$cdir/.env" line status title t c accounted
  local empty_titles=()
  : >"$panels_out"
  run_panels() {
    echo "== $1" >>"$panels_out"
    "$repo/scripts/check-panels.sh" "$@" >>"$panels_out" 2>&1 || true
    total_panels=$(( total_panels + $(jq '[.panels[] | if .type == "row" then (.panels // [])[] else . end | select(.type != "row")] | length' "$1") ))
    while IFS=$'\t' read -r t c; do category["$t"]="$c"; done < <(jq -r '
      [.panels[] as $p | if $p.type == "row" then ($p.panels // [])[] | . + {rowTitle: $p.title} else $p end][]
      | [.title, (if ((.rowTitle // "") | contains("(labs with")) then "row of a component only some labs run"
          elif ((.description // "") | startswith("Data only during a scenario")) then "data only during a scenario"
          else "log panel" end)] | @tsv' "$1")
  }
  run_panels "$repo/packs/postgresql/dashboards/postgresql.json" "$gf" "$envf" pg-1 main
  run_panels "$repo/packs/host/dashboards/host.json" "$gf" "$envf"
  while IFS= read -r line; do
    status=${line%% *}
    title=$(sed -E 's/^[A-Za-z]+ +//;s/ +(ok|FAIL|empty \(allowed\)) [A-Z]:.*$//' <<<"$line")
    case "$status" in
      ok) p_ok=$((p_ok + 1)) ;;
      empty) p_empty=$((p_empty + 1)); empty_titles+=("$title (${category[$title]:-unknown category})") ;;
      FAIL)
        if [ -n "${legit_empty[$title]:-}" ] && ! grep -q 'ERROR\|missing\|unparsable' <<<"$line"; then
          p_legit=$((p_legit + 1)); empty_titles+=("$title (accepted: ${legit_empty[$title]})")
        else
          p_fail=$((p_fail + 1)); fail "panel without data: $title"
        fi ;;
    esac
  done < <(grep -E '^(ok|empty|FAIL) ' "$panels_out")
  cat "$panels_out"
  # every panel of the dashboards must be accounted for, and some must have data:
  # a broken check-panels.sh or an unreadable password yields no lines at all
  accounted=$((p_ok + p_empty + p_legit + p_fail))
  [ "$accounted" -eq "$total_panels" ] || fail "panels accounted for: $accounted of $total_panels (check-panels.sh output incomplete)"
  [ "$p_ok" -gt 0 ] || fail "no panel has data"
  printf 'empty panels:\n'; printf '  %s\n' "${empty_titles[@]}"
  empty_names=$(printf '%s\n' "${empty_titles[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')
}
