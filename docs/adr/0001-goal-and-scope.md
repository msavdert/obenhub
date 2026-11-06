# ADR 0001: Goal and scope

- Status: Accepted
- Date: 2026-11-06

## Context

The owner wants to learn observability and OpenTelemetry in depth, at the
database and operating-system layer, by building a monitoring stack for their
own use and their company's. It is not a commercial product.

Existing database monitoring projects are either Prometheus-only or keep their
best features (query analysis, plans, advisors, RBAC, AI root-cause analysis)
in paid editions. The aim is one fully open-source project that collects the
best ideas of the existing PostgreSQL monitoring tools and does them on
OpenTelemetry standards.

obenhub is the fourth start on this theme, after dbsight, dbmedic and
dbwitness, all private repositories. dbsight grew to seven engines, 74
commits and about 63k lines (47% Markdown) without one end-to-end result. A
"depth before breadth" rule was written there and not followed. dbmedic and
dbwitness stopped before their first measured result.

## Decision

1. Primary goal: learning OpenTelemetry-based database and OS observability.
   Every component choice favours standard, upstream building blocks over
   custom code, unless the standard piece demonstrably cannot do the job.
2. Engine order: PostgreSQL first, Oracle second, others later. A second
   engine starts only after PostgreSQL works end to end on at least the
   single-instance and streaming-replica topologies.
3. PostgreSQL topology order, each a separate stage:
   1. single instance and physical streaming standby
   2. logical replication and PgBouncer
   3. Patroni cluster
   4. Kubernetes operator (CloudNativePG first)
   5. cloud-managed PostgreSQL (short-lived, cost-bounded experiments)
4. A stage is done when its fault scenarios fire the expected alerts and show
   on the dashboards, not when its documents are written. Every stage has a
   no-fault control run.
5. The first slice is vertical: one PostgreSQL major (18), primary plus
   physical standby, collector, reference backend, one dashboard, a handful of
   unit-tested alert rules delivered through Alertmanager, fault scenarios
   such that every rule other than the watchdog is fired by at least one of
   them, a no-fault control that fires none except the always-firing
   watchdog, and a measured collector overhead.
6. Documents describe what runs. Plans live in one roadmap file, not in ADRs
   or READMEs.

## Consequences

- Breadth (more engines, more topologies, packaging) is deliberately delayed.
  Requests for breadth are checked against this ADR.
- Labs run on Docker Compose first, on kind for the Kubernetes stage, and on
  Proxmox VMs where a VM topology is needed (Patroni, OS-level faults). Lab
  VMs are disposable and restored from snapshots.
- AI-assisted root-cause analysis is out of scope until the telemetry it would
  read exists and has been validated by fault scenarios.
