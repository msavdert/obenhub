#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329,SC1091
# Test of the scenario harness (lib-core.sh, run-suite.sh) against a stub of
# VictoriaLogs and Alertmanager (test-stub.py) and a stub docker, in a
# throwaway git repository with a fake lab "t". No docker, no lab; takes about
# a minute (the harness sleeps are shortened to 0.2 s).
#   - running images: the precondition fails when a running container's image
#     ID differs from the Compose file's, and the record carries the IDs
#   - suite window: an alert between two scenarios is unexpected, a resolved
#     notification of the previous scenario's alerts is not
#   - control proves the sinks: the synthetic alert must come back firing and
#     resolved, PostgreSQL log records must exist in the window
#   - resolution is searched from detection, not from the revert
#   - wait_slow_tier_settled (lab/slice1/scenarios/lib-slow-tier.sh, sourced
#     into the fake lab) returns at once when settled, waits for a trailing
#     gap and for a first sample after the revert, fails the revert on a
#     timeout, a pending alert or a dead backend, does not wait after a failure
#     or an abort; its expression and limit equal the rule's
# HARNESS_DIR (default: this directory) names the directory with lib-core.sh,
# guard.sh and run-suite.sh to test, to run the test against an older copy;
# SLOW_TIER_LIB names the lib-slow-tier.sh to test (default: slice 1's).
# Run it with `mise run lab:harness-test` (part of `mise run check`).
set -u

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HD=${HARNESS_DIR:-$src}
work=$(mktemp -d)
FAILED=0
PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=1; }
check() { # description command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
RECORDS=$work/records.jsonl
: >"$RECORDS"
start_stub() { # MODE -> port in STUB_PORT (not in a subshell: the pid must reach cleanup)
  STUB_PORT=$(free_port)
  python3 -I "$src/test-stub.py" "$STUB_PORT" "$RECORDS" "$1" >>"${STUB_LOG:-/dev/null}" 2>&1 &
  PIDS+=("$!")
  until curl -fsS "http://127.0.0.1:$STUB_PORT/api/v2/alerts" >/dev/null 2>&1; do sleep 0.1; done
}
start_stub ok; P_OK=$STUB_PORT
start_stub dead; P_DEAD=$STUB_PORT
export VL=http://127.0.0.1:$P_OK
export AM_OK=http://127.0.0.1:$P_OK AM_DEAD=http://127.0.0.1:$P_DEAD
export SUITE_LOCK_FILE=$work/lock
export RESULTS=$work/runs.jsonl
export RECORDS
export VM=http://127.0.0.1:$P_OK

# stub docker: the ID a container runs is $work/running/<service>, the ID of
# the declared image img-<service> is $work/declared/img-<service>
mkdir -p "$work/bin" "$work/running" "$work/declared"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -q") for a in "$@"; do case "$a" in label=com.docker.compose.service=*) echo "cid-${a##*=}" ;; esac; done ;;
  "inspect -f") cat "$WORK/running/${4#cid-}" ;;
  "image inspect") cat "$WORK/declared/$5" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/docker"
export WORK=$work
export PATH=$work/bin:$PATH

