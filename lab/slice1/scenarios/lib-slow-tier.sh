#!/usr/bin/env bash
# shellcheck disable=SC2034
# Wait for the slow tier to settle after a scenario that causes a gap in it.
# Sourced by lib.sh after lib-core.sh (uses its log, wait_until, FAILS and the
# adapter's VM); kept in its own file so lab/scenarios/test-harness.sh can
# source it into a fake lab. Do not run it.
#
# A gap in the slow tier's heartbeat (a Collector or a whole PostgreSQL instance
# down for more than about one 5 m collection) keeps the average spacing that
# PostgresSlowCollectionIntervalTooLong (packs/postgresql/rules.yml) measures
# above its limit until the gap has left the rule's 30 m window, and the alert
# then fires 10 m into that, in whatever scenario runs by then. A scenario that
# causes such a gap calls wait_slow_tier_settled at the end of revert() and
# lists the alert in ALLOW for the instances the gap touches (it may fire and
# resolve inside the wait). SLOW_TIER_SPACING and SLOW_TIER_LIMIT repeat the
# rule's expression and limit; lab/scenarios/test-harness.sh fails when they
# differ from the rule.
# The spacing stays at 300 s while a series is down (its last sample is fixed)
# and jumps only when the first sample after the gap lands, so the wait has two
# phases at once: every heartbeat series of the last hour has a sample newer
# than the call (up to one 5 m collection), then the spacing is back within the
# limit (up to the 30 m window) and the alert is neither pending nor firing.

SLOW_TIER_SPACING='max by (obenhub.cluster.name, service.instance.id, postgresql.database.name) (scrape_interval(postgresql.collection.slow_heartbeat[30m]))'
SLOW_TIER_LIMIT=450
SLOW_TIER_ALERT=PostgresSlowCollectionIntervalTooLong
SLOW_TIER_SETTLE_TIMEOUT=2700   # 300 s to the first sample + 1800 s window + margin; a constant, not a knob

# vm_count EXPR -> number of series EXPR returns now (0 for none); fails when
# VictoriaMetrics does not answer, so that a dead backend never reads as settled
vm_count() {
  local out
  out=$(curl -fsS "$VM/api/v1/query" --data-urlencode "query=count($1) or vector(0)") || return 1
  jq -er '.data.result[0].value[1] | tonumber | floor' <<<"$out"
}
# slow_tier_settled SINCE_EPOCH: every heartbeat series of the last hour has a sample after SINCE_EPOCH,
# no instance averages above the limit between samples, and the alert is neither pending nor firing
slow_tier_settled() {
  local stale over alerts
  stale=$(vm_count "tlast_over_time(postgresql.collection.slow_heartbeat[1h]) <= $1") || return 1
  [ "$stale" = 0 ] || return 1
  over=$(vm_count "$SLOW_TIER_SPACING > $SLOW_TIER_LIMIT") || return 1
  alerts=$(vm_count "ALERTS{alertname=\"$SLOW_TIER_ALERT\",alertstate=~\"pending|firing\"}") || return 1
  [ "$over" = 0 ] && [ "$alerts" = 0 ]
}
# Skipped when revert() runs from on_exit after an abort, and when the scenario has failed already:
# run-suite.sh stops at the first failure, so no later scenario of that suite inherits the alert.
# A new suite or smoke run started within about 40 minutes of such a failure can still inherit it.
# Every heartbeat series seen in the last hour must report again, so a scenario that drops a
# database or leaves an instance down cannot use this helper.
# The abort path is told by the EXIT trap: on_exit in lab/scenarios/lib-core.sh runs `trap - EXIT`
# (line 420 when written) before its do_revert, so an empty `trap -p EXIT` inside revert() means
# on_exit is calling it; a normal revert runs from run_scenario with the trap still set. This
# relies on that order; test-harness.sh (settle_abort) fails when it changes.
wait_slow_tier_settled() { # [TIMEOUT]: fails the revert, and says why, when it does not settle
  local limit=${1:-$SLOW_TIER_SETTLE_TIMEOUT} t0 s
  if [ -z "$(trap -p EXIT)" ] || [ "${#FAILS[@]}" -gt 0 ]; then log "not waiting for the slow tier to settle: the scenario failed or was aborted"; return 0; fi
  t0=$(date +%s)
  if ! wait_until "$limit" "slow tier settled (a heartbeat sample after the revert, $SLOW_TIER_ALERT neither pending nor firing, spacing at most $SLOW_TIER_LIMIT s)" slow_tier_settled "$t0"; then
    FAILS+=("slow tier not settled within ${limit}s after revert: a gap in postgresql.collection.slow_heartbeat still trails ($SLOW_TIER_ALERT)")
    return 1
  fi
  s=$(($(date +%s) - t0))
  log "slow tier settled after ${s}s"
}
