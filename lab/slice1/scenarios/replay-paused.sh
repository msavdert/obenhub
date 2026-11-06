#!/usr/bin/env bash
# Scenario replay-paused: pause WAL replay on the standby under write load; expect ReplayBacklog for pg-standby.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("ReplayBacklog:pg-standby")
PAUSED=0
inject() {
  psql_s -c "SELECT pg_wal_replay_pause()" >/dev/null || return 1
  PAUSED=1
  # ~100 MB of WAL; the standby receives it but does not replay it
  psql_p -c "DROP TABLE IF EXISTS slice1_scratch; CREATE TABLE slice1_scratch AS SELECT g, md5(g::text) || md5((g+1)::text) AS pad FROM generate_series(1, 1500000) g;" >/dev/null || return 1
  local b
  b=$(psql_s -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint")
  log "backlog on the standby: $b bytes"
  [ "$b" -gt $((16 * 1024 * 1024)) ] || { FAILS+=("backlog only $b bytes"); }
}
revert() {
  local rc=0
  if [ "$PAUSED" = 1 ]; then psql_s -c "SELECT pg_wal_replay_resume()" >/dev/null || rc=1; fi
  psql_p -c "DROP TABLE IF EXISTS slice1_scratch" >/dev/null || rc=1
  return $rc
}
run_scenario replay-paused
