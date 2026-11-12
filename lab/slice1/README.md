# slice1

Docker Compose project `obenhub-slice1`, versions pinned in `compose.yaml`.
Run it with `mise run lab:up` and `mise run lab:scenarios`; results are in
`results/runs.jsonl`.

## Prerequisites

Docker with Compose, and `mise install` for the tools. `mise run lab:up` starts
the lab and generates its `.env` with random passwords; `mise run lab:down`
stops it. Scenarios run on a clean tree, one suite at a time on the host.

## What runs

- PostgreSQL 18 primary and physical standby. Replication has its own network,
  so cutting it does not cut monitoring.
- A logical subscriber `pg-subscriber` (database `app`, subscription
  `app_sub`) on its own `logical` network, so cutting logical replication
  leaves the physical standby and monitoring alone.
- PgBouncer 1.26.1 (CloudNativePG image) in front of database `app`,
  transaction pooling, `default_pool_size` 5. It has no metrics endpoint
  (pgbouncer#1354), so `sqlqueryreceiver` queries the admin console
  (`SHOW POOLS`, `SHOW DATABASES`, `SHOW LISTS`, `SHOW STATS`).
- One `otelcol-contrib` Collector: `postgresqlreceiver`, the shared
  PostgreSQL pack ([lab/packs](../packs)) and `filelog` on `jsonlog`.
  `postgresqlreceiver` v0.164.0 has no replication slot or subscription
  metrics, so the pack queries `pg_replication_slots`, `pg_subscription`,
  `pg_stat_subscription`, `pg_stat_subscription_stats` and `pg_stat_archiver`.
- An expected-target inventory the heartbeat is checked against; PgBouncer's
  heartbeat is the `SHOW LISTS` row `databases`.
- VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager with a webhook sink
  that proves delivery, an always-firing Watchdog alert the sink must keep
  receiving, and one Grafana dashboard as code (replication, slots,
  subscription state, error counters, PgBouncer pools). `mise run
  lab:slice1:panels` runs its panel queries against the live Grafana.

## Scenarios

Each alert rule has `vmalert-tool unittest` tests and is fired by one
scenario in `scenarios/`; `control` is the no-fault run (only the Watchdog
fires, zero monitoring-role errors in the server log). Notable details:

- `connections-exhausted` sets `reserved_connections` and grants
  `pg_use_reserved_connections` to the monitoring role so it can still
  connect.
- `slot-invalidated` pushes a physical slot past `max_slot_wal_keep_size`,
  then checkpoints.
- `archiver-failing` makes `/archive` on the primary unwritable and switches
  WAL segments; both archiving alerts fire. Every node archives to its own
  volume with `postgres/archive-wal.sh`, which follows the PostgreSQL 18 docs
  (25.3.1): no overwrite, an identical re-archive after a crash succeeds;
  nothing prunes it. Measured 2026-11-12: about 116 MB per 10 minutes on
  average, about 320 MB per 10 minutes under the `control` run's pgbench load;
  the host had 206 GB free. `mise run lab:down` (`down -v`) clears it.
- `pgbouncer-pool-saturated` opens more transactions than the pool size.

The Collector's overhead is measured in [lab/overhead](../overhead).
