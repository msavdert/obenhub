# ADR 0002: OpenTelemetry-centred architecture and reference backend

- Status: Accepted; decision 2 refined by ADR 0005
- Date: 2026-11-06 (revised the same day after an external multi-model review, not published: OCB,
  gateway tier and role attribute deferred or changed)

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
   - Collector configuration for the upstream `otelcol-contrib` image; an own
     distribution built with the OpenTelemetry Collector Builder (OCB) comes
     once running labs have fixed the component list;
   - receiver configuration and SQL query packs (see ADR 0003);
   - a documented naming and meaning contract for every metric and event the
     project adds, including resource attributes for stable identity
     (cluster, instance, Patroni scope, Kubernetes and cloud identity). The
     role (primary or standby) changes on failover, so it is a metric
     (`pg_is_in_recovery()` per scrape) joined at query time, not a resource
     attribute;
   - the rule that "value is zero", "not observed", "collection failed" and
     "permission denied" are distinguishable in the data. Current receivers
     do not deliver this: a failing `sqlqueryreceiver` query is logged and
     its series disappear. Each query is its own scraper under one shared
     scraper name (`receiver/sqlqueryreceiver/receiver.go`, v0.164.0).
     The Collector's scraper self-metrics do not count a failed query: in
     the slice lab (contrib 0.164.0, 2026-11-06) a query failing with
     SQLSTATE 42501 left `otelcol_scraper_errored_metric_points` at 0 while
     `scraped_metric_points` kept rising. The receiver also reports each
     failure as a component status event, but all queries share one
     status, so it does not name the failed query. Until upstream has
     per-query outcomes, SQL returns 0 rather than no row where zero is meant, each
     target emits a heartbeat series checked against an expected
     inventory, a series that was present and vanished raises an alert,
     and the reason (failure or permission) is read from the Collector log.
   Anyone can point the output at their own OTLP-capable backend.
2. One Collector until a measured need for more (credential boundary, local
   log files, buffering under backpressure) justifies an agent per node plus
   a gateway. The pipeline monitors itself (collector internal metrics and
   logs, an always-firing watchdog alert whose absence an outside receiver
   notices, a telemetry-absent alert per target).
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
- VictoriaMetrics promotes every resource attribute and the instrumentation
  scope name and version to labels by default
  (`-opentelemetry.promoteAllResourceAttributes`,
  `-opentelemetry.promoteScopeMetadata`, v1.155.0 `-help`). What goes on the
  resource is series identity. Inferred, not yet observed: a Collector
  upgrade that changes the scope version creates new series unless
  `-opentelemetry.promoteScopeMetadata=false` is set.

## Not yet verified

- SigNoz `ee/LICENSE` terms.
- VictoriaTraces with OTLP traces. VictoriaMetrics and VictoriaLogs take the
  Collector's OTLP metrics and logs without a translation step in every lab
  (first in `lab/slice1`, 2026-11-06).
- Perses support for VictoriaLogs and VictoriaTraces.
