# ADR 0003: Receiver strategy - engine receivers, SQL query packs, upstream

- Status: Accepted; scraped endpoints and the pack layout refined by ADR 0005
- Date: 2026-11-06 (exporter evaluation added the same day; pack generator
  deferred the same day after a seven-model review)

## Context

The question was whether one generic receiver, `sqlqueryreceiver`, can carry
every database, or whether each engine's own receiver is the base. Checked on
opentelemetry-collector-contrib `main`, 2026-11-06:

`sqlqueryreceiver` (`receiver/sqlqueryreceiver`, `internal/sqlquery`):

- Drivers are Go `database/sql` only (postgres, mysql, sqlserver, oracle,
  clickhouse, snowflake, hdb, tds). MongoDB and Redis are not possible.
- No version-conditional SQL; different SQL per server version needs separate
  receiver instances.
- `collection_interval` and `timeout` are per receiver, not per query. The
  timeout is a client-side cancel, off by default, not a server-side
  `statement_timeout`.
- A failing query is logged and its series disappear; there is no per-query
  failure metric.
- `aggregation: delta` labels temporality; the receiver computes no deltas.
- Every query is independent; no multi-step logic (for example running EXPLAIN
  on statements found by an earlier query).
- `max_open_conn` defaults to unlimited.
- Stability: metrics alpha, logs development.

`postgresqlreceiver`: metrics beta (22 of 43 on by default), logs development.
It has stateful logic SQL cannot express: `db.server.top_query` (delta over
`pg_stat_statements`), `db.server.query_plan` (plan cache), and
`db.server.query_sample` with W3C `traceparent` correlation. It branches on
server version in places (`pg_stat_checkpointer` from 17, partitioned tables
from 14).

`oracledbreceiver`: metrics alpha (25 of 135 on by default), logs
development, with query_sample, top_query, query_plan, top_procedure and
session.wait_sample events. It branches on CDB/PDB and privileges, not on
version.

At contrib v0.164.0 (`18fcec7`) the receiver has no standby-side view: no
query reads `pg_stat_wal_receiver`, `pg_is_in_recovery()`,
`pg_replication_slots` or `pg_stat_io`. Replication lag comes only from the
primary's `pg_stat_replication` (`client.go`, `getReplicationStats`), with
`-1` for a NULL lag. `postgresql.wal.age` is seconds since
`pg_stat_archiver.last_archived_time` (its `metadata.yaml` says "age of the
oldest WAL file", which the code does not compute) and is silently absent
when nothing was archived yet (`errNoLastArchive`, `scraper.go`,
`collectWalAge`).

Earlier source reviews (private dbsight and dbwitness notes, contrib
v0.164.1) also found row caps without `ORDER BY` (blockers can be dropped),
facts detected only at start, and top-query deltas that misreport after a
restart or a `pg_stat_statements_reset()`.

## Decision

Three layers:

1. **Engine receiver as the base** (postgresql, oracledb, and later mysql,
   mongodb, redis and others). Anything that needs state or logic, and the
   metric names closest to semantic conventions, come from here.
2. **`sqlqueryreceiver` query packs fill the gaps.** Packs are hand-written
   `sqlqueryreceiver` configuration, one per engine and server major
   (PostgreSQL 18 first):
   - role: queries that must follow a failover are written role-tolerant
     and always return exactly one row: a `SELECT` without `FROM` whose
     columns are scalar subqueries or `EXISTS` over views such as
     `pg_stat_wal_receiver`, with `pg_is_in_recovery()` in a `CASE`, never
     in a `WHERE`. A standby that stopped streaming then reports 0 instead
     of a vanished series;
   - intervals: separate receiver instances per tier (for example 10 s,
     60 s, 5 min);
   - failure signal: see ADR 0002, decision 1.
   Every pack sets a server-side statement timeout in its SQL or role, and
   `max_open_conn` explicitly (3, as pg_exporter and sql_exporter do).
   A generator that reads version and extensions from the server and
   selects pack entries by `[min_version, max_version)` and tags (the
   pg_exporter design) is custom code; it is built only when a second
   PostgreSQL major makes the hand-written copies drift.
3. **Upstream pull requests make fixes permanent.** A pack that has proved
   itself in the lab becomes a PR to the engine receiver; generic gaps become
   PRs to `sqlqueryreceiver`. When upstream merges, the pack is retired.
   Candidates, each after checking for an existing issue:
   - `sqlqueryreceiver`: per-query failure counter plus optional duration
     and row-count metrics (all three evaluated exporters have this, which is
     the strongest argument for it upstream); per-query collection interval;
     per-query timeout, on by default and passed to the driver so the server
     cancels the statement; a bounded default for `max_open_conn`; per-query
     `min_version`/`max_version`; a "run only if" predicate query; several
     value columns into one metric with an attribute (`value_label`).
   - `postgresqlreceiver`: deterministic ordering under row caps; re-planning
     when recovery state, version or extensions change; replication slot
     `invalidation_reason`, `inactive_since`, conflicting/failover/synced;
     `pg_stat_io`; sequence exhaustion; settings pending restart; WAL archive
     failures. Check first which of these already exist.
   - `oracledbreceiver` (Oracle phase): alert log from `v$diag_alert_ext`
     with a high-water mark as a log event; tagging monitoring sessions with
     `DBMS_APPLICATION_INFO`.

## Exporter evaluation (2026-11-06, from source)

None of the three is run behind the Collector's `prometheus` receiver. Each
would add a second connection pool, Prometheus naming next to the receivers'
OTel names (duplicate series), and a single-maintainer release stream. What
each contributes instead:

| Project | Licence | Takeaway |
|---|---|---|
| pgsty/pg_exporter v1.5.0 | Apache-2.0 | The design for the deferred pack generator: version-ranged query branches, tag and predicate planning, re-plan on fact change, per-query TTL, timeout and self-metrics. 96 collector branches covering PG 10 to 19 (count unverified, no source recorded), the main source of SQL for our packs. Weak points: one target per process, self-counts exposed as gauges that reset on re-plan, 100 ms client-only default timeout, `sslmode=disable` when unset. Maintained by essentially one person. |
| burningalchemist/sql_exporter 0.24.13 | MIT | Per-collector `min_interval`, per-query error, duration and row metrics, a scrape deadline passed to the driver, `value_label`. No version mechanism. |
| CrunchyData/pgmonitor | Apache-2.0 | Its PG version handling lives in `pgmonitor-extension` (needs `CREATE EXTENSION`, possibly a preload), which we cannot assume on managed PG; PG 18 support not found. Its 40 PostgreSQL alert rules (plus Patroni, node, etcd) are the checklist for our rules. |
| oracle/oracle-db-appdev-monitoring 2.5.1 | MIT + UPL-1.0 | Only 12 default queries, no CDB or version awareness, OTLP push without a start time. Worth taking: per-metric interval and timeout, failure metric with a `result` attribute, alert log export, a few queries (tablespace, ASM guard, resource limits). Defaults avoid Diagnostics Pack views. |

SQL copied from these projects keeps its copyright notice and licence and
names the upstream file and commit (ADR 0004).

## Consequences

- obenhub shrinks as upstream grows; that is the intended direction.
- Metric names for pack output follow the names we would propose upstream,
  recorded in the naming contract (ADR 0006), so a later upstream merge does
  not rename series. OTel Weaver is a candidate tool for that registry (not
  yet evaluated).
