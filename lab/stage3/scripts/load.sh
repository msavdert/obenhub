#!/usr/bin/env bash
# Client load for the stage 3 lab. PGHOST (a list), PGTARGETSESSIONATTRS and
# the credentials come from the environment (libpq multi-host, PostgreSQL 14+).
# pgbench exits when its connection is lost, so it runs in a loop: after a
# failover the next run connects to whichever node is writable.
set -uo pipefail

until psql -X -qAt -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done

# a modest steady rate: enough WAL to show lag, little enough for 3 small nodes.
# 20 tps, not 100: on the box disk each commit is an fsync on the leader and on
# both replicas, and at 100 tps those fsyncs pushed the etcd backend commit p99
# past the EtcdHighCommitDurations threshold (0.25 s) with no fault injected
# (2026-11-17: load stopped -> box IO pressure 34% -> 2%, flushes 240/s -> 9/s).
# The scenarios write their own WAL; they only need the load to be running.
# The tables are checked on every round, so a failed initialisation is retried.
while true; do
  if [ "$(psql -X -qAt -c "SELECT to_regclass('public.pgbench_accounts') IS NOT NULL" 2>/dev/null)" != t ]; then
    pgbench -i -s 5 -q >/dev/null 2>&1 || { sleep 2; continue; }
  fi
  pgbench -c 4 -j 2 -R 20 -T 60 -n >/dev/null 2>&1 || sleep 2
done
