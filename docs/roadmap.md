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

- [ ] PostgreSQL 18 primary plus physical standby
- [ ] Collector
- [ ] Reference backend
- [ ] One dashboard
- [ ] A handful of unit-tested alert rules
- [ ] Three fault scenarios plus a no-fault control
- [ ] Measured collector overhead

## Upstream PR candidates

See [ADR 0003](adr/0003-receiver-strategy.md), decision 3. Each candidate is
checked against existing upstream issues before work starts.
