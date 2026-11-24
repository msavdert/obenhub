# slice1

Docker Compose project `obenhub-slice1`, versions pinned in `compose.yaml`.
Run it with `mise run lab:up` and `mise run lab:scenarios`; results are in
`results/runs.jsonl`.

## Prerequisites

Docker with Compose, and `mise install` for the tools. `mise run lab:up` starts
the lab and generates its `.env` with random passwords; `mise run lab:down`
stops it. Scenarios run on a clean tree, one suite at a time on the host.
The PostgreSQL image is built locally (`postgres/Dockerfile`: the pinned
postgres image plus pgBackRest from PGDG), so the first `lab:up` needs network
access to `apt.postgresql.org`.

## What runs

- PostgreSQL 19 primary and physical standby. Replication has its own network,
  so cutting it does not cut monitoring. A stack started on 18 (before
  roadmap E2) is not upgraded in place: `mise run lab:down` (deletes the
  volumes) before `mise run lab:up`.
- A logical subscriber `pg-subscriber` (database `app`, subscription
  `app_sub`) on its own `logical` network, so cutting logical replication
  leaves the physical standby and monitoring alone.
- PgBouncer 1.26.1 (CloudNativePG image) in front of database `app`,
  transaction pooling, `default_pool_size` 5. It has no metrics endpoint
  (pgbouncer#1354), so `sqlqueryreceiver` queries the admin console
  (`SHOW POOLS`, `SHOW DATABASES`, `SHOW LISTS`, `SHOW STATS`).
- One `otelcol-contrib` Collector: `postgresqlreceiver`, the shared
  PostgreSQL pack ([packs](../../packs)) and `filelog` on `jsonlog`.
  `postgresqlreceiver` v0.164.0 has no replication slot or subscription
  metrics, so the pack queries `pg_replication_slots`, `pg_subscription`,
  `pg_stat_subscription`, `pg_stat_subscription_stats` and `pg_stat_archiver`.
- pgBackRest 2.60.1 (ADR 0007; the exporter image bundles 2.60.0): the primary archives WAL with `archive-push`
  into a repository volume; the `pgbackrest-backup` service creates the stanza
  and keeps one backup per 600 s, scheduled from the repository (a full one when
  none exists or the last is older than ten intervals, else incremental);
  woblerr/pgbackrest_exporter v0.25.0 refreshes every 30 s and the Collector
  scrapes it (`prometheus/pgbackrest`); the pack is
  [packs/pgbackrest](../../packs/pgbackrest).
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
- `slot-retaining-wal` holds an inactive physical slot while 640 MiB of WAL
  is written, below `max_slot_wal_keep_size`, so the slot retains WAL without
  being invalidated; `PostgresPhysicalSlotInactive` fires with it.
- `archiver-failing` removes all access to the repository directory that
  holds the archived WAL (`chmod 000`) and switches WAL segments; both
  archiving alerts fire. Only the primary archives, with pgBackRest
  (`archive-push`); the standby and the subscriber do not archive. The same
  fault makes `pgbackrest info` report an error, so `PgBackRestStanzaError`
  and, after the revert, `PgBackRestBackupStale` may fire; the scenario allows
  both and expects neither.
- `backup-stale` takes a backup, stops the `pgbackrest-backup` service (a
  backup every 600 s) and expects `PgBackRestBackupStale` once the last backup
  is older than the lab's 780 s (`vmalert/rules/pgbackrest.yml`); detection
  takes about 15 minutes. The pack default is 26 h. `archiver-failing`,
  `slot-invalidated`, `slot-retaining-wal` and `checkpoint-pressure` pause the periodic backups for
  their run (each backup is a requested checkpoint).
- `backup-checksum-error` overwrites 16 bytes inside one page of a table on
  the primary's disk and takes a backup. pgBackRest logs an invalid page
  checksum, still ends the backup with exit code 0, and flags the backup;
  `PgBackRestBackupChecksumError` fires while `PgBackRestBackupStale` stays
  silent. The revert drops the table and takes a clean backup, which clears
  the flag; the damaged backup stays until retention expires it. Its time
  to detect includes the wait for checkpoint headroom before the damage
  (`inject_seconds`, limit 600 s); `damaged_backup_done` in the result row is
  when the damaged backup ended.
- `pitr-restore` writes marker rows, notes the time, writes more rows,
  restores with `pgbackrest restore --type=time` into a throwaway container
  and volume without network, and checks that only the earlier rows exist.
  The counts are in the result row. No alert is expected.
- `basebackup-compare` does the backup job with PostgreSQL's own tools in
  a throwaway container: full `pg_basebackup`, writes, `pg_basebackup
  --incremental`, `pg_combinebackup`, `pg_verifybackup`, then a point-in-time
  restore of the combined backup (WAL from the pgBackRest archive) and a row
  check. Step durations and sizes are in the result row; no alert is expected.
  It needs `summarize_wal=on`, set in `compose.yaml` (a lab started before
  that change needs its containers recreated). It pauses the periodic
  pgBackRest backups after taking one, and waits for a 5-minute window without
  a requested checkpoint, because both of its backups are requested
  checkpoints.
- `statements-evicted` runs `pg_stat_statements.max` plus 500 statements that
  differ in a table alias, so entries are evicted and
  `PostgresStatementsEvicted` fires; it needs the extension in database
  `postgres` (created by `postgres/10-init-primary.sh`). `lock-blocked` also
  checks that `postgresql.client_session.count` shows sessions with wait
  event type `Lock`.
- `pgbouncer-pool-saturated` opens more transactions than the pool size.

The Collector's overhead is measured in [lab/overhead](../overhead).
