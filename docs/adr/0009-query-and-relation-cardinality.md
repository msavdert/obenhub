# ADR 0009: Query-level and relation-scaled signals - cardinality

- Status: Accepted (owner, 2026-11-24)
- Date: 2026-11-24

## Context

Roadmap item F1 adds query-level telemetry from `pg_stat_statements`,
autovacuum and dead tuples, and wait events, and asks for a decision on
cardinality before any SQL. F5 adds sequence and invalid-index queries that
scale with the number of relations in the same way.

What the pinned `postgresqlreceiver` already does, read at contrib tag
v0.165.0 (`receiver/postgresqlreceiver/metadata.yaml`, `scraper.go`,
`templates/topQueryTemplate.tmpl`, `templates/querySampleTemplate.tmpl`) on
2026-11-24:

- Per-table metrics, enabled by default: `postgresql.rows` (attribute
  `state`, `live` or `dead`, from `n_live_tup` and `n_dead_tup`),
  `postgresql.operations`, `postgresql.table.size`,
  `postgresql.table.vacuum.count`, `postgresql.blocks_read`,
  `postgresql.index.scans`, `postgresql.index.size`. The SQL has no limit on
  the number of tables. The labs enable neither feature gate
  `receiver.postgresql.separateSchemaAttr` nor
  `receiver.postgresql.useOTelSemconv` (both alpha), so the scraper runs its
  legacy mode with one resource per table. No pack rule or dashboard panel
  reads any of these metrics.
- `postgresql.table.vacuum.count` counts manual vacuums only
  (`vacuum_count`); nothing reads `autovacuum_count`, the autovacuum
  thresholds or the `autovacuum` and `track_counts` settings.
- The checkpointer and background writer are covered by
  `postgresql.bgwriter.*`, enabled by default, reading
  `pg_stat_checkpointer` on PostgreSQL 17 and later.
- `postgresql.query.execution.time` (disabled by default) is
  `sum(total_exec_time)` from `pg_stat_statements` per database. It reads
  the view directly, so on a server without the extension every scrape
  reports an error (`client.go`, `getExecutionTimeStats`).
- Per-statement data exists only as log events, all disabled by default, in a
  signal at stability `development`: `db.server.top_query`,
  `db.server.query_plan` and `db.server.query_sample` (rows of
  `pg_stat_activity` with `wait_event_type` and `wait_event`).
- `db.server.top_query` reads up to `max_rows_per_query` statements
  (default 1000) `ORDER BY calls DESC` every
  `top_query_collection.collection_interval` (default 1m), turns the
  counters into deltas against the previous scrape, drops statements with no
  new execution time and emits the `top_n_query` (default 200) with the
  largest execution-time delta (`topQueryTemplate.tmpl`, `scraper.go`
  `collectTopQuery`). A slow statement outside the 1000 most called is not
  seen. The first scrape after a Collector start or a
  `pg_stat_statements_reset()` has no previous value, so it ranks by
  lifetime totals instead of recent load.
- For each emitted statement whose plan is not cached, `collectTopQuery`
  runs `PREPARE` and `EXPLAIN (FORMAT JSON) EXECUTE` on the monitored server,
  up to `max_explain_each_interval` (default 1000) per interval, whether or
  not `db.server.query_plan` is enabled; that event only decides whether
  the plan is emitted (`scraper.go`, `client.go` `explainQuery`).
- There is no wait-event metric.

The pack collects everything at 15 s (`packs/postgresql/README.md`,
"Collection interval"), and its `pg_stat_activity` reads are five scans in
two queries (F4).

## Decision

1. No metric series carries `queryid`, query text, a role, a table, an
   index or a sequence as an attribute from the pack's own SQL. The largest
   attribute set a pack query may emit is per database plus a value from a
   vocabulary that PostgreSQL defines (a state, a wait event type, a wait
   event name). Unconfirmed: whether extensions can add wait event names
   (custom wait events, LWLock tranches); if they can, the vocabulary is
   bounded in practice, not closed.
2. Query-level metrics are per-database totals from `pg_stat_statements`
   in pack SQL: execution time, calls, temporary blocks written, and the
   deallocation count from `pg_stat_statements_info`, which shows that
   statements are evicted and the totals undercount. A plain query on a
   server without the extension fails at parse time (`relation
   "pg_stat_statements" does not exist`, run on the slice1 PostgreSQL 18.7
   image), so these queries need a guard: `query_to_xml` behind a check of
   `pg_extension` returned no rows and no error in the same run. The first
   query settles which guard the pack uses. The receiver's
   `postgresql.query.execution.time` stays off: it would report an error on
   every scrape of a server without the extension.
3. The bounded top-K is the receiver's `db.server.top_query` event, shipped
   as logs to VictoriaLogs, never converted to metrics. It is off in the
   pack and on in slice1 at a 5 m interval with `top_n_query: 20`,
   `max_rows_per_query: 200` and `max_explain_each_interval: 0`, so that
   the monitoring user runs no `EXPLAIN` on the monitored server;
   `db.server.query_plan` stays off. That 0 disables `EXPLAIN` (the source
   tests `explained < max_explain_each_interval`, false for 0) and that the
   config accepts it (`Validate` in `config.go` does not check the field)
   was confirmed by the `top-query` scenario in slice1 suite
   `slice1-20261125T185820Z-2edce7c`: two `db.server.top_query` records,
   no `EXPLAIN` from the monitoring user. Because the signal is at stability
   `development` and sees only the most called statements, no rule depends
   on it; it is a diagnostic stream.
4. Wait events are one `pg_stat_activity` scan grouped by `state`,
   `wait_event_type` and `wait_event`, which F4 also uses to merge the
   existing five scans into one. Only combinations present at scrape time
   produce series.
5. Signals whose cost grows with the number of relations (dead tuples as
   the autovacuum backlog, F5 sequences and invalid indexes) run in a second `sql_query`
   receiver of the pack with its own query file and a 5 m
   `collection_interval`, and are aggregated in SQL to one value per
   database. Rules over that tier use windows of at least two of its
   intervals, as the README rule for the 15 s tier already requires.
6. The receiver's per-table metrics keep their upstream defaults. The pack
   README states that they produce series per table without a limit and how
   to disable them on a database with many relations. No pack rule reads
   them; the dead-tuple signal of the pack is the per-database backlog of
   decision 5.

## Consequences

- A database with any number of statements or relations adds a fixed,
  small number of series from the pack; query detail lives in logs, where
  volume is bounded by `top_n_query` and the interval, and the load on the
  monitored server by `max_rows_per_query`.
- Per-statement history in metrics (a time series per slow query) is not
  available; it is read from VictoriaLogs.
- The 5 m tier needs its own collection check:
  `PostgresCollectionIntervalTooLong` covers the 15 s tier only.
- Unconfirmed until run: that `pg_monitor` can read `pg_stat_statements`
  text and `pg_stat_statements_info` on every supported major, and how
  VictoriaMetrics treats staleness for a series written every 5 m. Both are
  checked by `packs:sql-test` and a slice1 run before the first rule over
  the slow tier.
