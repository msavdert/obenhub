# Oracle RMAN backup pack

`queries.yaml` reads the RMAN job history and the recovery area on both
databases of a Data Guard pair; `rules.yml` holds the age, failure, missing-backup
and recovery-area alerts, unit-tested in `tests/`
(`mise run lab:oracle:rules-test`).

## Collection interval

The two `sql_query` receivers that read `queries.yaml` collect every 60 s
(`sql_query/primary_backup`, `sql_query/standby_backup` in
`lab/oracle/files/otelcol-obs.yaml`): a backup age moves in minutes. The rules
read these series as instant values, with no window shorter than the interval,
so a window holds at least two collections. `OracleBackupMissing` reads the
role from `oracledb.database.primary` of the Data Guard pack, which is
collected every 15 s, with `[1m]`. The interval check of the pair is
`OracleCollectionIntervalTooLong` in `packs/oracledb-dg`.
