# PostgreSQL pack

`queries.yaml` is the `sql_query` list every PostgreSQL target of the labs
shares (every 15 s), `queries-slow.yaml` the slow tier of queries whose cost
grows with the number of relations (every 5 minutes, see "Slow tier"); `rules.yml` and `tests/` are its alerts (group `postgresql`, and
`logical-replication` for subscriptions and logical slots, which fires only
where those exist). The metric list is generated:
[docs/reference/postgresql-pack-metrics.md](../../docs/reference/postgresql-pack-metrics.md).
Names follow [ADR 0006](../../docs/adr/0006-naming-contract.md).
`dashboards/postgresql.json` is the dashboard; slice1, pgha and k8s mount it.

## PostgreSQL version

Every query in `queries.yaml` and `queries-slow.yaml` has a `# pg-min: <N>` line in its comment block,
the lowest major it runs on. `mise run packs:sql-test` starts a throwaway
container of each supported major (15 to 19, the majors not end of life on
endoflife.date on 2026-11-23, plus 19, released 2026-11-19; images pinned in `tests/images.sh`), creates the
monitoring role and runs every query as `otel_monitor`: it must succeed from
`pg-min` up and fail with an SQL error below it. It is part of `mise run
check`. A query that fails on an older major loses only its own metrics; the others
still report. The test prints only ok or an SQL error per major. The reasons
below are not produced by it: they are read from `packs:catalog-diff` outputs
(16 to 17, 17 to 18, 15 to 16) on 2026-11-23 and 18 to 19 on 2026-11-24.

| Query (first metric) | pg-min | Reason |
| --- | --- | --- |
| `postgresql.replication_slot.active` | 17 | `inactive_since`, `invalidation_reason` of `pg_replication_slots` |
| `postgresql.subscription.enabled` | 17 | `pg_stat_subscription.worker_type` |
| `postgresql.subscription.conflict` | 15 | no rows below 18: the `confl_*` columns of `pg_stat_subscription_stats` (18, `confl_update_deleted` 19) are read as keys of `to_jsonb(t)` (roadmap E3) |

The other queries run on 15. `postgresql.subscription.sync_error` reads
`sync_error_count` below 19 and the sum of `sync_table_error_count` and
`sync_seq_error_count` from 19, the same way. `monitoring-role.sql` grants
`pg_use_reserved_connections` only where the role exists (16 and later).

`mise run packs:catalog-diff <old> <new>` (for example `17 18`) lists the
`pg_catalog` columns and functions the queries mention that were added,
removed or changed between two majors, from the same images. Run it when a
new major or minor is pinned; a new query takes its `pg-min` from the test.

## Statements and wait events

`postgresql.statement.*` and `postgresql.client_session.count` follow [ADR 0009](../../docs/adr/0009-query-and-relation-cardinality.md): per-database totals and one series per state and wait event, never a query or its id.

- Requirement: `pg_stat_statements` in `shared_preload_libraries` and `CREATE EXTENSION pg_stat_statements` in database `postgres`, the database the pack connects to (slice1: `shared_preload_libraries` in `lab/slice1/compose.yaml`, the extension in `lab/slice1/postgres/10-init-primary.sh`). The monitoring role needs `pg_monitor`: `pg_read_all_stats` for the view and `pg_read_all_settings` for the preload check; a role without the latter gets no statement series and no error.
- Guard: without the extension in that database the two statement queries return no rows and no error, so there are no `postgresql.statement.*` series and no alert. The SQL text is passed to `query_to_xml()` behind a `pg_extension` check, because a plain query fails at parse time. `mise run packs:sql-test` runs both queries on every supported major before and after `CREATE EXTENSION` (containers start with the library preloaded) and checks no rows, then rows.
- `postgresql.statement.execution_time`, `.call` and `.temp_block_written` are gauges, not counters: a statement evicted from the view leaves the sum. Do not `rate()` them (a fall reads as a counter reset); the dashboard uses `deriv()` clamped at 0. `postgresql.statement.deallocation` is the cumulative eviction count and `PostgresStatementsEvicted` fires when it rises: the totals then undercount.
- Per-statement data is not a metric of the pack: the receiver's `db.server.top_query` log event is off in the pack and on in slice1 (ADR 0009 decision 3; configuration and scenario in [lab/slice1](../../lab/slice1/README.md)).
- `postgresql.client_session.count` has the attributes `postgresql.session.state`, `postgresql.wait_event.type` and `postgresql.wait_event.name`; a missing value is the string `none`.

