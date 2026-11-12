#!/usr/bin/env bash
# Scenario permission-revoked: revoke EXECUTE on pg_last_wal_receive_lsn from PUBLIC; expect PostgresSeriesVanished on both instances, naming exactly the metrics of the queries that call the function (the replication query on both, plus the slot query on the primary).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresSeriesVanished:pg-primary" "PostgresSeriesVanished:pg-standby")
BROKEN_METRICS='["postgresql.recovery.active","postgresql.replay.backlog","postgresql.replay.paused","postgresql.wal_receiver.streaming"]'
# The slot query also calls pg_last_wal_receive_lsn (in its CASE; the privilege check does not depend on the branch), so on the primary, the only node with slots, its six metrics vanish too. The standby has no slot series, so nothing of them vanishes there.
BROKEN_PRIMARY=$(jq -c '. + ["postgresql.replication_slot.active","postgresql.replication_slot.inactive_age","postgresql.replication_slot.invalidated","postgresql.replication_slot.retained_wal","postgresql.replication_slot.unconfirmed_wal","postgresql.replication_slot.wal_status"] | sort' <<<"$BROKEN_METRICS")
BROKEN_METRICS=$(jq -c 'sort' <<<"$BROKEN_METRICS")
inject() { psql_p -c "REVOKE EXECUTE ON FUNCTION pg_last_wal_receive_lsn() FROM PUBLIC" >/dev/null; }
revert() { psql_p -c "GRANT EXECUTE ON FUNCTION pg_last_wal_receive_lsn() TO PUBLIC" >/dev/null; }
# the metric label of the delivered firing alerts, per instance, must be exactly the metrics of the broken queries
extra_checks() {
  local out inst got want
  if ! out=$(vl "_time:>$T_INJECT commonLabels.alertname:=PostgresSeriesVanished status:=firing | fields alerts"); then
    FAILS+=("PostgresSeriesVanished metric check: VictoriaLogs query failed")
    return 0
  fi
  for inst in pg-primary pg-standby; do
    got=$(printf '%s\n' "$out" | jq -s -c --arg i "$inst" '
      [.[].alerts | fromjson | .[] | select(.status == "firing" and .labels.service_instance_id == $i) | .labels.metric] | unique') || got=""
    log "PostgresSeriesVanished metrics for $inst: $got"
    want=$BROKEN_METRICS; [ "$inst" = pg-primary ] && want=$BROKEN_PRIMARY
    if [ "$got" != "$want" ]; then
      FAILS+=("PostgresSeriesVanished metrics for $inst are $got, expected $want")
    fi
  done
}
run_scenario permission-revoked
