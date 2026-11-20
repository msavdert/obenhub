# CloudNativePG pack

`rules.yml` and `tests/` are the alerts; `dashboards/cnpg.json` is the dashboard, mounted by k8s.

## Collection interval

`CNPGPrimaryChanged` reads `postgresql.recovery.active`, which the labs
collect every 15 s: its `[1m]` window holds four collections and the `[3m]`
window twelve, at least two as the rule requires. At 60 s the `[1m]` window
holds one; the interval check is `PostgresCollectionIntervalTooLong`
(`packs/postgresql`), which reads its heartbeat from the same queries file.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-cnpg*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/cnpg/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Run it in a DaemonSet with RBAC for the Kubernetes API; the base provides `k8s_observer/obenhub`. The pods of one CloudNativePG Cluster are selected by name, one namespace.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_CNPG_CLUSTER` | name of the CloudNativePG Cluster (label cnpg.io/cluster) | `pg` |
| `OBENHUB_CNPG_NAMESPACE` | namespace of the CloudNativePG Cluster | `obenhub` |
| `OBENHUB_PG_CA_FILE` | CA file that verifies the server certificate | `/etc/otelcol-contrib/tls/ca.crt` |
| `OBENHUB_PG_DATABASES` | databases the receiver connects to, a YAML list | `[postgres, app]` |
| `OBENHUB_PG_PASSWORD` | its password; from a secret store, never a file in a repository |  |
| `OBENHUB_PG_USER` | monitoring role (packs/postgresql/monitoring-role.sql) | `otel_monitor` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
