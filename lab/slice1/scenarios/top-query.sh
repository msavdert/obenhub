#!/usr/bin/env bash
# Scenario top-query: the receiver's db.server.top_query events (ADR 0009 decision 3; receiver postgresql/primary-topquery of otelcol/config.yaml, every 5 minutes, top 20 by execution-time delta, EXPLAIN off). inject() runs a marker statement (`SELECT count(*) FROM generate_series(1, 2000000) AS obenhub_top_query`, about 0.5 s each on the lab primary 2026-11-25) ten times in database app, then waits until the top_query records since the start whose query text holds the marker and whose db.namespace is app sum to at least ten calls (each record holds the delta since the previous read, so a read during the runs splits them over two records). It also checks that no marker record carries a query plan and that the calls of the monitoring user's PREPARE and EXPLAIN statements did not rise (pg_stat_statements tracks utility statements, track_utility on). No alert is expected: the signal is a diagnostic stream and no rule reads it. Nothing to revert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
MARKER=obenhub_top_query
RUNS=10
# 5 minute interval plus one tick of slack plus export and ingestion
TOPQ_TIMEOUT=720

# calls of the monitoring user's statements that start with PREPARE or EXPLAIN
# (calls, not rows: a repeated text adds calls to an existing row)
monitor_explains() {
  psql_p -c "SELECT coalesce(sum(s.calls), 0) FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid
    WHERE r.rolname = 'otel_monitor' AND (s.query ILIKE 'explain%' OR s.query ILIKE 'prepare%')"
}
topq_filter() { printf '_time:>%s event_name:="db.server.top_query" service.instance.id:=pg-primary db.namespace:=app db.query.text:~"%s"' "$T_INJECT" "$MARKER"; }
# the receiver emits deltas, so a read during the loop splits the runs over two
# records: sum the calls of all marker records since the start
topq_calls() { vl "$(topq_filter) | stats sum(postgresql.calls) n" | jq -r 'if (.n // "NaN") == "NaN" then 0 else .n end'; }
topq_seen() { awk -v n="$(topq_calls)" -v r="$RUNS" 'BEGIN { exit !(n + 0 >= r) }'; }

inject() {
  local before after calls plan t i
  before=$(monitor_explains) || return 1
  log "running the marker statement $RUNS times in database app"
  for i in $(seq 1 "$RUNS"); do
    psql_pa -c "SELECT count(*) FROM generate_series(1, 2000000) AS $MARKER" >/dev/null || return 1
  done
  wait_until "$TOPQ_TIMEOUT" "db.server.top_query records with $RUNS calls of $MARKER in VictoriaLogs" topq_seen \
    || { FAILS+=("db.server.top_query records of $MARKER in database app sum to $(topq_calls) calls, not $RUNS, within ${TOPQ_TIMEOUT}s"); return 1; }
  calls=$(topq_calls) || return 1
  t=$(vl "$(topq_filter) | sort by (_time desc) | limit 1" | jq -r '._time') || return 1
  plan=$(vl "$(topq_filter) postgresql.query_plan:* | stats count() n" | jq -r '.n') || return 1
  log "top_query records up to $t: $calls calls in database app"
  [ "$plan" = 0 ] || FAILS+=("$plan marker records carry a query plan although EXPLAIN is off")
  extra_set top_query_calls "$(awk -v n="$calls" 'BEGIN { printf "%d", n }')"
  after=$(monitor_explains) || return 1
  [ "$after" = "$before" ] || FAILS+=("otel_monitor ran PREPARE or EXPLAIN: $before -> $after statements")
  extra_set top_query_seconds "$(secs "$T_INJECT" "$t")"
  extra_set top_query_records "$(vl_count "_time:>$T_INJECT event_name:=\"db.server.top_query\" service.instance.id:=pg-primary" || echo 0)"
  extra_set monitor_explain_statements "$after"
}
revert() { :; }
run_scenario top-query
