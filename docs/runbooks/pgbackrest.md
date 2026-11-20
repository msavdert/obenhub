# pgBackRest pack runbook

One section for each alert of `packs/pgbackrest/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/pgbackrest-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## PgBackRestBackupStale

The last completed backup of a stanza is older than the tolerated age (26 h by default). Reference: [PgBackRestBackupStale](../reference/pgbackrest-pack-alerts.md#pgbackrestbackupstale).

Look first: As the postgres user where pgBackRest runs.

```bash
pgbackrest --stanza=slice1 info
```

From `pgbr` in `lab/slice1/scenarios/lib.sh` (the stanza is the lab's; `--output=json` there is for the harness).

Seen in the lab:

- slice1: `backup-stale` (suite `slice1-20261118T134118Z-37e22f2`)

## PgBackRestBackupChecksumError

The last backup found pages whose checksum does not match; the backup still completes, so the stale alert stays silent. Reference: [PgBackRestBackupChecksumError](../reference/pgbackrest-pack-alerts.md#pgbackrestbackupchecksumerror).

Look first: pgBackRest info and the backup log.

```bash
pgbackrest --stanza=slice1 info
grep 'invalid page checksum found' /var/log/pgbackrest/slice1-backup.log
```

`pgbr` in `lab/slice1/scenarios/lib.sh`; the log path and message from `lab/slice1/scenarios/backup-checksum-error.sh`.

Seen in the lab:

- slice1: `backup-checksum-error` (suite `slice1-20261118T134118Z-37e22f2`)