## Slow tier

`queries-slow.yaml` is read by a second `sql_query` receiver, `sql_query/obenhub-postgresql-slow` in `otelcol.yaml`, with `collection_interval: 5m` and `max_open_conn: 1`, so a catalog-heavy query never runs at 15 s on a busy primary ([ADR 0009](../../docs/adr/0009-query-and-relation-cardinality.md) decision 5; roadmap F1). Its series are one per database: `postgresql.autovacuum.pending_table.count` (tables whose `n_dead_tup` is above `autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples`, storage parameters of the table honoured, tables with autovacuum disabled left out), `postgresql.autovacuum.disabled_table.count`, `postgresql.autovacuum.enabled`, `postgresql.track_counts.enabled` and `postgresql.collection.slow_heartbeat`. Rules: `PostgresAutovacuumOff`, `PostgresAutovacuumBacklog`, `PostgresAutovacuumTableDisabled`, `PostgresSlowCollectionIntervalTooLong` and `PostgresSlowTierStalled` (group `postgresql-slow`).

- One instance reads one database. `pg_stat_user_tables` and `pg_class` show only the connected database, so the `database` of the receiver is the one database read and the attribute `postgresql.database.name` is `current_database()`. The fragment reads `OBENHUB_PG_SLOW_DATABASE`. To read another database, copy the `sql_query/obenhub-postgresql-slow` block under a new name (for example `sql_query/obenhub-postgresql-slow-sales`), set its `database`, and add it to the `receivers` of the metrics pipeline; no other change is needed, the series differ by the database attribute and the rules group by it. A database without tables of interest (the labs leave out `postgres`) needs no instance.
- The lab Collectors read database `app` only (slice1: primary, standby and subscriber; stage3, pgha and k8s: every node), the one with tables in every lab.
- On a server in recovery every slow-tier query except the heartbeat returns no row: autovacuum does not run on a standby and its statistics are not those of the primary, so there is no backlog series there, and the series appear after a promotion.
- The threshold is the one the autovacuum launcher applies (PostgreSQL docs, "Routine Vacuuming"), evaluated from the statistics views. "Tables without recent writes" are not left out: autovacuum does not look at write recency, and no statistics view holds a last-write time. The insert-triggered threshold (13 and later) is not read.
- The cost grows with the number of tables of the database (one `pg_options_to_table` call per table); at 5 minutes that is 12 scans an hour. Not measured on a database with many tables.

## Series per table

The upstream `postgresql` receiver's per-table metrics are enabled by default and produce one series per table (and per index for `postgresql.index.*`) with no limit: `postgresql.rows`, `postgresql.operations`, `postgresql.table.size`, `postgresql.table.vacuum.count`, `postgresql.blocks_read`, `postgresql.index.scans` and `postgresql.index.size` (ADR 0009, decision 6, read at contrib v0.165.0). No rule or panel of the pack reads them. On a database with many relations, switch them off in the receiver block of the Collector configuration:

```yaml
receivers:
  postgresql/obenhub-postgresql:
    metrics:
      postgresql.deadlocks:
        enabled: true
      postgresql.rows: {enabled: false}
      postgresql.operations: {enabled: false}
      postgresql.table.size: {enabled: false}
      postgresql.table.vacuum.count: {enabled: false}
      postgresql.blocks_read: {enabled: false}
      postgresql.index.scans: {enabled: false}
      postgresql.index.size: {enabled: false}
```

