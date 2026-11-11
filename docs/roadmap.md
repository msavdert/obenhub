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

PostgreSQL counts as done for ADR 0001 when stages 1 to 4 are done; the
Oracle phase starts then. Stage 5 applies the same pack to managed services
rather than adding a topology, so it runs later, when it is fully prepared
(owner decision, 2026-11-08).

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
- [x] Alert rules with unit tests, each fired by one fault scenario:
      - apply errors: an `insert_exists` conflict
      - subscription enabled but not streaming: the `logical` network cut
      - logical slot retaining WAL: subscription disabled while the
        publisher writes
      - slot invalidated: a physical slot pushed past `max_slot_wal_keep_size`,
        then a checkpoint (`slot-invalidated`)
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

## Stage 3: Patroni cluster

A separate Compose project in `lab/stage3` (`obenhub-stage3`) with its own
backend, so the stage 2 lab keeps running and its suite stays unchanged.
Versions read 2026-11-07: Patroni 4.1.5 (MIT; PostgreSQL 18 support since
4.0.7), PGDG package `4.1.5-2.pgdg13+1` available in `postgres:18.6-trixie`,
etcd 3.6.16 (Apache-2.0).

- [x] Three etcd members and three PostgreSQL 18 nodes under Patroni, image
      built from `postgres:18.6-trixie` plus the PGDG `patroni` package,
      `etcd3` DCS, defaults for `ttl`, `loop_wait` and `failsafe_mode`
- [x] No HAProxy: clients reach the leader through libpq multi-host
      connection strings with `target_session_attrs=read-write`
- [x] Collector: the stage 2 PostgreSQL pack on every node, named by node
      and never by role, plus `prometheusreceiver` on each node's Patroni
      `/metrics` (contrib has no Patroni receiver)
- [x] Alert rules with unit tests, each fired by one fault scenario:
      - no writable primary: two etcd members stopped (quorum lost, the
        leader demotes itself)
      - failover happened: the leader container killed; the rule fires once
        on the timeline change and the cluster recovers without help
      - replica not eligible for failover: one replica cut from the
        replication network while the leader writes past
        `maximum_lag_on_failover`. Paused replay does not work: Patroni
        4.1.5 measures lag from the received position, and resumes paused
        replay unless the cluster is paused
      - replay backlog: replay paused on a replica of a paused cluster
      - cluster left paused: maintenance mode on for longer than the window
      - pending restart: a parameter that needs a restart changed through
        `patronictl edit-config`
- [x] Planned switchover: no alert except the failover rule. The rule
      cannot tell planned from unplanned: both raise the timeline by one
- [x] Dashboard: role per node over time, timeline, DCS last seen, lag per
      replica
- [x] No-fault control
- [x] One PostgreSQL pack shared by both labs instead of two copies
      (`lab/packs/postgresql`). Stage 3 thereby also runs SnapshotHeldTooLong,
      ConnectionSaturation and SeriesVanished; their fault scenarios are in
      slice1
- [x] Each stage 3 scenario reloads vmalert and Alertmanager first, checks the
      vmalert reload counters, and records the hash of the rule and
      Alertmanager files as the containers read them; a mismatch with the
      repository files fails the run (as `reload_config` in slice1)

The scenarios and the control run with `mise run lab:stage3:scenarios`; their
results are in `lab/stage3/results/runs.jsonl` (the last eleven records are the
suite run of 2026-11-09 with the configuration reload, each with the
`config_sha256` the containers read; older records predate it, two of them on
an earlier draft of the pack, and include two `leader-killed` failures before
`wal_keep_size` was raised).

Coverage gaps found on 2026-11-07 by comparing both labs with existing rule
sets: the catalog survey in the private predecessor repository (pgMonitor,
postgres_exporter, pganalyze, PMM, Datadog and others, read at pinned commits;
not checkable from here) and, for
PgBouncer, Patroni and etcd, pigsty v4.5.0, the etcd mixin at v3.7.3 and
awesome-prometheus-alerts. Rules are written for our metric names. Text is
copied only from Apache-2.0 sources (pigsty since v4.0.0, etcd mixin,
pgMonitor), with provenance. AGPL sources (PMM, Zabbix, per that survey) and
awesome-prometheus-alerts (CC BY 4.0, not in ADR 0004's list) give ideas
only. Each item gets a fault scenario where one can be built in the lab,
otherwise unit tests only, said so in the rule:

- [x] etcd: scrape every member's `/metrics`; alerts for member down, no
      leader, lost quorum, frequent leader changes, slow WAL fsync and slow
      backend commit. Scenarios: one member stopped, leadership moved four
      times with `etcdctl move-leader`, and quorum lost (now expecting the
      etcd alerts as well). The two disk-latency rules have unit tests only;
      injecting disk latency into one container (for example a cgroup I/O
      limit) was not attempted
- [x] Patroni: its own scrape absent while PostgreSQL on that node still
      reports, and failsafe mode active. The scenario blocks the Collector's
      scrape of one node's REST API, because Patroni is the container's main
      process and stopping it stops PostgreSQL too. Failsafe has unit tests
      only, because the lab runs with failsafe mode off
- [x] PostgreSQL, in the shared pack: transaction ID wraparound age,
      idle-in-transaction separated from active long transactions, blocked
      sessions, deadlocks, checkpoint pressure from `pg_stat_checkpointer`
      (PostgreSQL 17+), and an inactive physical slot. Scenarios cover idle in
      transaction, a lock wait, a deadlock, checkpoint pressure and an unused
      physical slot; wraparound has unit tests only, because the lab cannot
      reach those ages (its metric is present in both labs)
- [x] Two tiers (warning and critical) for capacity signals: connections,
      wraparound age, idle in transaction. One alertname with two severities
      and one tier per series; the connections and idle-in-transaction
      scenarios assert the critical tier
- [x] PgBouncer: pool saturation (average use of `pool_size` over 5 m),
      `max_client_conn` exhaustion in two tiers, and the average wait per
      server assignment from `SHOW STATS`; no alert on query time, which
      includes the wait. Scenarios: short transactions queueing without
      `PgbouncerClientsWaiting`, and `max_client_conn` filled so that the next
      client is refused while no client waits (`cl_waiting` 0, `maxwait` 0)

Then the same cluster on three VMs, because the operating-system layer
(ADR 0001, primary goal) cannot be observed per node in Compose:

- [x] Three Debian 13 VMs, each with etcd, Patroni, PostgreSQL 18 and one
      Collector, installed by scripts in the repository (`lab/pgha`)
- [x] `hostmetricsreceiver` and journald logs per node, pushed through a
      gateway Collector to a backend on the lab host; the stage 3 Patroni,
      etcd and PostgreSQL rules run unchanged as shared packs
- [x] `CollectorAbsent` per Collector: each lab's inventory lists its
      Collectors (`obenhub.expected_collector`) and tags every target with the
      Collector that collects it; one stopped node Collector raises only its
      own alert, and a stopped gateway only the gateway's (unit-tested in
      `lab/pgha/mon/vmalert/tests/collectors.yml`)
