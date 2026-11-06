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
- [ ] Collector overhead on pg-lab: alternating runs with and without the
      Collector, latency percentiles, cgroup CPU of PostgreSQL and Collector

The scenarios and the control run with `mise run lab:scenarios`; their
results are in `lab/slice1/results/runs.jsonl`.

Deferred until after the slice: see ADR 0002 decisions 1 and 2 and ADR 0003
decision 2.

## Upstream PR candidates

See [ADR 0003](adr/0003-receiver-strategy.md), decision 3. Each candidate is
checked against existing upstream issues before work starts.
