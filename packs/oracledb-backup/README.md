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

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-oracledb-backup*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/oracledb-backup/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

The same connection variables as the oracledb-dg fragment.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_ORACLE_DB_UNIQUE_NAME` | db_unique_name; service.instance.id | `CDB19` |
| `OBENHUB_ORACLE_DG_PASSWORD` | its password |  |
| `OBENHUB_ORACLE_DG_USER` | account of the sql_query receivers, percent-encoded for the URL | `C%23%23OBENHUB_DG` |
| `OBENHUB_ORACLE_HOST` | listener host; also server.address | `ora-au-lab.lab.local` |
| `OBENHUB_ORACLE_PORT` | listener port; also server.port | `1521` |
| `OBENHUB_ORACLE_SERVICE` | service name the receivers connect to | `CDB19` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
