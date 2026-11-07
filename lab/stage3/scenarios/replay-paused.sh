#!/usr/bin/env bash
# Scenario replay-paused: pause WAL replay on one replica under write load. Expect ReplayBacklog on it, and no PatroniReplicaNotEligible: Patroni compares max(received, replayed) with the leader's position, and a paused replay does not stop the WAL receiver. Patroni itself resumes a paused replay on a follower within one loop unless the cluster is in maintenance mode (ha.py:778 calls handle_parameter_change, defined in patroni/postgresql/__init__.py, under `if not self.is_paused()`; seen in the log "Resuming paused WAL replay"), so the scenario pauses the cluster first; PatroniClusterPaused may therefore follow after its 3 m window and is allowed. The extra fields record Patroni's own positions.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R="" L="" PAUSED=0 MAINT=0
ALLOW=("PatroniClusterPaused:")
backlog_big() { [ "$(psql_n "$R" -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint")" -gt $((16 * 1024 * 1024)) ]; }
inject() {
  R=$(first_replica) && [ -n "$R" ] || return 1
  L=$(leader_name) && [ -n "$L" ] || return 1
  EXPECT=("ReplayBacklog:$R")
  ptl pause --wait >/dev/null || return 1
  MAINT=1
  psql_n "$R" -c "SELECT pg_wal_replay_pause()" >/dev/null || return 1
  PAUSED=1
  psql_n "$L" -c "DROP TABLE IF EXISTS s3_scratch; CREATE TABLE s3_scratch AS SELECT g, md5(g::text) || md5((g+1)::text) AS pad FROM generate_series(1, 1500000) g;" >/dev/null || return 1
  # the replica receives the WAL a moment after the leader has written it
  wait_until 60 "backlog above 16 MiB on $R" backlog_big || FAILS+=("backlog on $R stayed below 16 MiB")
}
after_detect() {
  # Patroni's view while replay is paused and the alert has fired
  local row
  row=$(members | jq -c --arg r "$R" '.[] | select(.Member == $r)')
  log "patronictl row for $R: $row"
  EXTRA_JSON=$(jq -n -c --arg r "$R" --argjson row "${row:-null}" \
    --arg recv "$(vm_query "patroni_xlog_received_location{service.instance.id=\"$R\"}")" \
    --arg repl "$(vm_query "patroni_xlog_replayed_location{service.instance.id=\"$R\"}")" \
    --arg lead "$(vm_query 'max(patroni_xlog_location)')" \
    '{replica: $r, patronictl_row: $row, patroni_received: $recv, patroni_replayed: $repl, patroni_leader_location: $lead}')
}
revert() {
  local rc=0
  if [ "$PAUSED" = 1 ]; then psql_n "$R" -c "SELECT pg_wal_replay_resume()" >/dev/null || rc=1; fi
  if [ "$MAINT" = 1 ]; then ptl resume --wait >/dev/null || rc=1; fi
  psql_n "$(leader_name || echo "$L")" -c "DROP TABLE IF EXISTS s3_scratch" >/dev/null 2>&1
  wait_until 300 "cluster healthy again" cluster_healthy || rc=1
  return $rc
}
run_scenario replay-paused
