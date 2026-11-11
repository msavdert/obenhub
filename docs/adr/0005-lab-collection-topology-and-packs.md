# ADR 0005: Collector topology, scraped endpoints, packs and MetricsQL

- Status: Accepted
- Date: 2026-11-11

## Context

The labs went past three earlier decisions without recording it:

- ADR 0002, decision 2, says one Collector until a measured need. `lab/pgha`
  runs a Collector per VM plus a gateway, and `lab/k8s` a DaemonSet, a
  Deployment and a gateway.
- ADR 0003 runs no exporter behind the `prometheus` receiver. The labs scrape
  Patroni's REST `/metrics`, every etcd member's `/metrics` and
  CloudNativePG's exporter.
- ADR 0003 calls a pack `sqlqueryreceiver` configuration. `lab/packs/<component>/`
  now also holds alert rules and their unit tests, and five of its six
  directories have no SQL.

The alert rules also use MetricsQL-only functions (`WITH` templates,
`label_set`, `union`, `tlast_over_time`, for example
`lab/packs/patroni/rules.yml`), which no ADR mentions.

## Decision

1. **Collector topology.** One Collector per lab while every target is
   reachable from one place (`lab/slice1`, `lab/stage3`). A Collector per node
   plus a gateway when the node itself is monitored: host metrics and
   journald logs need a local agent (`lab/pgha`, the operating-system layer of
   ADR 0001). On Kubernetes, the Collector Helm chart's DaemonSet for per-node
   receivers (kubelet stats, pod logs) and one Deployment for receivers that
   must run once per cluster (`k8s_cluster`, Kubernetes events). The gateway
   is the single path to the backend and, on the VMs, the mutual-TLS
   boundary. This is the measured need ADR 0002 decision 2 asks for.
2. **Scraped endpoints.** A component's own `/metrics` is scraped only when it
   reports state that SQL cannot read and contrib has no receiver for it:
   Patroni's REST `/metrics` (contrib has no Patroni receiver), etcd
   `/metrics`, and CloudNativePG's exporter restricted to
   `cnpg_collector_*` and `cnpg_last_error` with its default queries off.
   PostgreSQL metrics never come from an exporter; the database exporters
   ADR 0003 evaluated stay out.
3. **Pack.** `lab/packs/<component>/` holds what every lab shares for one
   component: queries (PostgreSQL only), alert rules and their unit tests.
   What differs per lab (inventory, Collector wiring, backend) stays in the
   lab directory.
4. **MetricsQL.** Alert rules are written for VictoriaMetrics and vmalert,
   the reference backend of ADR 0002 decision 3, and may use MetricsQL.
   Prometheus and Mimir cannot load them, and no PromQL copy is kept.
5. **Statement timeout on CloudNativePG.** A CloudNativePG managed role has no
   field for a role-level setting, so the monitoring role in `lab/k8s` runs
   without the server-side `statement_timeout` ADR 0003 requires
   (`lab/k8s/cnpg/cluster.yaml`). This is an accepted gap for the lab, not a
   pattern for production.

## Consequences

- ADR 0002 and ADR 0003 keep their text; their status lines point here.
- A rule that would load in Prometheus is not a goal. Porting the rules is
  work for whoever needs it, and the OTLP contract stays the stable interface
  (ADR 0002).
- A new component with a `/metrics` endpoint is checked against decision 2
  before it is scraped.