Not run in a lab: the `enabled: false` form is the receiver's metric setting (the same form as `postgresql.deadlocks` above), unconfirmed for these seven names until a run.

## Checks

`scripts/check-pack-names.py` (part of `mise run check`) fails when a pack
metric has no unit, ends in a unit word, has an undotted attribute, or has the
name of a postgresqlreceiver metric (`upstream-receiver-metrics.txt`).

`scripts/check-series-vanished.py` (`mise run lint:series-vanished`) fails when
the metric list of `PostgresSeriesVanished` in `rules.yml` differs from
`queries.yaml`; the one metric left out on purpose (the heartbeat) is listed,
with the reason, in the script.

## Collection interval

The rules assume 15 s for every source of the pack: the `postgresql` receiver
and each `sqlquery` receiver that reads `queries.yaml` set
`collection_interval: 15s` in every lab. A window holds at least two
collections: `[30s]` for the latest value, `[75s:15s]` and `[45s:15s]` for
the sustained-condition tiers. A source set to 60 s would leave those windows
with one sample or none, so the rules would go quiet or flap without an
error; `PostgresCollectionIntervalTooLong` fires when the samples of
`postgresql.collection.heartbeat` are on average more than 20 s apart. To
collect slower, widen every window to at least twice the new interval first.

The slow tier is collected every 5 minutes (`sql_query/obenhub-postgresql-slow`, `collection_interval: 5m`) and its rules, in group `postgresql-slow`, are sized for that: `[10m]` for the latest value (two collections), `[15m]` for presence (three), `[30m]` for the interval check (six), and a `for` that is a multiple of 5 minutes, so detection takes up to one interval plus the hold (`PostgresAutovacuumOff` 5 m, `PostgresAutovacuumBacklog` and `PostgresAutovacuumTableDisabled` 15 m). Every rule over a slow-tier series uses `last_over_time` over such a window and does not read the series directly or rely on staleness: how long VictoriaMetrics keeps a 5 minute series as the latest value is not confirmed here. `PostgresSlowCollectionIntervalTooLong` fires when the samples of `postgresql.collection.slow_heartbeat` are on average more than 450 s apart over 30 minutes, and `PostgresSlowTierStalled` when a database that reported it in the last hour has sent none for 15 minutes. `PostgresSeriesVanished` does not watch these series: its 2 minute window is shorter than their interval (`scripts/check-series-vanished.py` fails when one is added to it). To collect the slow tier slower, widen every window of that group to at least twice the new interval first.

## Thresholds

Every policy threshold is a production default in the rule that a lab can override with a recorded series; the series, defaults and units are in the generated table [postgresql-pack-alerts.md#thresholds](../../docs/reference/postgresql-pack-alerts.md#thresholds).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-postgresql*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/postgresql/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_PG_CA_FILE` | CA file that verifies the server certificate | `/etc/otelcol-contrib/tls/ca.crt` |
| `OBENHUB_PG_DATABASES` | databases the receiver connects to, a YAML list | `[postgres, app]` |
| `OBENHUB_PG_HOST` | PostgreSQL host; also server.address | `db1.example.net` |
| `OBENHUB_PG_INSTANCE_ID` | service.instance.id, unique within the cluster | `pgha-1` |
| `OBENHUB_PG_LOG_GLOB` | glob of the jsonlog files | `/var/log/postgresql/postgresql-*.json` |
| `OBENHUB_PG_PASSWORD` | its password; from a secret store, never a file in a repository |  |
| `OBENHUB_PG_PORT` | PostgreSQL port; also server.port | `5432` |
| `OBENHUB_PG_SLOW_DATABASE` | the one database the slow tier reads ("Slow tier" below) | `app` |
| `OBENHUB_PG_SSLMODE` | sslmode of sql_query | `verify-full` |
| `OBENHUB_PG_TLS_INSECURE` | true turns TLS off for the postgresql receiver; keep it consistent with the sslmode | `false` |
| `OBENHUB_PG_USER` | monitoring role (packs/postgresql/monitoring-role.sql) | `otel_monitor` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
