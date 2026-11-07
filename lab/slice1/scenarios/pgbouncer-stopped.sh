#!/usr/bin/env bash
# Scenario pgbouncer-stopped: stop the PgBouncer container; expect PostgresTargetAbsent for pgbouncer only (the pool alert must stay quiet and no PostgreSQL target may be reported absent).
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD_AFTER_DETECT=60   # seconds; no other alert may follow
EXPECT=("PostgresTargetAbsent:pgbouncer")
inject() { dc stop pgbouncer >/dev/null; }
revert() { dc start pgbouncer >/dev/null && wait_until 120 "pgbouncer answering again" pgb_console "SHOW VERSION"; }
run_scenario pgbouncer-stopped
