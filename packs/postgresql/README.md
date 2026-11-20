# PostgreSQL pack

`queries.yaml` is the `sql_query` list every PostgreSQL target of the labs
shares; `rules.yml` and `tests/` are its alerts (group `postgresql`, and
`logical-replication` for subscriptions and logical slots, which fires only
where those exist). The metric list is generated:
[docs/reference/postgresql-pack-metrics.md](../../docs/reference/postgresql-pack-metrics.md).
Names follow [ADR 0006](../../docs/adr/0006-naming-contract.md).
`dashboards/postgresql.json` is the dashboard; slice1, pgha and k8s mount it.

## PostgreSQL version

The pack needs PostgreSQL 18 and is tested on 18 only. One query needs it:
the conflict counters query reads `confl_insert_exists` and six more `confl_*`
columns of `pg_stat_subscription_stats`, which the PostgreSQL 17 documentation
does not list and the 18 documentation does (both read 2026-11-11). On 17 or
older that query fails and only `postgresql.subscription.conflict` is lost;
each query runs on its own, so the others still report.

The remaining queries use columns from older releases. These versions are
from memory and not checked against the documentation (unverified):

- `reserved_connections` setting: 16.
- `pg_stat_subscription.worker_type`: 16.
- `pg_replication_slots.inactive_since` and `invalidation_reason`: 17.
- `pg_locks.waitstart`, `pg_get_wal_replay_pause_state()`: 14.
- `pg_stat_subscription_stats` itself: 15.

So the pack as a whole would need 18; the other queries alone would need 17.

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

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-postgresql*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/postgresql/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

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
