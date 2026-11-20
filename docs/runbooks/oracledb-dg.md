# Oracle Data Guard pack runbook

One section for each alert of `packs/oracledb-dg/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/oracledb-dg-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

Command several sections use:

```bash
dgmgrl -silent / 'show configuration'
```

Run as the oracle user on the host of the database: `dg` in `lab/oracle/scenarios/lib.sh`.

## OraclePrimaryChanged

A database reports PRIMARY after having reported another role within the last 3 minutes: a standby was promoted, by switchover or failover. Reference: [OraclePrimaryChanged](../reference/oracledb-dg-pack-alerts.md#oracleprimarychanged).

Look first: On each database of the pair.

```sql
SELECT db_unique_name, database_role, open_mode FROM v$database;
```

The role query of `packs/oracledb-dg/queries.yaml`.

Look first: Broker view, with `dgmgrl show configuration` (see the top of this page).

Seen in the lab:

- oracle: `fsfo-failover` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleProtectionDegraded

The primary's protection level is below its protection mode, so the zero-data-loss guarantee no longer holds. Reference: [OracleProtectionDegraded](../reference/oracledb-dg-pack-alerts.md#oracleprotectiondegraded).

Look first: On the primary.

```sql
SELECT protection_mode, protection_level FROM v$database;
```

The protection query of `packs/oracledb-dg/queries.yaml`.

Look first: Broker view, with `dgmgrl show configuration` (see the top of this page).

Seen in the lab:

- oracle: `transport-cut` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleFastStartFailoverObserverMissing

Fast-start failover is enabled but the primary sees no observer, so the broker cannot fail over automatically. Reference: [OracleFastStartFailoverObserverMissing](../reference/oracledb-dg-pack-alerts.md#oraclefaststartfailoverobservermissing).

Look first: On the primary.

```sql
SELECT fs_failover_status, fs_failover_observer_present FROM v$database;
```

The fast-start failover query of `packs/oracledb-dg/queries.yaml`.

Look first: Broker view, with `dgmgrl show configuration` (see the top of this page).

Seen in the lab:

- oracle: `observer-stopped` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleStandbyApplyStopped

The managed recovery process of a standby is gone: redo is received but no longer applied. Reference: [OracleStandbyApplyStopped](../reference/oracledb-dg-pack-alerts.md#oraclestandbyapplystopped).

Look first: On the standby.

```sql
SELECT * FROM v$dataguard_process WHERE role = 'managed recovery';
SELECT * FROM v$archive_gap;
```

The apply query of `packs/oracledb-dg/queries.yaml`; no row from the first statement is the alert's condition.

Seen in the lab:

- oracle: `apply-stopped` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleStandbyLag

Transport or apply lag on a standby is above 60 seconds (lab threshold). Reference: [OracleStandbyLag](../reference/oracledb-dg-pack-alerts.md#oraclestandbylag).

Look first: On the standby.

```sql
SELECT name, value, datum_time FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag');
```

The lag query of `packs/oracledb-dg/queries.yaml`, without the conversion to seconds.

Seen in the lab:

- oracle: `apply-stopped` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleStandbyDataStale

The data the standby's lag is computed from is older than 60 seconds: redo has stopped arriving even if the lag value is low. Reference: [OracleStandbyDataStale](../reference/oracledb-dg-pack-alerts.md#oraclestandbydatastale).

Look first: On the standby, then on the primary.

```sql
SELECT name, value, datum_time FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag');
SELECT dest_id, destination, status, gap_status FROM v$archive_dest_status
WHERE status <> 'INACTIVE' AND type <> 'UNKNOWN';   -- primary
```

The lag and archive-destination queries of `packs/oracledb-dg/queries.yaml`.

Seen in the lab:

- oracle: `transport-cut` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleRedoDestinationInvalid

An archive destination is not VALID: a remote one means the primary cannot ship redo, the local one means archiving stopped. Reference: [OracleRedoDestinationInvalid](../reference/oracledb-dg-pack-alerts.md#oracleredodestinationinvalid).

Look first: On the primary.

```sql
SELECT dest_id, destination, status, gap_status FROM v$archive_dest_status
WHERE status <> 'INACTIVE' AND type <> 'UNKNOWN';
SELECT dest_id, status, error FROM v$archive_dest WHERE dest_id = 1;
```

The first statement is the destination query of `packs/oracledb-dg/queries.yaml`; the second reads the error text of the local destination as `dest1` does in `lab/oracle/scenarios/archiver-stuck.sh`.

Seen in the lab:

- oracle: `archiver-stuck`, `transport-cut` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleListenerUnreachable

A TCP connect to a listener endpoint failed on every check for a minute; the tcpcheck receiver does no login and no service lookup. Reference: [OracleListenerUnreachable](../reference/oracledb-dg-pack-alerts.md#oraclelistenerunreachable).

Look first: As the oracle user on the listener's host.

```bash
lsnrctl status <listener>
```

`lsnr` in `lab/oracle/scenarios/listener-stopped.sh` (runs `lsnrctl CMD LISTENER_NAME` as the oracle user with the listener's `ORACLE_HOME` and `TNS_ADMIN`).

Seen in the lab:

- oracle: `listener-stopped` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleMonitoringAccountNotOpen

A project monitoring account (`C##OBENHUB_*`) is not OPEN: expired, in grace or locked. An expired password stops only new logins, so collection can continue until the next reconnect. Reference: [OracleMonitoringAccountNotOpen](../reference/oracledb-dg-pack-alerts.md#oraclemonitoringaccountnotopen).

