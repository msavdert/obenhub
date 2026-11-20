# Oracle Data Guard pack

`queries.yaml` is the `sql_query` list read on both databases of a Data
Guard pair through a `SYSDG` connection (ADR 0008 decisions 4 and 5). The
metric list is generated:
[docs/reference/oracledb-dg-pack-metrics.md](../../docs/reference/oracledb-dg-pack-metrics.md).
Names follow [ADR 0006](../../docs/adr/0006-naming-contract.md) under the
receiver's namespace `oracledb.*`; `scripts/check-pack-names.py` fails when a
name equals an `oracledbreceiver` metric (`upstream-receiver-metrics.txt`,
contrib v0.164.0).

`queries-primary.yaml` holds the queries that only the primary can answer
(the state of the `C##OBENHUB_*` and `OBENHUB_*` accounts from `DBA_USERS`, which a mounted
standby does not serve). One receiver that connects to the primary only reads
it (`sql_query/primary_account`, `lab/oracle/files/otelcol-obs.yaml`).

## Oracle version

Tested on 19.33 only (the `CDB19` pair, 2026-11-13), as SQL*Plus statements
and through the Collector. Not run on 26ai. That the managed recovery process
disappears when apply is stopped was observed in the apply-stopped trial runs
of 2026-11-14 (`lab/oracle/results/runs.jsonl`).

## Dashboard

`dashboards/oracle-dg.json` (uid `obenhub-oracle-dg`) shows the pack's metrics
and the firing alerts; `lab/oracle/mon` mounts it into Grafana.

## Alert rules

`rules.yml` holds 20 rules, 18 alert names (group `oracledb-dg`; `OracleProcessesSaturation` and `OracleTablespaceUsageHigh` have a warning and a critical tier, as `PostgresConnectionSaturation`), unit-tested in `tests/`
(`mise run lab:oracle:rules-test`). Each rule comment names the lab/oracle
scenario that exercised it, or says that none has; the lab values of the
thresholds are recorded by the lab, the defaults are in the rules.
`OracleTargetAbsent` reads `obenhub.expected_target` from the lab's
inventory (`lab/oracle/mon/vmalert/inventory.yml`).

`OracleListenerUnreachable` reads `tcpcheck.status` from the `tcpcheck`
receiver (alpha, contrib v0.164.0), configured in
`lab/oracle/files/otelcol-obs.yaml`, not from this pack's queries. It is a TCP
connect only; ADR 0008 decision 7 records that no login is probed per check.

`OracleMonitoringAccountNotOpen` reads `oracledb.user.open` from
`queries-primary.yaml`: the receivers hold pooled sessions, so an expired
account is not seen by them while the pool lives (scenario `password-expired`).

`OracleProcessesSaturation` reads `oracledb.processes.usage` and `oracledb.processes.limit` of the `oracledb` receiver (30 s), which keeps working at the limit through its pooled session while new logins fail (scenario `processes-exhausted`).

`OracleTablespaceUsageHigh` reads `oracledb.tablespace_size.usage` and `oracledb.tablespace_size.limit` of the `oracledb` receiver (30 s), enabled by default upstream; the limit is the size a tablespace can grow to with autoextend. The lab Collector adds `oracle.db.pdb` to both metrics, otherwise a tablespace of the root and of a PDB with the same name are averaged into one series (scenario `tablespace-full`).

`OracleBlockedSessions` reads `oracledb.lock.oldest_wait_age` from `queries-primary.yaml`, the longest wait of a session for a lock held by another session (`V$SESSION`, wait class Application, read at the CDB root); oracledbreceiver has no metric for it (`metadata.yaml` at contrib v0.164.0). One warning tier, lab threshold 30 s (scenario `blocking-session`).

## Collection interval

The rules assume the `sql_query` receivers at 15 s (`lab/oracle/files/otelcol-obs.yaml`):
the `[30s]` latest-value windows and the `[45s:15s]` subquery hold at least
two collections. Two sources are slower and have their own windows:
the `oracledb` receiver (`OracleProcessesSaturation`, `OracleTablespaceUsageHigh`)
runs at 30 s and reads `[90s:30s]`, three collections; the RMAN backup
queries run at 60 s and are read as instant values
([packs/oracledb-backup](../oracledb-backup/README.md)). A window holds at least two
collections of its own source. `OracleCollectionIntervalTooLong` fires when
the samples of `oracledb.collection.heartbeat` (the 15 s `sql_query`
receiver) are on average more than 20 s apart.

## Thresholds

Every policy threshold is a production default in the rule that a lab can override with a recorded series; the series, defaults and units are in the generated table [oracledb-dg-pack-alerts.md#thresholds](../../docs/reference/oracledb-dg-pack-alerts.md#thresholds).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-oracledb-dg*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/oracledb-dg/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

One database per Collector process; the alert log is read on the database VM, the other receivers may run elsewhere.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_ORACLE_ALERT_LOG` | absolute path of the instance alert log | `/u01/app/oracle/diag/rdbms/cdb19/CDB19/trace/alert_CDB19.log` |
| `OBENHUB_ORACLE_DB_UNIQUE_NAME` | db_unique_name; service.instance.id | `CDB19` |
| `OBENHUB_ORACLE_DG_PASSWORD` | its password |  |
| `OBENHUB_ORACLE_DG_USER` | account of the sql_query receivers, percent-encoded for the URL | `C%23%23OBENHUB_DG` |
| `OBENHUB_ORACLE_HOST` | listener host; also server.address | `ora-au-lab.lab.local` |
| `OBENHUB_ORACLE_MON_PASSWORD` | its password |  |
| `OBENHUB_ORACLE_MON_USER` | account of the oracledb receiver | `C##OBENHUB_MON` |
| `OBENHUB_ORACLE_PORT` | listener port; also server.port | `1521` |
| `OBENHUB_ORACLE_SERVICE` | service name the receivers connect to | `CDB19` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
