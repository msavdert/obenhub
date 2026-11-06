#!/usr/bin/env bash
# Scenario permission-revoked: revoke EXECUTE on pg_last_wal_receive_lsn from PUBLIC; expect SeriesVanished on both instances, naming exactly the metrics of the replication query (the query that calls the function).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("SeriesVanished:pg-primary" "SeriesVanished:pg-standby")
BROKEN_METRICS='["postgresql.recovery.active","postgresql.replay.backlog","postgresql.replay.paused","postgresql.wal_receiver.streaming"]'
inject() { psql_p -c "REVOKE EXECUTE ON FUNCTION pg_last_wal_receive_lsn() FROM PUBLIC" >/dev/null; }
revert() { psql_p -c "GRANT EXECUTE ON FUNCTION pg_last_wal_receive_lsn() TO PUBLIC" >/dev/null; }
# the metric label of the delivered firing alerts, per instance, must be exactly the broken query's metrics
extra_checks() {
  local out inst got
  if ! out=$(vl "_time:>$T_INJECT commonLabels.alertname:=SeriesVanished status:=firing | fields alerts"); then
    FAILS+=("SeriesVanished metric check: VictoriaLogs query failed")
    return 0
  fi
  for inst in pg-primary pg-standby; do
    got=$(printf '%s\n' "$out" | jq -s -c --arg i "$inst" '
      [.[].alerts | fromjson | .[] | select(.status == "firing" and .labels.service_instance_id == $i) | .labels.metric] | unique') || got=""
    log "SeriesVanished metrics for $inst: $got"
    if [ "$got" != "$BROKEN_METRICS" ]; then
      FAILS+=("SeriesVanished metrics for $inst are $got, expected $BROKEN_METRICS")
    fi
  done
}
run_scenario permission-revoked
