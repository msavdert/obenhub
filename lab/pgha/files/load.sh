#!/usr/bin/env bash
# Client load for a pgha node, run by obenhub-load.service as the postgres
# user over the local socket (peer authentication, so no password anywhere).
# Same write pattern and rate as lab/stage3/scripts/load.sh: pgbench scale 5,
# 4 clients, 100 transactions/s, in 60 s rounds. It writes only while this
# node is the primary (pg_is_in_recovery() false); on a replica it waits, so
# exactly one node carries the load and after a failover the new primary's
# instance takes over within a round. pgbench exits when its connection is
# lost, so it runs in a loop.
set -uo pipefail

export PGHOST=/var/run/postgresql PGDATABASE=app PGUSER=postgres
BIN=/usr/lib/postgresql/18/bin

while true; do
  if [ "$("$BIN/psql" -X -qAt -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" != f ]; then sleep 2; continue; fi
  if [ "$("$BIN/psql" -X -qAt -c "SELECT to_regclass('public.pgbench_accounts') IS NOT NULL" 2>/dev/null)" != t ]; then
    "$BIN/pgbench" -i -s 5 -q >/dev/null 2>&1 || { sleep 2; continue; }
  fi
  # bound pgbench_history (about 6000 rows a minute) on the long-lived VMs
  "$BIN/psql" -X -qAt -c "DO \$\$ BEGIN IF (SELECT count(*) FROM pgbench_history) > 1000000 THEN TRUNCATE pgbench_history; END IF; END \$\$" >/dev/null 2>&1
  "$BIN/pgbench" -c 4 -j 2 -R 100 -T 60 -n >/dev/null 2>&1 || sleep 2
done