Look first: On the primary.

```sql
SELECT username, account_status FROM dba_users
WHERE username LIKE 'C##OBENHUB\_%' ESCAPE '\' OR username LIKE 'OBENHUB\_%' ESCAPE '\';
```

The account query of `packs/oracledb-dg/queries-primary.yaml`.

Seen in the lab:

- oracle: `password-expired` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleProcessesSaturation

Process slots in use are above 85 % of the `PROCESSES` parameter (critical at 95 %); at the limit a new dedicated server process cannot start. Reference: [OracleProcessesSaturation](../reference/oracledb-dg-pack-alerts.md#oracleprocessessaturation).

Look first: On the primary.

```sql
SELECT current_utilization, limit_value FROM v$resource_limit WHERE resource_name = 'processes';
```

The metric comes from the stock oracledb receiver, not from a pack query; the view is named by `packs/oracledb-dg/dashboards/oracle-dg.json` and queried as `procs_state` in `lab/oracle/scenarios/processes-exhausted.sh`.

Seen in the lab:

- oracle: `processes-exhausted` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleTablespaceUsageHigh

A tablespace is above 85 % of its limit (critical at 95 %). Reference: [OracleTablespaceUsageHigh](../reference/oracledb-dg-pack-alerts.md#oracletablespaceusagehigh).

Look first: In the container named in the alert.

```sql
SELECT tablespace_name, used_space, tablespace_size FROM dba_tablespace_usage_metrics;
```

The metric comes from the stock oracledb receiver; query form from `lab/oracle/scenarios/tablespace-full.sh` (run there after `ALTER SESSION SET CONTAINER`, `in_pdb` in `lab/oracle/scenarios/lib.sh`). Sizes are in blocks there (the script joins `dba_tablespaces.block_size`).

Seen in the lab:

- oracle: `tablespace-full` (suite `oracle-20261119T153131Z-4ac9423`)

## OracleBlockedSessions

A session has waited more than 30 seconds for a lock held by another session; the alert does not name the blocker. Reference: [OracleBlockedSessions](../reference/oracledb-dg-pack-alerts.md#oracleblockedsessions).

Look first: On the primary, from the CDB root.

```sql
SELECT sid, blocking_session, wait_class, wait_time_micro / 1000000 AS waiting_s
FROM v$session
WHERE blocking_session IS NOT NULL AND state = 'WAITING' AND wait_class = 'Application';
```

The lock-wait query of `packs/oracledb-dg/queries-primary.yaml`, listing sessions instead of the maximum.

Seen in the lab:

- oracle: `blocking-session` (suite `oracle-20261119T153131Z-4ac9423`)
