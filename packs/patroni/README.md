# Patroni pack

`rules.yml` and `tests/` are the alerts; `dashboards/patroni.json` is the dashboard, mounted by stage3 and pgha.

## Collection interval

The rules assume the Patroni `/metrics` scrape every 15 s (`prometheus`
receiver `scrape_interval: 15s` in the labs). A window holds at least two
collections: `[30s]` in `PatroniMultiplePrimaries`, and `[1m]` on
`postgresql.collection.heartbeat` (the `postgresql` pack's 15 s source) and
on `otelcol_process_uptime` in `PatroniTargetAbsent`.
`PatroniCollectionIntervalTooLong` fires when the samples of `up` of the
Patroni scrape are on average more than 20 s apart.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-patroni*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/patroni/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_PATRONI_CA_FILE` | CA file for https; unused with http | `/etc/otelcol-contrib/tls/ca.crt` |
| `OBENHUB_PATRONI_HOST` | member host; also server.address | `pgha-1` |
| `OBENHUB_PATRONI_INSTANCE_ID` | service.instance.id, the member name | `pgha-1` |
| `OBENHUB_PATRONI_PORT` | REST API port; also server.port | `8008` |
| `OBENHUB_PATRONI_SCHEME` | http or https | `https` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
