# Oracle backup pack runbook

One section for each alert of `packs/oracledb-backup/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/oracledb-backup-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## OracleBackupStale

The newest completed RMAN job of a kind (database or archivelog) is older than the tolerated age (26 h by default). Reference: [OracleBackupStale](../reference/oracledb-backup-pack-alerts.md#oraclebackupstale).

Look first: On the primary.

```sql
SELECT session_key, input_type, status, start_time, end_time
FROM v$rman_backup_job_details
ORDER BY start_time DESC FETCH FIRST 10 ROWS ONLY;
```

The `oracledb.backup.*` queries of `packs/oracledb-backup/queries.yaml`, listing jobs instead of one row per kind. `COMPLETED` and `COMPLETED WITH WARNINGS` count as completed there.

Seen in the lab:

- oracle: `backup-stale` (run started `2026-11-15T07:15:34.145Z`, no suite)

## OracleBackupFailed

The most recent finished RMAN job of a kind failed and no later job of that kind has succeeded. Reference: [OracleBackupFailed](../reference/oracledb-backup-pack-alerts.md#oraclebackupfailed).

Look first: On the primary.

```sql
SELECT session_key, input_type, status, start_time, end_time
FROM v$rman_backup_job_details
ORDER BY start_time DESC FETCH FIRST 10 ROWS ONLY;
```

The `oracledb.backup.*` queries of `packs/oracledb-backup/queries.yaml`, listing jobs instead of one row per kind. A status `FAILED` or `COMPLETED WITH ERRORS` on the newest row is the alert's condition.

Seen in the lab:

- oracle: `backup-failed` (suite `oracle-20261119T153131Z-4ac9423`)
