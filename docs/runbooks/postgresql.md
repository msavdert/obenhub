# PostgreSQL pack runbook

One section for each alert of `packs/postgresql/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/postgresql-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

Query several sections use, the slot query of `packs/postgresql/queries.yaml` with the columns unaggregated:

```sql
SELECT slot_name, slot_type, active, wal_status, invalidation_reason, inactive_since, restart_lsn,
       pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN greatest(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
                           ELSE pg_current_wal_lsn() END, restart_lsn) AS retained_wal
FROM pg_replication_slots;
```

## PostgresTargetAbsent

The Collector is alive but the PostgreSQL target has sent no heartbeat for 2 minutes: PostgreSQL is down or the monitoring role cannot connect. Reference: [PostgresTargetAbsent](../reference/postgresql-pack-alerts.md#postgrestargetabsent).

Look first: Run the heartbeat query as the monitoring role.

```sql
SELECT 1 AS collection_heartbeat;
```

The first query of `packs/postgresql/queries.yaml`; if it fails, its error is the cause.

Look first: Errors of the monitoring role in the PostgreSQL log.

```logsql
service.name:=postgresql user:=otel_monitor error_severity:in(ERROR,FATAL,PANIC) _time:>$T_START | sort by (_time desc) | limit 20 | fields _time,_msg
```

Form from `lab/slice1/scenarios/control.sh` (the k8s lab names the field `user_name`, `lab/k8s/scenarios/control.sh`) and `lab/pgha/scenarios/leader-killed.sh` (sort, limit, fields); run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`. `$T_START` is an RFC 3339 time.

Seen in the lab:

- slice1: `standby-stopped` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresStandbyNotStreaming

