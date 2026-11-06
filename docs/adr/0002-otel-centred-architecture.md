# ADR 0002: OpenTelemetry-centred architecture and reference backend

- Status: Accepted
- Date: 2026-11-06

## Context

Prometheus stores metrics only. Query samples, execution plans, lock-wait
trees and log correlation do not fit metric labels; a multi-model review of
the private predecessor dbsight reached the same conclusion (5 of 7
reviewers). The vendors often cited as "the future" were checked on
2026-11-06:

- SigNoz is MIT except `ee/` and `cmd/enterprise/`, which are under a separate
  licence (terms not read). RBAC, retention controls and its AI assistant are
  paid or cloud-only.
- Robusta is an alert-enrichment layer on top of Prometheus webhooks.
  HolmesGPT, from the same team, is Apache 2.0 and a CNCF Sandbox project.
- Coralogix is closed SaaS. Its core idea, processing and alerting in the
  stream before indexing, is what an OpenTelemetry Collector pipeline does.

The durable part of these designs is OTLP as the wire format, logs and events
as first-class signals next to metrics, and backends that can be swapped.

## Decision

1. OpenTelemetry is the centre. The project's product is the collection side:
   - a Collector distribution built with the OpenTelemetry Collector Builder
     (OCB), from contrib components;
   - receiver configuration and SQL query packs (see ADR 0003);
   - a documented naming and meaning contract for every metric and event the
     project adds, including resource attributes that describe topology
     (cluster, role, Patroni scope, Kubernetes and cloud identity);
   - the rule that "value is zero", "not observed", "collection failed" and
     "permission denied" are distinguishable in the data.
   Anyone can point the output at their own OTLP-capable backend.
2. Two Collector tiers: an agent per database node (or sidecar), and a gateway
   that enriches, filters, batches and exports. The pipeline monitors itself
   (collector internal metrics and logs, a dead-man alert, a
   telemetry-absent alert per engine).
3. Reference backend, used by the lab, the dashboards and the alert rules:
   VictoriaMetrics (metrics), VictoriaLogs (logs and events), VictoriaTraces
   (traces), all Apache 2.0, all fed by OTLP. Alerting with vmalert and
   Alertmanager, every rule with a unit test.
4. Visualisation: Grafana OSS, with dashboards kept as code in this
   repository. Perses (Apache 2.0, CNCF) is re-evaluated when it supports the
   Victoria log and trace datasources.
5. A ClickHouse-based backend is evaluated later by sending the same OTLP
   stream to both backends and comparing them on the same fault scenarios.

## Consequences

- Backend-specific content (PromQL/LogsQL rules, Grafana JSON) is reference
  material; the OTLP contract is the stable interface.
- Grafana OSS is AGPL-3.0. It is run unmodified as a separate service and its
  code is not shipped here; the owner accepted this (ADR 0004).
- Event-shaped data (query samples, plans, lock trees) goes to the log signal,
  not to metric labels.

## Not yet verified

- SigNoz `ee/LICENSE` terms.
- Whether each Victoria component accepts every OTLP signal we need without an
  extra translation step; checked when the first slice runs.
- Perses support for VictoriaLogs and VictoriaTraces.
