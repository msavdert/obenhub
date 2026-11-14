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
disappears when apply is stopped was observed in the apply-stopped trial runs
of 2026-11-14 (`lab/oracle/results/runs.jsonl`).

## Alert rules

`rules.yml` holds 13 rules (group `oracledb-dg`), unit-tested in `tests/`
(`mise run lab:oracle:rules-test`). No lab scenario has exercised them yet;
every rule says so in its comment, and the thresholds are lab thresholds.
`OracleTargetAbsent` reads `obenhub.expected_target` from the lab's
inventory (`lab/oracle/mon/vmalert/inventory.yml`).
