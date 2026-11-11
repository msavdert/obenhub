#!/usr/bin/env bash
# Scenario replica-not-eligible: cut one replica from the repl network (its WAL receiver stops; its DCS session and monitoring stay) and write about 100 MB on the leader, beyond maximum_lag_on_failover (16 MiB). Expect PatroniReplicaNotEligible on that replica; its PostgresStandbyNotStreaming follows once the WAL receiver has timed out.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R="" L="" CUT=0
inject() {
  R=$(first_replica) && [ -n "$R" ] || return 1
  L=$(leader_name) && [ -n "$L" ] || return 1
  EXPECT=("PatroniReplicaNotEligible:$R" "PostgresStandbyNotStreaming:$R")
  docker network disconnect "$REPL_NET" "$(cname "$R")" || return 1
  CUT=1
  psql_n "$L" -c "DROP TABLE IF EXISTS s3_scratch; CREATE TABLE s3_scratch AS SELECT g, md5(g::text) || md5((g+1)::text) AS pad FROM generate_series(1, 1500000) g;" >/dev/null || return 1
  log "replica $R cut from $REPL_NET; leader $L wrote the scratch table"
}
revert() {
  local rc=0
  if [ "$CUT" = 1 ]; then docker network connect --ip "$(repl_ip "$R")" "$REPL_NET" "$(cname "$R")" || rc=1; fi
  [ -n "$L" ] && psql_n "$(leader_or "$L")" -c "DROP TABLE IF EXISTS s3_scratch" >/dev/null 2>&1
  wait_until 300 "cluster healthy again" cluster_healthy || rc=1
  return $rc
}
run_scenario replica-not-eligible
