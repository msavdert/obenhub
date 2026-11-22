#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install test of deploy/ (roadmap D2): the backend of deploy/compose, a host
# Collector laid out as deploy/README.md "Host Collector" says, and a plain
# PostgreSQL container with its default configuration and no lab file. It
# asserts that the heartbeat is there, that nothing but Watchdog fires once
# every `for:` has elapsed, that the dead-man route delivers Watchdog about
# every 60 s, and that the dashboard panels have data. One JSON line per run
# goes to deploy/results/runs.jsonl. Needs docker, jq, curl, openssl; takes
# about 15 minutes. Not part of `mise run check`.
#   mise run deploy:install-test
# Environment: INSTALL_TEST_PORT_BASE (default 61000; six ports from there are
# bound on 127.0.0.1), INSTALL_TEST_EVIDENCE=0 to skip the runs.jsonl line,
# INSTALL_TEST_SETTLE=<seconds> to shorten the settle while debugging the test
# (no evidence line is written then).
#
# Files used are those deploy/README.md tells a user to use (deploy/, packs/).
# One exception, by D1's design: the Grafana service mounts
# lab/mon/grafana/provisioning (generic datasources and a dashboard provider).
# Two deviations, both test-only:
#  - the contrib image has no journalctl, so the journald receivers of the host
#    pack cannot read anything; an overlay replaces the receivers of the host
#    logs pipeline by the base's `nop` (a list is replaced on merge), pack
#    files stay untouched. The journal is therefore not tested here.
#  - the Collector runs in a container. Without root_path the filesystem
#    scraper reports nothing there (measured with 0.165.0: 0 data points, and it
#    logs a warning), so the overlay sets root_path of the host pack's receiver
#    to /hostfs and the host's / is mounted there read-only, as the upstream
#    hostmetrics receiver README describes for containers. The host pack does
#    not set root_path itself; this is the test's choice, not a pack feature.
#    The whole / is mounted, not just /proc: the scraper reads the mount list
#    from <root_path>/proc and calls statfs on <root_path><mountpoint>, so the
#    mount points must be reachable. With only /proc mounted a debug run still
#    reported "/" with the host's numbers, but only because Docker's data root
#    lives on the host's / (the container's overlay root answers the statfs);
#    /boot and /boot/efi were missing. That is luck, not a reading of the host.
# shellcheck disable=SC2329  # functions are called from the EXIT trap
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project=obenhub-install-test
net="$project-pg"
mon="${project}_mon"
pgc="$project-pg"
colc="$project-otelcol"
# PostgreSQL 18 pin of the labs (lab/stage3/compose.yaml, lab/slice1/compose.yaml);
# scripts/check-deploy-pins.py fails when this line differs from them.
PG_IMAGE=postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
# the host Collector runs the image of the gateway, as deploy/README.md asks
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' "$repo/deploy/compose/compose.yaml")"
[ -n "$OTELCOL_IMAGE" ] || { echo "install-test: gateway image not found in compose.yaml" >&2; exit 2; }

base="${INSTALL_TEST_PORT_BASE:-61000}"
p_grafana=$base p_vm=$((base + 1)) p_vl=$((base + 2)) p_vmalert=$((base + 3)) p_am=$((base + 4)) p_gw=$((base + 5))
for p in $p_grafana $p_vm $p_vl $p_vmalert $p_am $p_gw; do
  if ss -ltn | awk '{print $4}' | grep -q ":$p\$"; then echo "install-test: port $p is in use; set INSTALL_TEST_PORT_BASE" >&2; exit 2; fi
done

t0=$(date +%s)
tmp="$(mktemp -d)"
cdir="$tmp/deploy/compose"
failures=()
fail() { failures+=("$1"); echo "FAIL: $1" >&2; }
log() { echo "[$(( $(date +%s) - t0 ))s] $*"; }
# values the evidence row reads; set again as the run goes, so that a run that
# aborts early still produces a complete failed row
max_for=0 settle=0 hb=0 firing="" pending="" ever_firing="" dm_n=0 gaps="" dm_age=-1
p_ok=0 p_empty=0 p_fail=0 p_legit=0 empty_names='[]'
finished=false
completed=false
aborted=""
sig=""
total_panels=0
trap 'aborted="line $LINENO: $BASH_COMMAND"' ERR
# a signal ends the run as a failure; the EXIT trap still reports and tears down
trap 'sig=SIGINT; exit 130' INT
trap 'sig=SIGTERM; exit 143' TERM
trap 'sig=SIGHUP; exit 129' HUP