# the tree under test: the harness files to test plus a fake lab "t"
tree=$work/tree
mkdir -p "$tree/lab/scenarios" "$tree/lab/t/scenarios" "$tree/lab/t/results"
cp "$HD/guard.sh" "$HD/lib-core.sh" "$HD/run-suite.sh" "$tree/lab/scenarios/"
SLOW_TIER_LIB=${SLOW_TIER_LIB:-$src/../slice1/scenarios/lib-slow-tier.sh}
cp "$SLOW_TIER_LIB" "$tree/lab/t/scenarios/lib-slow-tier.sh"
: >"$tree/lab/t/results/.keep"
cat >"$tree/lab/t/scenarios/lib.sh" <<'EOF'
# shellcheck disable=SC2034
SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
PROJECT=t
VMALERT=http://127.0.0.1:1 VM=${VM:-http://127.0.0.1:1} VMALERT_C=x AM_C=x CONFIG_FILES=() NODES=()
AM=${AM:-$AM_OK}
RESOLVE_TIMEOUT=2
SINK_PROBE_TIMEOUT=2
. "$SC_DIR/../../scenarios/lib-core.sh"
. "$SC_DIR/lib-slow-tier.sh"
sleep() { command sleep 0.2; }
reload_config() { CONFIG_HASH=test; }
component_versions() { echo '[]'; }
lab_precondition() {
  # records that land between two scenarios of a suite: the pre-flight of second
  if [ "$SCENARIO" = second ] && [ -n "${GAP_EMIT:-}" ]; then
    # shellcheck disable=SC2086
    emit $GAP_EMIT
  fi
  return 0
}
dc() { echo '{"services":{"db":{"image":"img-db"},"web":{"image":"img-web"}}}'; }
# emit STATUS ALERTNAME INSTANCE: one notification record, now
emit() {
  jq -n -c --arg t "$(now_ts)" --arg s "$1" --arg a "$2" --arg i "${3:-}" \
    '{_time: $t, status: $s, "commonLabels.alertname": $a} + (if $i == "" then {} else {"commonLabels.service_instance_id": $i} end)' >>"$RECORDS"
}
EOF
mk() { # NAME BODY: scenario script
  { printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/lib.sh"\n%s\nrun_scenario %s\n' "$2" "$1"; } >"$tree/lab/t/scenarios/$1.sh"
  chmod +x "$tree/lab/t/scenarios/$1.sh"
}
mk noop 'EXPECT=()
inject() { :; }
revert() { :; }
running_images() { compose_running_images; }'
mk first 'EXPECT=(Foo:x)
inject() { sleep 1; emit firing Foo x; }
revert() { sleep 1; emit resolved Foo x; }'
mk second 'EXPECT=()
inject() { :; }
revert() { :; }'
mk ctl 'EXPECT=()
ALLOW=(ObenhubSinkProbe:)
inject() { sink_probe_start; if [ -n "${PG_REC:-}" ]; then sleep 1; jq -n -c --arg t "$(now_ts)" "{_time: \$t, \"service.name\": \"postgresql\"}" >>"$RECORDS"; fi; }
revert() { :; }
extra_checks() { sink_probe_check; pg_log_records_check; }'
mk early 'EXPECT=(Foo:x)
inject() { sleep 1; emit firing Foo x; sleep 1; emit resolved Foo x; sleep 1; }
revert() { :; }'
mk flap 'EXPECT=(Foo:x)
inject() { sleep 1; emit firing Foo x; sleep 1; emit resolved Foo x; sleep 1; emit firing Foo x; }
revert() { :; }'
mk late 'EXPECT=(Foo:x)
inject() { sleep 1; emit firing Foo x; }
revert() { sleep 1; emit resolved Foo x; }'
mk settle 'EXPECT=()
inject() { :; }
revert() { wait_slow_tier_settled "${SETTLE_T:-4}"; }'
mk settle_failed 'EXPECT=()
inject() { FAILS+=("an earlier check failed"); }
revert() { wait_slow_tier_settled "${SETTLE_T:-4}"; }'
mk settle_abort 'EXPECT=()
inject() { exit 7; }
revert() { wait_slow_tier_settled "${SETTLE_T:-4}"; }'
git -C "$tree" init -q
git -C "$tree" add -A
git -C "$tree" -c user.name=t -c user.email=t@t commit -qm init

last() { tail -n1 "$RESULTS"; }
reset() { : >"$RESULTS"; : >"$RECORDS"; }
# run NAME: a single scenario run, output kept in $work/out
run() { "$tree/lab/t/scenarios/$1.sh" >"$work/out" 2>&1; }
suite() { "$tree/lab/scenarios/run-suite.sh" t "$@" >"$work/out" 2>&1; local r=$?; [ -n "${DEBUG_OUT:-}" ] && cp "$work/out" "$DEBUG_OUT"; return $r; }
rec() { last | jq -e "$1" >/dev/null; } # rec JQEXPR: the last record satisfies it

echo "--- running images"
reset
printf 'sha256:aaa\n' >"$work/running/db"; printf 'sha256:bbb\n' >"$work/running/web"
printf 'sha256:aaa\n' >"$work/declared/img-db"; printf 'sha256:bbb\n' >"$work/declared/img-web"
run noop; rc=$?
check "matching images: the scenario passes" test "$rc" -eq 0
check "matching images: the record carries the running images of both services" rec '(.running_images | length) == 2 and ([.running_images[].name] | sort) == ["db","web"] and .running_images[0].running != null'
reset
printf 'sha256:ccc\n' >"$work/running/web"
run noop; rc=$?
check "a running image that differs from the declared one fails the scenario" test "$rc" -ne 0
check "the failure names the service, the running and the declared ID" rec '.pass == false and (.failure_reasons | join(" ") | test("web") and test("sha256:ccc") and test("sha256:bbb"))'
check "the scenario did not start (no inject)" rec '.inject == null'

echo "--- suite window"
reset
GAP_EMIT="firing Gap y" suite first second; rc=$?
check "a firing alert nobody expects between two scenarios fails the suite" test "$rc" -ne 0
check "the gap alert is in the unexpected list of the second scenario" rec '.scenario == "second" and ([.unexpected_alerts[].alertname] | index("Gap")) != null'
reset
GAP_EMIT="resolved Foo x" suite first second; rc=$?
check "a resolved notification of the previous scenario's alert in the gap is allowed" test "$rc" -eq 0
check "the second scenario's window starts at the end of the first" bash -c '
  first=$(jq -r "select(.scenario == \"first\") | .end" "$1"); second=$(jq -r "select(.scenario == \"second\") | .window_start" "$1")
  [ -n "$first" ] && [ "$first" != null ] && [ "$first" = "$second" ]' _ "$RESULTS"
check "the first scenario's window starts before its own start (suite start)" bash -c '
  jq -e "select(.scenario == \"first\") | .window_start != null and .window_start < .start" "$1"' _ "$RESULTS"
reset
GAP_EMIT="firing Foo x" suite first second; rc=$?
check "a new firing of the previous scenario's alert in the gap is unexpected" test "$rc" -ne 0
reset
GAP_EMIT="resolved Other z" suite first second; rc=$?
check "a resolved notification of an alert the previous scenario did not expect is unexpected" test "$rc" -ne 0
reset
run first; rc=$?
check "outside a suite the window starts at the scenario start" bash -c 'test '"$rc"' -eq 0 && jq -e ".window_start == .start" "$1"' _ "$RESULTS"

echo "--- control proves the sinks"
reset
PG_REC=1 AM=$AM_OK run ctl; rc=$?
check "synthetic alert delivered and log records present: control passes" test "$rc" -eq 0
check "the record says so" rec '.extra.sink_probe == true and .extra.postgresql_log_records > 0 and .unexpected_alerts == []'
reset
PG_REC=1 AM=$AM_DEAD run ctl; rc=$?
check "a dead sink (the synthetic alert never comes back) fails control" test "$rc" -ne 0
check "the reason names the sink probe" rec '.pass == false and (.failure_reasons | join(" ") | test("sink probe"))'
reset
AM=$AM_OK run ctl; rc=$?
check "no PostgreSQL log record in the window fails control" test "$rc" -ne 0
check "the reason names the log records" rec '.pass == false and (.failure_reasons | join(" ") | test("postgresql log records"))'

echo "--- resolution from detection"
reset
run early; rc=$?
check "an alert that resolved before the revert still counts as resolved" test "$rc" -eq 0
check "its seconds_to_resolve is negative and resolved_before_revert is true" rec '.seconds_to_resolve < 0 and .resolved_before_revert == true'
reset
run late; rc=$?
check "a resolution after the revert passes" test "$rc" -eq 0
check "it has a positive seconds_to_resolve and resolved_before_revert false" rec '.seconds_to_resolve > 0 and .resolved_before_revert == false'
reset
run flap; rc=$?
check "a resolve that a new firing follows is not a resolution" test "$rc" -ne 0
check "the reason is not resolved" rec '.failure_reasons | join(" ") | test("not resolved")'

echo "--- slow tier settle"
SLOW=$RECORDS.slow
reset
printf '0 0\n' >"$SLOW"
run settle; rc=$?
check "no gap and no alert: settled at once" test "$rc" -eq 0
check "it says how long it waited (under 2 s)" grep -q 'slow tier settled after [01]s' "$work/out"
reset
printf '2 0\n' >"$SLOW"
( command sleep 2; printf '0 0\n' >"$SLOW" ) &
PIDS+=("$!")
run settle; rc=$?
check "a trailing gap that clears while waiting: the revert waits and passes" test "$rc" -eq 0
check "it waited for the gap (at least 1 s)" bash -c '! grep -q "slow tier settled after 0s" "$1" && grep -q "slow tier settled after" "$1"' _ "$work/out"
reset
printf '2 0\n' >"$SLOW"
run settle; rc=$?
check "a gap that does not clear within the timeout fails the scenario" test "$rc" -ne 0
check "the reason names the slow tier and the timeout" rec '.pass == false and (.failure_reasons | join(" ") | test("slow tier not settled within 4s") and test("revert failed"))'
reset
printf '0 1\n' >"$SLOW"
run settle; rc=$?
check "a pending or firing alert alone keeps the wait going, then fails" test "$rc" -ne 0
reset
printf '0 0\n' >"$SLOW"
VM=http://127.0.0.1:1 run settle; rc=$?
check "an unreachable VictoriaMetrics does not read as settled" test "$rc" -ne 0
reset
printf '0 0 1\n' >"$SLOW"
run settle; rc=$?
check "no sample after the revert yet (spacing still fine, no alert): not settled" test "$rc" -ne 0
check "the reason names the slow tier" rec '.failure_reasons | join(" ") | test("slow tier not settled")'
reset
printf '0 0 1\n' >"$SLOW"
( command sleep 2; printf '0 0 0\n' >"$SLOW" ) &
PIDS+=("$!")
run settle; rc=$?
check "the first sample after the revert lands while waiting: settled" test "$rc" -eq 0
check "it asked the freshness query, not only the spacing" bash -c '! grep -q "settled after 0s" "$1"' _ "$work/out"
reset
printf '2 1 1\n' >"$SLOW"
run settle_failed
check "a scenario that failed already does not wait (no 4 s timeout, no slow-tier reason)" bash -c '
  grep -q "not waiting for the slow tier" "$1" && ! jq -e ".failure_reasons | join(\" \") | test(\"slow tier not settled\")" "$2" >/dev/null' _ "$work/out" "$RESULTS"
reset
run settle_abort
check "a revert from the abort path does not wait" bash -c '
  grep -q "not waiting for the slow tier" "$1" && ! jq -e ".failure_reasons | join(\" \") | test(\"slow tier not settled\")" "$2" >/dev/null' _ "$work/out" "$RESULTS"
rm -f "$SLOW"

echo "--- slow tier expression equals the rule's"
rule=$src/../../packs/postgresql/rules.yml
rule_expr=$(awk '/- alert: PostgresSlowCollectionIntervalTooLong$/ {f=1} f && /^ *expr: / {sub(/^ *expr: /, ""); print; exit}' "$rule")
lib_expr=$(sed -n "s/^SLOW_TIER_SPACING='\(.*\)'\$/\1/p" "$SLOW_TIER_LIB")
lib_limit=$(sed -n 's/^SLOW_TIER_LIMIT=\([0-9]*\)$/\1/p' "$SLOW_TIER_LIB")
check "the helper's spacing expression and limit are the rule's expr (rule: $rule_expr)" test -n "$rule_expr" -a "$rule_expr" = "$lib_expr > $lib_limit"

[ "$FAILED" = 0 ] && echo "all harness tests passed"
exit "$FAILED"
