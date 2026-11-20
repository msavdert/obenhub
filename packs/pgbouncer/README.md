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
`tests/` (`mise run lab:pgbouncer:rules-test`).
`PgbouncerTargetAbsent` reads `obenhub.expected_target` from the lab's
inventory (`lab/slice1/vmalert/rules/postgresql.yml`) and the Collector's own
`otelcol_process_uptime` (the `collector` pack's prerequisite), matched on the
`obenhub.collector` label.

## Collection interval

The rules assume 15 s: the `sqlquery` receiver that reads `queries.yaml` sets
`collection_interval: 15s` in the lab. A window holds at least two
collections (`[75s:15s]` and `[75s]` in the saturation and wait rules).
`PgbouncerCollectionIntervalTooLong` fires when the samples of the heartbeat
row (`pgbouncer.list.item.count`, list `databases`) are on average more than
20 s apart; widen the windows before collecting slower.

## Thresholds

Every policy threshold is a production default in the rule that a lab can override with a recorded series; the series, defaults and units are in the generated table [pgbouncer-pack-alerts.md#thresholds](../../docs/reference/pgbouncer-pack-alerts.md#thresholds).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-pgbouncer*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/pgbouncer/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_PGBOUNCER_HOST` | PgBouncer host; also server.address | `pgbouncer` |
| `OBENHUB_PGBOUNCER_INSTANCE_ID` | service.instance.id | `pgbouncer` |
| `OBENHUB_PGBOUNCER_PASSWORD` | its password |  |
| `OBENHUB_PGBOUNCER_PORT` | PgBouncer port; also server.port | `6432` |
| `OBENHUB_PGBOUNCER_SSLMODE` | sslmode of the console connection | `disable` |
| `OBENHUB_PGBOUNCER_USER` | stats user of the admin console | `otel_monitor` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
