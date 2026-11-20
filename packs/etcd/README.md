# etcd pack

`rules.yml` and `tests/` are the alerts of the etcd pack, used by stage3 and pgha.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-etcd*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/etcd/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_ETCD_CLUSTER_NAME` | obenhub.cluster.name of the etcd cluster, not the PostgreSQL cluster | `pgha-etcd` |
| `OBENHUB_ETCD_HOST` | member host; also server.address | `pgha-1` |
| `OBENHUB_ETCD_INSTANCE_ID` | service.instance.id, the member name | `pgha-1` |
| `OBENHUB_ETCD_METRICS_ENDPOINT` | host:port the Collector scrapes | `127.0.0.1:2381` |
| `OBENHUB_ETCD_PORT` | member client port; also server.port | `2379` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
