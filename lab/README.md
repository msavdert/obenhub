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
recorded `git_sha` stays in the history; `mise run lab:evidence` lists the
labs whose latest complete passing suite predates their code.

| Lab | Topology | Where it runs | Scenarios | Evidence |
| --- | --- | --- | --- | --- |
| [slice1](slice1) | PostgreSQL 18 primary, standby, logical subscriber, PgBouncer; one Collector | Docker Compose on the host | `mise run lab:scenarios` | [results](slice1/results) |
| [stage3](stage3) | Three etcd members and three PostgreSQL 18 nodes under Patroni; one Collector | Docker Compose on the host | `mise run lab:stage3:scenarios` | [results](stage3/results) |
| [pgha](pgha) | The same Patroni cluster on three Debian VMs; a Collector per node and a gateway | Three VMs plus Compose backend on the host | `mise run lab:pgha:scenarios` | [results](pgha/results) |
| [k8s](k8s) | CloudNativePG `Cluster` of three PostgreSQL 18 instances on kind; Collector DaemonSet and Deployment | kind on the host | `mise run lab:k8s:scenarios` | [results](k8s/results) |

Shared parts:

- [packs](packs): queries and alert rules with unit tests, one directory per
  component (postgresql, patroni, etcd, cnpg, host, k8s).
- [scenarios/lib-core.sh](scenarios/lib-core.sh): the scenario harness used by
  slice1, stage3, pgha and k8s.
- [scenarios/patroni](scenarios/patroni): the Patroni scenarios stage3 and pgha
  share; each lab links them from its `scenarios/` and supplies the adapter
  functions in its `lib.sh` (`etcd_stop`, `etcd_start`, `ptl`, ...).
- [mon](mon): `compose.base.yaml`, the VictoriaMetrics, VictoriaLogs, vmalert,
  Alertmanager and Grafana services every lab extends, with the shared
  Alertmanager config and Grafana provisioning.

One-off measurements on the `pg-lab` VM, not scenario labs:

- [overhead](overhead): Collector CPU and memory next to pgbench
  ([results](overhead/results/results.md)).
- [obi](obi): OpenTelemetry eBPF Instrumentation against PostgreSQL and
  PgBouncer; not adopted ([results](obi/results/results.md)).

Not covered yet: backups and PITR (WAL archiving to a local directory is in
slice1, with no restore), synchronous replication. A backup tool is an open
item in the [roadmap](../docs/roadmap.md).
