# lab

What runs today. Every lab sends telemetry through OpenTelemetry Collectors to
its own VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager and Grafana
backend, and has fault scenarios that inject a failure, wait for the expected
alert to fire and resolve, and fail on any unexpected alert. Scenario results
are appended to the lab's `results/runs.jsonl`. The `mise run` tasks below run
a lab's scenarios as a suite (`lab/scenarios/run-suite.sh`: clean tree outside
`results/`, one run at a time on the host, every record carries the `suite` id
and `detected_at`, the time each expected alert first fired); a scenario run on
its own is a smoke run and records `suite: null`. Suites run on a commit of
`main`, and their results come back through a pull request, so that the
recorded `git_sha` stays in the history. A suite refuses timing overrides
from the environment (`SUITE_TIMING_VARS` in `lab/scenarios/guard.sh`), and
counts only with `control` run last. A scenario's unexpected-alert window runs
from the end of the previous scenario of the suite (the suite start for the
first), so alerts between two scenarios count. The Compose and k8s labs fail
the pre-flight when a running image differs from the declared one and record
what runs as `running_images`. `control` also sends a synthetic alert that must
come back from VictoriaLogs as firing and resolved, and needs database log
records in its window. A resolution is searched from the alert's detection, so
`seconds_to_resolve` (still from the revert) can be negative
(`resolved_before_revert`). `mise run lab:harness-test` tests this without a
lab. `mise run lab:evidence` reports, per
lab, whether its latest full suite plus the later targeted suites (subsets of
`suite.txt`) cover the code: `scripts/affected-scenarios.sh` maps each change
to the scenarios it can affect (its header is the reference for the mapping; a
Grafana change prints a `panels` line to run `mise run lab:<lab>:panels`), and
`mise run lab:affected <lab>` lists them
(`mise run lab:scenarios:affected` and `lab:<lab>:scenarios:affected` run
them). `scripts/check-evidence.sh --full` counts only a full suite with no change
that affects the lab since, as a release and the end of a dependency update
batch require. In both modes a scenario that failed in a suite after the
counted one keeps the lab stale until it passes again, and `lab:affected` lists
it.

| Lab | Topology | Where it runs | Scenarios | Evidence |
| --- | --- | --- | --- | --- |
| [slice1](slice1) | PostgreSQL 19 primary, standby, logical subscriber, PgBouncer; one Collector | Docker Compose on the host | `mise run lab:scenarios` | [results](slice1/results) |
| [stage3](stage3) | Three etcd members and three PostgreSQL 18 nodes under Patroni; one Collector | Docker Compose on the host | `mise run lab:stage3:scenarios` | [results](stage3/results) |
| [pgha](pgha) | The same Patroni cluster on three Debian VMs; a Collector per node and a gateway | Three VMs plus Compose backend on the host | `mise run lab:pgha:scenarios` | [results](pgha/results) |
| [k8s](k8s) | CloudNativePG `Cluster` of three PostgreSQL 18 instances on kind; Collector DaemonSet and Deployment | kind on the host | `mise run lab:k8s:scenarios` | [results](k8s/results) |
| [oracle](oracle) | Oracle 19.33 Data Guard pair `CDB19` with fast-start failover and RMAN backups; a Collector per VM and a gateway | Three Oracle VMs, databases not built from this repository, plus Compose backend on the host | `mise run lab:oracle:scenarios` | [results](oracle/results) |

Shared parts:

- [packs](../packs): queries and alert rules with unit tests, one directory per
  component (postgresql, patroni, etcd, cnpg, pgbackrest, host, k8s,
  collector, oracledb-dg, oracledb-backup).
- [scenarios/lib-core.sh](scenarios/lib-core.sh): the scenario harness used by
  slice1, stage3, pgha, k8s and oracle.
- [scenarios/patroni](scenarios/patroni): the Patroni scenarios stage3 and pgha
  share; each lab links them from its `scenarios/` and supplies the adapter
  functions in its `lib.sh` (`etcd_stop`, `etcd_start`, `ptl`, ...).
- [mon](mon): `compose.base.yaml`, the VictoriaMetrics, VictoriaLogs, vmalert,
  Alertmanager and Grafana services every lab extends, with the shared
  Alertmanager config and Grafana provisioning.

One-off measurements on the `pg-lab` VM, not scenario labs:

- [overhead](overhead): Collector CPU and memory next to pgbench (TPC-B and CPU-saturated arms, per-query pack cost)
  ([results](overhead/results/results.md)).
- [obi](obi): OpenTelemetry eBPF Instrumentation against PostgreSQL and
  PgBouncer; not adopted ([results](obi/results/results.md)).

Backups are in slice1 only: pgBackRest with a point-in-time restore and
the `pg_basebackup` comparison ([ADR 0007](../docs/adr/0007-backup-tool.md)).
Synchronous replication is covered by pgha (`synchronous-standby-cut`).