A standby is in recovery without a streaming WAL receiver while another member is writable. Reference: [PostgresStandbyNotStreaming](../reference/postgresql-pack-alerts.md#postgresstandbynotstreaming).

Look first: On the standby, then on the primary.

```sql
SELECT pg_is_in_recovery() AS recovery_active,
       (EXISTS (SELECT 1 FROM pg_stat_wal_receiver WHERE status = 'streaming'))::int AS wal_receiver_streaming;
SELECT * FROM pg_stat_wal_receiver;      -- standby
SELECT * FROM pg_stat_replication;       -- primary
```

The first statement is the recovery and receiver part of the second query of `packs/postgresql/queries.yaml`; the views are those the description names.

Seen in the lab:

- k8s: `replica-cut`, `slot-retaining-wal` (suite `k8s-20261118T194429Z-37e22f2`)
- pgha: `network-partition-replica`, `replica-not-eligible`, `synchronous-standby-cut` (suite `pgha-20261118T225346Z-e47dc14`)
- slice1: `repl-cut` (suite `slice1-20261118T134118Z-37e22f2`)
- stage3: `replica-not-eligible` (suite `stage3-20261118T214721Z-e47dc14`)

## PostgresSynchronousStandbyMissing

The primary lists fewer synchronous standbys than `synchronous_standby_names` requires, so commits wait. Reference: [PostgresSynchronousStandbyMissing](../reference/postgresql-pack-alerts.md#postgressynchronousstandbymissing).

Look first: On the primary.

```sql
SELECT current_setting('synchronous_standby_names') AS synchronous_standby_names,
       (SELECT count(*) FROM pg_stat_replication WHERE sync_state IN ('sync', 'quorum')) AS synchronous_standby_count;
```

The synchronous replication query of `packs/postgresql/queries.yaml`, without the parsing of the setting.

Seen in the lab:

- pgha: `synchronous-standby-cut` (suite `pgha-20261118T225346Z-e47dc14`)

## PostgresReplayBacklog

A standby has received WAL that it has not replayed. Reference: [PostgresReplayBacklog](../reference/postgresql-pack-alerts.md#postgresreplaybacklog).

Look first: On the standby.

```sql
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_backlog,
       pg_get_wal_replay_pause_state() AS replay_pause_state;
```

The replay backlog and pause columns of the second query of `packs/postgresql/queries.yaml`; a state other than `not paused` is the paused case.

Seen in the lab:

- pgha: `replay-paused` (suite `pgha-20261118T225346Z-e47dc14`)
- slice1: `replay-paused` (suite `slice1-20261118T134118Z-37e22f2`)
- stage3: `replay-paused` (suite `stage3-20261118T214721Z-e47dc14`)

## PostgresSnapshotHeldTooLong

A client transaction or prepared transaction has held a snapshot or an xid for longer than its limit (1800 s unless the lab sets `obenhub.postgresql.snapshot_age.limit`), which holds back the xmin horizon. Reference: [PostgresSnapshotHeldTooLong](../reference/postgresql-pack-alerts.md#postgressnapshotheldtoolong).

Look first: On the instance named in the alert.

```sql
SELECT pid, state, xact_start, clock_timestamp() - xact_start AS age, backend_xmin, backend_xid
FROM pg_stat_activity
WHERE (backend_xmin IS NOT NULL OR backend_xid IS NOT NULL)
  AND backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY xact_start;
SELECT * FROM pg_prepared_xacts;
```

The `snapshot_oldest_age` part of the third query of `packs/postgresql/queries.yaml`, listing sessions instead of taking the maximum.

Seen in the lab:

- slice1: `lock-blocked`, `snapshot-held` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresConnectionSaturation

Client connections use more than 85 % of the connection limit (critical at 95 %). Reference: [PostgresConnectionSaturation](../reference/postgresql-pack-alerts.md#postgresconnectionsaturation).

Look first: On the instance named in the alert.

```sql
SELECT state, count(*) FROM pg_stat_activity
WHERE backend_type = 'client backend' GROUP BY state ORDER BY count(*) DESC;
SELECT current_setting('max_connections')::int
     - current_setting('superuser_reserved_connections')::int
     - current_setting('reserved_connections')::int AS client_connection_limit;
```

The count and the limit of the third query of `packs/postgresql/queries.yaml`; `state` is grouped here to see who holds the connections.

Seen in the lab:

- slice1: `connections-exhausted` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresIdleInTransaction

A client session has been idle in a transaction for more than 300 seconds (critical over 1800 s) unless the lab sets `obenhub.postgresql.idle_in_transaction_age.limit` per severity. Reference: [PostgresIdleInTransaction](../reference/postgresql-pack-alerts.md#postgresidleintransaction).

Look first: On the instance named in the alert.

```sql
SELECT pid, state, state_change, clock_timestamp() - state_change AS idle_for
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND state IN ('idle in transaction', 'idle in transaction (aborted)')
  AND pid <> pg_backend_pid()
ORDER BY state_change;
```

The idle-age query of `packs/postgresql/queries.yaml`, listing sessions instead of taking the maximum.

Seen in the lab:

- slice1: `idle-in-transaction`, `lock-blocked`, `pgbouncer-pool-saturated` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresBlockedSessions

A session has waited more than its limit (120 s unless the lab sets `obenhub.postgresql.lock_wait_age.limit`) for a lock. Reference: [PostgresBlockedSessions](../reference/postgresql-pack-alerts.md#postgresblockedsessions).

Look first: On the instance named in the alert.

```sql
SELECT pid, locktype, mode, clock_timestamp() - waitstart AS waiting
FROM pg_locks WHERE NOT granted ORDER BY waitstart;
SELECT pid, pg_blocking_pids(pid) AS blockers FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

The first statement is the lock-wait query of `packs/postgresql/queries.yaml` per row; that file's comment names `pg_blocking_pids()` as left out of the collection on purpose, which is why the second statement is for a person to run once.

Seen in the lab:

- slice1: `lock-blocked` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresDeadlocks

The deadlock counter of a database rose within 5 minutes; PostgreSQL aborted one session of each deadlock. Reference: [PostgresDeadlocks](../reference/postgresql-pack-alerts.md#postgresdeadlocks).

Look first: On the instance named in the alert.

```sql
SELECT datname, deadlocks FROM pg_stat_database ORDER BY deadlocks DESC;
```

The counter the alert reads (`postgresql.deadlocks` of the stock receiver); query form from `lab/slice1/scenarios/deadlock.sh`.

Seen in the lab:

- slice1: `deadlock` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresStatementsEvicted

More distinct statements arrived than `pg_stat_statements.max` holds within 5 minutes, so the least used entries were evicted and the statement totals of the pack (`postgresql.statement.*`) undercount. Reference: [PostgresStatementsEvicted](../reference/postgresql-pack-alerts.md#postgresstatementsevicted).

Look first: On the instance named in the alert.

```sql
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
SELECT current_setting('pg_stat_statements.max') AS max, count(*) AS entries FROM pg_stat_statements;
```

The first statement is the counter the alert reads (the deallocation query of `packs/postgresql/queries.yaml`). Raising `pg_stat_statements.max` needs a restart; statements that differ only in literals are one entry, so a flood of entries usually means unparameterised or generated SQL.

Seen in the lab:

- slice1: `statements-evicted` (suite `none yet`)

## PostgresAutovacuumOff

The `autovacuum` or `track_counts` setting is off (the `setting` label says which), as read by the slow tier every 5 minutes. Without either, dead tuples are cleaned up only to prevent transaction ID wraparound. Reference: [PostgresAutovacuumOff](../reference/postgresql-pack-alerts.md#postgresautovacuumoff).

Look first: On the instance named in the alert.

```sql
SELECT name, setting, source, sourcefile FROM pg_settings WHERE name IN ('autovacuum', 'track_counts');
```

A `source` of `configuration file` with `postgresql.auto.conf` means `ALTER SYSTEM`; `ALTER SYSTEM RESET autovacuum` and `SELECT pg_reload_conf()` undo it. The series are `postgresql.autovacuum.enabled` and `postgresql.track_counts.enabled` of `packs/postgresql/queries-slow.yaml`.

Seen in the lab:

- slice1: `autovacuum-off` (suite `none yet`)

## PostgresAutovacuumBacklog

Tables of a database have had more dead tuples than their effective autovacuum vacuum threshold, with no vacuum finished on them in the last three `autovacuum_naptime` intervals, at three collections in a row (every 5 minutes). Reference: [PostgresAutovacuumBacklog](../reference/postgresql-pack-alerts.md#postgresautovacuumbacklog).

Look first: In the database named in the alert, on the instance named in the alert.

```sql
SELECT s.relname, s.n_dead_tup, c.reltuples, c.reloptions, s.last_autovacuum, s.last_vacuum
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
ORDER BY s.n_dead_tup DESC LIMIT 20;
SELECT pid, relid::regclass, phase FROM pg_stat_progress_vacuum;
```

The first statement lists the tables the count is made of; the threshold of a table is `autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples` (the storage parameter in `reloptions` when set, else the setting; from PostgreSQL 18 capped by `autovacuum_vacuum_max_threshold`), the condition in the second query of `packs/postgresql/queries-slow.yaml`. A table vacuumed within the last three `autovacuum_naptime` intervals is not counted, even when it is past the threshold again: autovacuum reaches it (a small table with many updates crosses its threshold between rounds), and a table whose dead tuples a VACUUM cannot remove is held by an old snapshot or a replication slot, which `PostgresSnapshotHeldTooLong` and `PostgresXminHorizonHeld` report. A counted table was not vacuumed for longer: autovacuum is off for it (`PostgresAutovacuumOff`), too slow for the write rate (`autovacuum_vacuum_cost_limit`, `autovacuum_max_workers`), or one VACUUM on it runs longer than three rounds (`pg_stat_progress_vacuum`).

Seen in the lab:

- slice1: `autovacuum-backlog` (suite `none yet`)

## PostgresAutovacuumTableDisabled

Tables of a database have the storage parameter `autovacuum_enabled` set to false. Reference: [PostgresAutovacuumTableDisabled](../reference/postgresql-pack-alerts.md#postgresautovacuumtabledisabled).

Look first: In the database named in the alert, on the instance named in the alert.

```sql
SELECT c.oid::regclass AS tbl, c.reloptions
FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't') AND c.reloptions::text ~ 'autovacuum_enabled=(false|off|0)'
ORDER BY 1;
```

The same condition as the disabled count of `packs/postgresql/queries-slow.yaml` (which reads the user tables of `pg_stat_user_tables`; this query also lists TOAST tables, whose parameters are set through `toast.autovacuum_enabled`). `ALTER TABLE ... RESET (autovacuum_enabled)` undoes it.

Seen in the lab:

- slice1: `autovacuum-off` (suite `none yet`)

## PostgresCheckpointsRequested

More than 3 requested checkpoints in 5 minutes on a primary. Usually WAL reached `max_wal_size` before `checkpoint_timeout`, but `CHECKPOINT`, `CREATE DATABASE`, base backups, promotion and shutdown also request one (the scenario pauses pgBackRest backups for that reason). Reference: [PostgresCheckpointsRequested](../reference/postgresql-pack-alerts.md#postgrescheckpointsrequested).

Look first: On the primary.

```sql
SELECT num_requested FROM pg_stat_checkpointer;
SHOW max_wal_size;
```

First statement from `requested()` in `lab/slice1/scenarios/checkpoint-pressure.sh`. Assumption: `pg_stat_checkpointer` exists from PostgreSQL 17; slice1 runs 19, the other labs 18.

Seen in the lab:

- slice1: `checkpoint-pressure` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresPhysicalSlotInactive

A physical replication slot has had no consumer for more than its limit (900 s unless the lab sets `obenhub.postgresql.physical_slot_inactive_age.limit`) and keeps WAL. Reference: [PostgresPhysicalSlotInactive](../reference/postgresql-pack-alerts.md#postgresphysicalslotinactive).

Look first: On the primary, the slot query (see the top of this page).

Seen in the lab:

- k8s: `fenced`, `replica-cut`, `slot-retaining-wal` (suite `k8s-20261118T194429Z-37e22f2`)
- pgha: `network-partition-replica`, `synchronous-standby-cut` (suite `pgha-20261118T225346Z-e47dc14`)
- slice1: `physical-slot-inactive`, `slot-retaining-wal`, `standby-stopped` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresReplicationSlotInvalidated

A replication slot is invalidated and no longer retains WAL; the consumer that depended on it has to be rebuilt. Reference: [PostgresReplicationSlotInvalidated](../reference/postgresql-pack-alerts.md#postgresreplicationslotinvalidated).

Look first: On the primary, the slot query (see the top of this page); `wal_status` and `invalidation_reason` say why.

Seen in the lab:

- slice1: `slot-invalidated` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresReplicationSlotRetainingWAL

A valid slot holds back more than its limit of WAL (8 GiB unless the lab sets `obenhub.postgresql.slot_retained_wal.limit`), so the WAL volume is filling. Reference: [PostgresReplicationSlotRetainingWAL](../reference/postgresql-pack-alerts.md#postgresreplicationslotretainingwal).

Look first: On the primary, the slot query (see the top of this page); `retained_wal` is the value the alert reads.

Seen in the lab:

- k8s: `slot-retaining-wal` (suite `k8s-20261118T194429Z-37e22f2`)
- slice1: `slot-retaining-wal` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresArchivingFailing

The `archive_command` ran and failed, and the last failure is newer than the last success. Reference: [PostgresArchivingFailing](../reference/postgresql-pack-alerts.md#postgresarchivingfailing).

Look first: On the primary.

```sql
SELECT * FROM pg_stat_archiver;
```

The view of the archiver query of `packs/postgresql/queries.yaml`; compare `last_failed_time` with `last_archived_time`.

Seen in the lab:

- slice1: `archiver-failing` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresArchiveBacklog

More WAL segments than the limit (64 unless the lab sets `obenhub.postgresql.archive_ready_files.limit`) wait for the archiver, so they stay in `pg_wal` and can fill the disk. Reference: [PostgresArchiveBacklog](../reference/postgresql-pack-alerts.md#postgresarchivebacklog).

Look first: On the primary.

```sql
SELECT count(*) AS ready_files FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready';
SELECT * FROM pg_stat_archiver;
```

The archiver query of `packs/postgresql/queries.yaml`, the `ready_files` subquery first.

Seen in the lab:

- slice1: `archiver-failing` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresSeriesVanished

A metric of the pack that existed during the last hour is gone on an instance whose heartbeat is still present; the metric name is in the alert. Reference: [PostgresSeriesVanished](../reference/postgresql-pack-alerts.md#postgresseriesvanished).

Look first: Errors of the monitoring role in the PostgreSQL log.

```logsql
service.name:=postgresql user:=otel_monitor error_severity:in(ERROR,FATAL,PANIC) _time:>$T_START | sort by (_time desc) | limit 20 | fields _time,_msg
```

Form from `lab/slice1/scenarios/control.sh` (the k8s lab names the field `user_name`, `lab/k8s/scenarios/control.sh`) and `lab/pgha/scenarios/leader-killed.sh` (sort, limit, fields); run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`. `$T_START` is an RFC 3339 time.

Seen in the lab:

- slice1: `permission-revoked` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresLogicalApplyErrors

A logical subscription raised its apply or sync error counter by 2 or more within 3 minutes: the apply worker keeps failing on a change. Reference: [PostgresLogicalApplyErrors](../reference/postgresql-pack-alerts.md#postgreslogicalapplyerrors).

Look first: On the subscriber.

```sql
SELECT * FROM pg_stat_subscription_stats;
```

The subscription query of `packs/postgresql/queries.yaml` (its sync error count is `sync_error_count` below 19 and `sync_table_error_count` plus `sync_seq_error_count` from 19); the `confl_*` columns of the same view are the conflict counters of the query after it.

Seen in the lab:

- slice1: `logical-conflict` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresLogicalSubscriptionNotStreaming

An enabled subscription has no apply worker, or no message for over its limit (300 s unless the lab sets `obenhub.postgresql.subscription_msg_age.limit`), without errors that `PostgresLogicalApplyErrors` would own. Reference: [PostgresLogicalSubscriptionNotStreaming](../reference/postgresql-pack-alerts.md#postgreslogicalsubscriptionnotstreaming).

Look first: On the subscriber.

```sql
SELECT s.subname, s.subenabled, a.worker_type, a.pid, a.last_msg_receipt_time
FROM pg_subscription s LEFT JOIN pg_stat_subscription a ON a.subid = s.oid;
```

The subscription query of `packs/postgresql/queries.yaml`, columns unaggregated.

Seen in the lab:

- slice1: `logical-cut` (suite `slice1-20261118T134118Z-37e22f2`)

## PostgresLogicalSlotStalled

A logical slot on the publisher has been inactive for over its limit (900 s unless the lab sets `obenhub.postgresql.logical_slot_inactive_age.limit`), or has more WAL unconfirmed than its limit (4 GiB unless the lab sets `obenhub.postgresql.logical_slot_unconfirmed_wal.limit`). Reference: [PostgresLogicalSlotStalled](../reference/postgresql-pack-alerts.md#postgreslogicalslotstalled).

Look first: On the publisher.

```sql
SELECT slot_name, active, inactive_since, confirmed_flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS unconfirmed_wal
FROM pg_replication_slots WHERE slot_type = 'logical';
```

The slot query of `packs/postgresql/queries.yaml` (`unconfirmed_wal`).

Seen in the lab:

- slice1: `subscription-disabled` (suite `slice1-20261118T134118Z-37e22f2`)
