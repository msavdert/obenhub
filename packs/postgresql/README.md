# PostgreSQL pack

`queries.yaml` is the `sql_query` list every PostgreSQL target of the labs
shares; `rules.yml` and `tests/` are its alerts (group `postgresql`, and
`logical-replication` for subscriptions and logical slots, which fires only
where those exist). The metric list is generated:
[docs/reference/postgresql-pack-metrics.md](../../docs/reference/postgresql-pack-metrics.md).
Names follow [ADR 0006](../../docs/adr/0006-naming-contract.md).
`dashboards/postgresql.json` is the dashboard; slice1, pgha and k8s mount it.

## PostgreSQL version

Every query in `queries.yaml` has a `# pg-min: <N>` line in its comment block,
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
| `postgresql.snapshot.oldest_age` | 16 | setting `reserved_connections` |
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
| `OBENHUB_PG_SSLMODE` | sslmode of sql_query | `verify-full` |
| `OBENHUB_PG_TLS_INSECURE` | true turns TLS off for the postgresql receiver; keep it consistent with the sslmode | `false` |
| `OBENHUB_PG_USER` | monitoring role (packs/postgresql/monitoring-role.sql) | `otel_monitor` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
