# Host pack

`rules.yml` and `tests/` are the operating-system alerts; `dashboards/` holds the dashboard.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-host*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/host/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_HOST_INSTANCE_ID` | service.instance.id, the machine name | `pgha-1` |
| `OBENHUB_HOST_JOURNAL_UNITS` | systemd units whose journal is collected, a YAML list | `[patroni, etcd, otelcol-contrib]` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
