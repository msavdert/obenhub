# PgBouncer pack

`queries.yaml` is the `sql_query` list that reads the PgBouncer admin console
(`SHOW POOLS`, `DATABASES`, `STATS`, `CONFIG`, `LISTS`) because PgBouncer has
no metrics endpoint (pgbouncer#1354). The metric list is generated:
[docs/reference/pgbouncer-pack-metrics.md](../../docs/reference/pgbouncer-pack-metrics.md).
Names follow [ADR 0006](../../docs/adr/0006-naming-contract.md); there is no
upstream PgBouncer receiver, so `scripts/check-pack-names.py` checks only the
form of the names.

## Prerequisites

- A stats user (the lab uses `otel_monitor`) that may connect
  to the `pgbouncer` database. The console speaks only the simple query
  protocol; the receiver's no-argument queries qualify.
- The Collector pipeline renames the bare columns `database`, `name`, `user`
  and `list` to `pgbouncer.*` attributes and converts microseconds to seconds
  (`attributes/pgbouncer`, `transform/pgbouncer-seconds` in
  `lab/slice1/otelcol/config.yaml`); the rules read the renamed series.
- PgBouncer 1.26.1 is the version the lab ran; other versions are not tested.

## Alert rules

`rules.yml` holds the `pgbouncer` group (`PgbouncerTargetAbsent`,
`PgbouncerClientsWaiting`, `PgbouncerPoolSaturated`,
`PgbouncerClientSaturation` in two tiers, `PgbouncerWaitTime`), unit-tested in
`tests/` (`mise run lab:pgbouncer:rules-test`). Thresholds are lab values.
`PgbouncerTargetAbsent` reads `obenhub.expected_target` from the lab's
inventory (`lab/slice1/vmalert/rules/postgresql.yml`) and the Collector's own
`otelcol_process_uptime` (the `collector` pack's prerequisite), matched on the
`obenhub.collector` label.
