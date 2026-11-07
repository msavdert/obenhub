# Roadmap

The only place for plans. Scope and order are decided in
[ADR 0001](adr/0001-goal-and-scope.md).

## Stages

1. Single instance and physical streaming standby (next: the first vertical
   slice below)
2. Logical replication and PgBouncer
3. Patroni cluster
4. Kubernetes operator (CloudNativePG first)
5. Cloud-managed PostgreSQL

A stage is done when its fault scenarios fire the expected alerts and show on
the dashboards, with a no-fault control run.

## First vertical slice

Docker Compose in `lab/slice1`, versions pinned in its `compose.yaml`.

- [x] PostgreSQL 18 primary plus physical standby, replication on its own
      network so a replication cut does not also cut monitoring
- [x] One `otelcol-contrib` Collector: `postgresqlreceiver`, a hand-written
      PostgreSQL 18 `sqlqueryreceiver` pack (recovery state, WAL receiver,
      received-minus-replayed bytes, oldest snapshot age, heartbeat), and an
      expected-target inventory for the heartbeat to be checked against,
      `filelog` on `jsonlog`
- [x] VictoriaMetrics and VictoriaLogs; vmalert and Alertmanager with a
      webhook sink that proves delivery
- [x] Alert rules with `vmalert-tool unittest` tests, each fired by one
      fault scenario:
      - target telemetry absent: standby container stopped
      - Collector absent: Collector stopped
      - standby not streaming: replication network cut
      - replay backlog: replay paused under load
      - snapshot held too long: repeatable-read transaction left open
      - connection saturation: client connections exhausted, with
        `reserved_connections` set and `pg_use_reserved_connections` granted
        to the monitoring role so it can still connect
      - a series that was present vanished: one pack query broken on purpose
- [x] Watchdog: an always-firing alert that the webhook sink must keep
      receiving
- [x] No-fault control: no alert except the watchdog, and zero
      monitoring-role errors in the server log
- [x] One Grafana dashboard as code
- [x] Collector overhead on pg-lab: alternating runs with and without the
      Collector, latency percentiles, cgroup CPU of PostgreSQL and Collector
      (`lab/overhead`, results in `lab/overhead/results/results.md`)

The scenarios and the control run with `mise run lab:scenarios`; their
results are in `lab/slice1/results/runs.jsonl`.

Deferred until after the slice: see ADR 0002 decisions 1 and 2 and ADR 0003
decision 2.

## Stage 2: logical replication and PgBouncer

Extends `lab/slice1` in place (same Compose project, harness and
`mise run lab:scenarios`).

- [x] Logical subscriber `pg-subscriber` (PostgreSQL 18, database `app`,
      subscription `app_sub`) on its own `logical` network, so cutting
      logical replication does not cut the physical standby or monitoring
- [x] Pack queries for replication slots on every node and for
      subscriptions on the subscriber (`pg_replication_slots`,
      `pg_subscription`, `pg_stat_subscription`,
      `pg_stat_subscription_stats`); `postgresqlreceiver` v0.164.0 has none
      of these
- [x] Alert rules with unit tests, each fired by one fault scenario except
      the last:
      - apply errors: an `insert_exists` conflict
      - subscription enabled but not streaming: the `logical` network cut
      - logical slot retaining WAL: subscription disabled while the
        publisher writes
      - slot invalidated: unit test only, no scenario (see the rule)
- [x] Dashboard panels for slots, subscription state and error counters
- [x] No-fault control with the subscriber included
- [x] PgBouncer 1.26.1 (CloudNativePG image) in front of database `app`,
      transaction pooling, `default_pool_size` 5. It has no metrics endpoint
      (pgbouncer#1354), so `sqlqueryreceiver` queries the admin console
      (`SHOW POOLS`, `SHOW DATABASES`, `SHOW LISTS`); no exporter needed
- [x] PgBouncer is an expected target; its heartbeat is the `SHOW LISTS` row
      `databases`
- [x] Alert rule with unit tests, each fired by one fault scenario:
      - clients waiting for a server connection: more open transactions
        than the pool size
      - PgBouncer absent: the container stopped
- [x] Dashboard panels for pool clients, server connections and wait time

## Upstream PR candidates

See [ADR 0003](adr/0003-receiver-strategy.md), decision 3. Each candidate is
checked against existing upstream issues before work starts.

## After the PgBouncer step: OpenTelemetry eBPF Instrumentation (OBI)

One experiment between stage 2 and stage 3; it does not displace stage 3.
The question is whether OBI adds client-side database latency to what the
receivers report. Its docs
([opentelemetry.io/docs/zero-code/obi](https://opentelemetry.io/docs/zero-code/obi/),
read 2026-11-07) list PostgreSQL among the protocols it observes, and its
[metrics page](https://opentelemetry.io/docs/zero-code/obi/metrics/) lists
`db.client.operation.duration`; release
[v1.0.0](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/releases/tag/v1.0.0)
(2026-10-30) is its first stable one. What it reports in this lab is
unconfirmed.

- [x] Licence: as a separate, unmodified process in the lab, OBI falls
      under ADR 0004 decision 3 and passes it. At v1.0.0 `LICENSE` is
      Apache-2.0 and the BPF sources carry Apache-2.0 SPDX headers, but the
      programs declare `"Dual MIT/GPL"` (`bpf/generictracer/generictracer.c`)
      or `"GPL"` (`bpf/netolly/flows.c`) to the kernel, and `bpf/bpfcore/`
      vendors libbpf headers (LGPL-2.1 OR BSD-2-Clause). Building OBI into
      the project's own Collector distribution would fall under decision 2
      and needs its own decision first
- [x] OBI v1.0.0 on the `pg-lab` VM, not on the shared Docker host: OBI
      sees every process on its kernel, and the VM runs no other workload
      (an idle source-built PostgreSQL on port 5433 is excluded by path). It
      exports OTLP metrics to a Collector; the question is what it reports
      for pgbench through PgBouncer and directly against PostgreSQL
      (simple, extended and prepared protocol), next to pgbench's own
      latency
- [x] Only if the signal is worth keeping: add VictoriaTraces (ADR 0002)
      to the lab and a traces pipeline. Decided 2026-11-07: not now. The
      per-statement client latency is accurate and splits the PgBouncer
      hops, but OBI misses `BEGIN` and the commit (`END`), statements
      prepared before it attaches, and most server-side calls over TLS
      ([results](https://github.com/msavdert/obenhub/blob/main/lab/obi/results/results.md)).
      It stays out of the reference stack until those gaps close upstream
