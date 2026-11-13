# Oracle Data Guard pack

`queries.yaml` is the `sql_query` list read on both databases of a Data
Guard pair through a `SYSDG` connection (ADR 0008 decisions 4 and 5). The
metric list is generated:
[docs/reference/oracledb-dg-pack-metrics.md](../../../docs/reference/oracledb-dg-pack-metrics.md).
Names follow [ADR 0006](../../../docs/adr/0006-naming-contract.md) under the
receiver's namespace `oracledb.*`; `scripts/check-pack-names.py` fails when a
name equals an `oracledbreceiver` metric (`upstream-receiver-metrics.txt`,
contrib v0.164.0).

## Oracle version

Tested on 19.33 only (the `CDB19` pair, 2026-11-13), as SQL*Plus statements
and through the Collector. Not run on 26ai. That the managed recovery process
disappears when apply is stopped is expected, not yet observed; the
apply-stopped scenario is meant to confirm it.

There are no alert rules yet.
