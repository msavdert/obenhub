#!/usr/bin/env bash
# Scenario snapshot-held: leave a repeatable-read transaction open on the primary; expect PostgresSnapshotHeldTooLong for pg-primary.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresSnapshotHeldTooLong:pg-primary")
APPNAME=slice1-snapshot-held
inject() {
  docker exec -d -e PGAPPNAME="$APPNAME" "$PRIMARY" timeout 1200 psql -U postgres -X \
    -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1 FROM pg_class LIMIT 1; SELECT pg_sleep(1200);" || return 1
  sleep 3
  [ "$(psql_p -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$APPNAME'")" = 1 ]
}
revert() {
  psql_p -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name = '$APPNAME'" >/dev/null
}
run_scenario snapshot-held
