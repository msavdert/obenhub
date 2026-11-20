# etcd pack

`rules.yml` and `tests/` are the alerts of the etcd pack, used by stage3 and pgha.

## Thresholds

Every policy threshold is a production default in the rule that a lab can override with a recorded series; the series, defaults and units are in the generated table [etcd-pack-alerts.md#thresholds](../../docs/reference/etcd-pack-alerts.md#thresholds).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-etcd*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/etcd/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_ETCD_CLUSTER_NAME` | obenhub.cluster.name of the etcd cluster, not the PostgreSQL cluster | `pgha-etcd` |
| `OBENHUB_ETCD_HOST` | member host; also server.address | `pgha-1` |
| `OBENHUB_ETCD_INSTANCE_ID` | service.instance.id, the member name | `pgha-1` |
| `OBENHUB_ETCD_METRICS_ENDPOINT` | host:port the Collector scrapes | `127.0.0.1:2381` |
| `OBENHUB_ETCD_PORT` | member client port; also server.port | `2379` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
