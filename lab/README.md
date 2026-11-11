# lab

What runs today. Every lab sends telemetry through OpenTelemetry Collectors to
its own VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager and Grafana
backend, and has fault scenarios that inject a failure, wait for the expected
alert to fire and resolve, and fail on any unexpected alert. Scenario results
are appended to the lab's `results/runs.jsonl`.

| Lab | Topology | Where it runs | Scenarios | Evidence |
| --- | --- | --- | --- | --- |
| [slice1](slice1) | PostgreSQL 18 primary, standby, logical subscriber, PgBouncer; one Collector | Docker Compose on the host | `mise run lab:scenarios` | [results](slice1/results) |
| [stage3](stage3) | Three etcd members and three PostgreSQL 18 nodes under Patroni; one Collector | Docker Compose on the host | `mise run lab:stage3:scenarios` | [results](stage3/results) |
| [pgha](pgha) | The same Patroni cluster on three Debian VMs; a Collector per node and a gateway | Three VMs plus Compose backend on the host | `mise run lab:pgha:scenarios` | [results](pgha/results) |
| [k8s](k8s) | CloudNativePG `Cluster` of three PostgreSQL 18 instances on kind; Collector DaemonSet and Deployment | kind on the host | `lab/k8s/scenarios/<name>.sh` | [results](k8s/results) |

Shared parts:

- [packs](packs): queries and alert rules with unit tests, one directory per
  component (postgresql, patroni, etcd, cnpg, host, k8s).
- [scenarios/lib-core.sh](scenarios/lib-core.sh): the scenario harness used by
  stage3, pgha and k8s.

One-off measurements on the `pg-lab` VM, not scenario labs:

- [overhead](overhead): Collector CPU and memory next to pgbench
  ([results](overhead/results/results.md)).
- [obi](obi): OpenTelemetry eBPF Instrumentation against PostgreSQL and
  PgBouncer; not adopted ([results](obi/results/results.md)).

Not covered yet: WAL archiving, backups, synchronous replication.
