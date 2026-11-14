# Oracle Data Guard pack

`queries.yaml` is the `sql_query` list read on both databases of a Data
Guard pair through a `SYSDG` connection (ADR 0008 decisions 4 and 5). The
metric list is generated:
[docs/reference/oracledb-dg-pack-metrics.md](../../../docs/reference/oracledb-dg-pack-metrics.md).
Names follow [ADR 0006](../../../docs/adr/0006-naming-contract.md) under the
receiver's namespace `oracledb.*`; `scripts/check-pack-names.py` fails when a
name equals an `oracledbreceiver` metric (`upstream-receiver-metrics.txt`,
contrib v0.164.0).

`queries-primary.yaml` holds the queries that only the primary can answer
(the state of the `C##OBENHUB_*` accounts from `DBA_USERS`, which a mounted
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

`rules.yml` holds 17 rules, 16 alert names (group `oracledb-dg`; `OracleProcessesSaturation` has a warning and a critical tier, as `PostgresConnectionSaturation`), unit-tested in `tests/`
(`mise run lab:oracle:rules-test`). Each rule comment names the lab/oracle
scenario that exercised it, or says that none has; the thresholds are lab
thresholds.
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