- [x] The stage 3 fault scenarios carried over to the VMs where they apply
      (`lab/pgha/scenarios`, results in `lab/pgha/results/runs.jsonl`);
      `leader-killed` is not carried over, it moves to the OS fault item below
- [x] OS fault scenarios with alerts: filesystem filling, memory pressure,
      a real network partition between nodes, and the leader killed (the
      stage 3 `leader-killed` scenario, moved here by owner decision
      2026-11-10; on the VMs Patroni is frozen and the watchdog resets the
      leader)

## Stage 4: CloudNativePG on kind

A kind cluster on the lab host with its own backend Compose project
(`obenhub-k8s`), so the pgha lab keeps running. The operating-system faults
stay on the pgha VMs: kind nodes share the host kernel. Versions read
2026-11-10, unconfirmed until a run: CloudNativePG 1.30.1 (Apache-2.0;
Kubernetes 1.34 to 1.36, PostgreSQL 14 to 18), kind 0.33.0 with
`kindest/node:v1.36.4` (1.37 is outside CloudNativePG's matrix), Collector
contrib 0.165.1.

- [x] kind cluster (one control plane, three workers), the CloudNativePG
      operator from its release manifest, one `Cluster` of three
      PostgreSQL 18 instances, one per worker (`lab/k8s`)
- [x] Collector as a DaemonSet: the PostgreSQL pack against every instance
      pod (`receivercreator`, named by pod and never by role),
      `kubeletstats`, and container logs with the PostgreSQL `record` of
      CloudNativePG's JSON log parsed; one Deployment for `k8scluster` and
      Kubernetes events; `k8sattributes` on all signals
- [x] CloudNativePG's exporter scraped only for operator state
      (`cnpg_collector_*`, `cnpg_last_error`) with its default queries off:
      the pack already covers PostgreSQL, as with Patroni `/metrics` in
      stage 3
- [x] Alert rules with unit tests, each fired by one fault scenario: primary
      pod deleted (failover), worker node stopped, instance fenced,
      switchover, a replica cut from the primary, and an HA replication slot
      retaining WAL; plus a no-fault control run. Event reasons are taken
      from the run (`kubectl get events`), not assumed

## Stage 5: cloud-managed PostgreSQL

Waits until the project is mature. AWS and Azure give managed PostgreSQL
hours only to new accounts for twelve months
([RDS pricing](https://aws.amazon.com/rds/postgresql/pricing/),
[Azure free services](https://azure.microsoft.com/en-us/pricing/free-services)),
OCI has no free tier for it
([billing](https://docs.oracle.com/en-us/iaas/Content/postgresql/billing.htm)),
and no free Cloud SQL tier was found (all read 2026-11-07). So each paid
provider gets one session of a few hours:

- [ ] One script per provider: create the service, connect the Collector,
      run the scenarios that apply to a managed service and the control,
      keep the evidence, delete everything. A budget alert is set before
      the first paid hour
- [ ] The script rehearsed first on free services: Aiven (free plan) and
      Supabase (Free); Neon for short runs only, because its free plan has
      100 compute-hours a month and suspends after five idle minutes
      ([plans](https://neon.com/docs/introduction/plans)), so polling
      would keep it awake and use them up
- [ ] Paid, prices read again on the day: AWS RDS for PostgreSQL, Azure
      Database for PostgreSQL flexible server, Google Cloud SQL, OCI Database
      with PostgreSQL

Unconfirmed until a run: whether each provider's admin role can grant
`pg_monitor`; whether Collector polling keeps a Supabase project from being
paused and an Aiven free service from being powered off; and what changes
when the Collector has to use a pooled endpoint instead of a direct one.

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