teardown() {
  set +e
  docker rm -f "$colc" "$pgc" >/dev/null 2>&1
  [ -d "$cdir" ] && (cd "$cdir" && docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1)
  docker network rm "$net" >/dev/null 2>&1
  rm -rf "${tmp:?}"
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
    summarize
  fi
  teardown
  if [ ${#failures[@]} -gt 0 ]; then
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
  fi
}
summarize() {
  local outcome=pass dur
  { $completed && [ ${#failures[@]} -eq 0 ]; } || outcome=fail
  dur=$(( $(date +%s) - t0 ))
  if [ "${INSTALL_TEST_EVIDENCE:-1}" != 0 ] && [ -z "${INSTALL_TEST_SETTLE:-}" ]; then
    write_evidence "$outcome" "$dur"
  fi
  if [ "$outcome" = pass ]; then
    echo "install-test: PASS in ${dur}s, firing [$firing] (firing after startup besides Watchdog: [$ever_firing]), deadman x$dm_n newest ${dm_age}s old, panels ok=$p_ok empty=$p_empty accepted-empty=$p_legit fail=$p_fail, settle ${settle}s"
  else
    echo "install-test: FAIL in ${dur}s (${#failures[@]}): $(IFS=';'; echo "${failures[*]}")" >&2
  fi
}
write_evidence() {
  local sha dirty
  mkdir -p "$repo/deploy/results"
  sha=$(git -C "$repo" rev-parse --short HEAD)
  dirty=false; [ -z "$(git -C "$repo" status --porcelain -- deploy packs scripts mise.toml lab/mon/grafana)" ] || dirty=true
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$sha" --argjson dirty "$dirty" --arg outcome "$1" \
    --arg firing "$firing" --arg pending "$pending" --arg ever "$ever_firing" --argjson dmn "$dm_n" --arg gaps "${gaps# }" --argjson dm_age_s "$dm_age" \
    --argjson ok "$p_ok" --argjson empty "$p_empty" --argjson legit "$p_legit" --argjson pfail "$p_fail" --argjson empty_names "$empty_names" \
    --argjson settle "$settle" --argjson maxfor "$max_for" --argjson dur "$2" --argjson hb "${hb:-0}" \
    --arg fails "$(IFS=';'; echo "${failures[*]:-}")" --arg pg "$PG_IMAGE" --arg oc "$OTELCOL_IMAGE" \
    --arg images "$(grep -o 'image: *[^ ]*' "$repo/deploy/compose/compose.yaml" | sed 's/image: *//' | sort -u | tr '\n' ' ')" '
    {test: "install-test", ts: $ts, git_sha: $sha, git_dirty: $dirty, pass: ($outcome == "pass"), outcome: $outcome,
     failure_reasons: ($fails | split(";") | map(select(. != ""))),
     heartbeat_series: $hb, firing_alerts: ($firing | split(",") | map(select(. != ""))),
     pending_alerts: ($pending | split(",") | map(select(. != ""))),
     firing_after_startup_besides_watchdog: ($ever | split(",") | map(select(. != ""))),
     deadman_notifications: $dmn, deadman_gaps_seconds: ($gaps | split(" ") | map(select(. != "") | tonumber)),
     deadman_newest_age_seconds: $dm_age_s,
     panels_ok: $ok, panels_empty_allowed: $empty, panels_empty_accepted: $legit, panels_failed: $pfail, panels_empty_titles: $empty_names,
     max_for_seconds: $maxfor, settle_seconds: $settle, duration_seconds: $dur,
     images: ([$pg, $oc] + ($images | split(" ") | map(select(. != ""))) | unique)}' >>"$repo/deploy/results/runs.jsonl"
}
trap finish EXIT

# a. fresh state: certificates, .env, compose project (the repo checkout stays clean)
mkdir -p "$tmp/deploy" "$tmp/lab/mon"
cp -r "$repo/deploy/compose" "$tmp/deploy/"
ln -s "$repo/packs" "$tmp/packs"
ln -s "$repo/lab/mon/grafana" "$tmp/lab/mon/grafana"
gpw="$(openssl rand -hex 12)"
(
  cd "$cdir"
  bash tls.sh gateway >/dev/null
  cp .env.example .env
  sed -i -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$gpw/" \
    -e "s/^OBENHUB_UID=.*/OBENHUB_UID=$(id -u)/" -e "s/^OBENHUB_GID=.*/OBENHUB_GID=$(id -g)/" \
    -e "s/^OBENHUB_GRAFANA_PORT=.*/OBENHUB_GRAFANA_PORT=$p_grafana/" -e "s/^OBENHUB_VM_PORT=.*/OBENHUB_VM_PORT=$p_vm/" \
    -e "s/^OBENHUB_VL_PORT=.*/OBENHUB_VL_PORT=$p_vl/" -e "s/^OBENHUB_VMALERT_PORT=.*/OBENHUB_VMALERT_PORT=$p_vmalert/" \
    -e "s/^OBENHUB_ALERTMANAGER_PORT=.*/OBENHUB_ALERTMANAGER_PORT=$p_am/" -e "s/^OBENHUB_GATEWAY_PORT=.*/OBENHUB_GATEWAY_PORT=$p_gw/" \
    -e "s/^OBENHUB_GATEWAY_BIND=.*/OBENHUB_GATEWAY_BIND=127.0.0.1/" .env
)
log "backend: docker compose up"
(cd "$cdir" && docker compose -p "$project" up -d --wait) >"$tmp/compose-up.log" 2>&1 || { cat "$tmp/compose-up.log" >&2; fail "docker compose up --wait"; }

# b. plain PostgreSQL: default configuration, own network, monitoring role from the pack
docker network create "$net" >/dev/null
pgpw="$(openssl rand -hex 12)"
monpw="$(openssl rand -hex 12)"
docker run -d --name "$pgc" --network "$net" --network-alias pg -e POSTGRES_PASSWORD="$pgpw" "$PG_IMAGE" >/dev/null
for _ in $(seq 60); do docker exec "$pgc" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
# the init scripts restart the server once; wait until it answers over TCP twice in a row
sleep 3
for _ in $(seq 60); do docker exec "$pgc" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
docker exec -i -e OTEL_MONITOR_PASSWORD="$monpw" "$pgc" psql -U postgres -v ON_ERROR_STOP=1 -q \
  -c '\getenv mon_pw OTEL_MONITOR_PASSWORD' -f - <"$repo/packs/postgresql/monitoring-role.sql" >/dev/null \
  || fail "monitoring-role.sql"

# c. host Collector: files as /etc/otelcol-contrib, as deploy/README.md lays them out
oc="$tmp/otelcol"
install -d "$oc/packs" "$oc/tls"
cp "$repo/packs/otelcol-base.yaml" "$oc/packs/"
for p in collector host postgresql; do cp -r "$repo/packs/$p" "$oc/packs/"; done
cp "$repo/deploy/collector/otelcol-tls.yaml" "$oc/"
cp "$repo/deploy/collector/obenhub.env.example" "$oc/obenhub.env"
cp "$cdir/tls/ca.crt" "$cdir/tls/client.crt" "$cdir/tls/client.key" "$oc/tls/"
chmod 0600 "$oc/obenhub.env"
sed -i -e "s#^OBENHUB_GATEWAY_ENDPOINT=.*#OBENHUB_GATEWAY_ENDPOINT=https://gateway:4318#" \
  -e "s#^OBENHUB_PG_HOST=.*#OBENHUB_PG_HOST=pg#" -e "s#^OBENHUB_PG_PASSWORD=.*#OBENHUB_PG_PASSWORD=$monpw#" \
  -e "s#^OBENHUB_PG_LOG_GLOB=.*#OBENHUB_PG_LOG_GLOB=/nonexistent/postgresql-*.json#" "$oc/obenhub.env"
# docker --env-file keeps single quotes that a shell would strip
sed -n "s/^\([A-Z_0-9]*\)='\(.*\)'$/\1=\2/p;t;/^[A-Z_0-9]*=/p" "$oc/obenhub.env" >"$tmp/docker.env"
cat >"$oc/install-test-overlay.yaml" <<'YAML'
# test only (see install-test.sh): no journalctl in the contrib image, and the
# host's / is mounted at /hostfs so the filesystem scraper has something to read
receivers:
  host_metrics/obenhub-host:
    root_path: /hostfs
service:
  pipelines:
    logs/obenhub-host:
      receivers: [nop]
YAML
chmod -R a+rX "$oc"
log "host Collector: start $OTELCOL_IMAGE"
docker run -d --name "$colc" --network "$net" --user "$(id -u):$(id -g)" --env-file "$tmp/docker.env" \
  --tmpfs /var/lib/otelcol-contrib:mode=1777 -v "$oc:/etc/otelcol-contrib:ro" -v /:/hostfs:ro "$OTELCOL_IMAGE" \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml \
  --config=/etc/otelcol-contrib/install-test-overlay.yaml >/dev/null
docker network connect "$mon" "$colc"
tcol=$(date +%s)

# d. settle: the longest `for:` among the rules that can fire here, plus a margin.
# Packs loaded with data: collector, host, postgresql. Other packs' rules watch
# components this setup does not run. Margin 120 s (assumption: vmalert
# evaluates every 15 s, Alertmanager group_wait 5 s, scrape and export lag).
max_for=$(grep -h '^ *for: *[0-9]' "$repo"/packs/{collector,host,postgresql}/rules.yml | sed 's/^ *for: *"\{0,1\}\([0-9]*\)\([sm]\).*/\1 \2/' |
  awk '{ s = ($2 == "m") ? $1 * 60 : $1; if (s > m) m = s } END { print m }')
settle=$((max_for + 120))
if [ -n "${INSTALL_TEST_SETTLE:-}" ]; then settle=$INSTALL_TEST_SETTLE; INSTALL_TEST_EVIDENCE=0; fi
log "settle: longest for: of the loaded packs is ${max_for}s, waiting ${settle}s from Collector start"
while [ $(( $(date +%s) - tcol )) -lt "$settle" ]; do
  docker ps -q -f name="^$colc\$" | grep -q . || { fail "host Collector exited"; docker logs --tail 30 "$colc" >&2 || true; break; }
  sleep 15
done
docker logs "$colc" 2>&1 | grep -ci 'error' | sed 's/^/Collector log lines with "error": /' || true

vm="http://127.0.0.1:$p_vm" vl="http://127.0.0.1:$p_vl" vma="http://127.0.0.1:$p_vmalert" gf="http://127.0.0.1:$p_grafana"

# heartbeat
hb=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode 'query=count(last_over_time({__name__="postgresql.collection.heartbeat","service.instance.id"="pg-1","obenhub.cluster.name"="main"}[2m]))' | jq -r '.data.result[0].value[1] // "0"')
if [ "$hb" = 1 ]; then log "heartbeat of pg-1 (cluster main): present"; else fail "no postgresql.collection.heartbeat of pg-1 in the last 2m"; fi

# alerts: only Watchdog may fire, and nothing may be pending
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
startup_grace=120
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

# panels: the lab's own rule, as lab:pgha:panels runs it (no --strict-rows).
# check-panels.sh lets a panel be empty when it reads a log datasource, when its
# description starts with "Data only during a scenario", or when it sits in a
# row titled "(labs with ...)" (components this setup does not run:
# subscription, PgBouncer, pgBackRest); the category is recomputed here from the
# dashboard JSON so the report names the right reason. On top of that, panels
# that cannot have data on a plain PostgreSQL are listed below with the reason;
# a panel is accepted only when every failing query returned 0 rows (an error
# or a missing result stays a failure). check-panels.sh itself is unchanged.
declare -A legit_empty=(
  ["Replication slots: WAL retained"]="a plain server has no replication slot"
  ["Replication slots: active and inactive time"]="a plain server has no replication slot"
)
declare -A category=()
panels_out="$tmp/panels.txt"
: >"$panels_out"
envf="$cdir/.env"
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
empty_titles=()
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

# the EXIT trap prints the summary line and appends the evidence row
completed=true
exit 0
