# Collector pack

`rules.yml` holds the engine-neutral alerts every lab loads: `Watchdog`
(always firing, proves the alert pipeline), `CollectorAbsent` (an expected
Collector with no self-metrics) and `CollectorUnknown` (an inventory entry that
names no expected Collector). `tests/` are their unit tests.

A lab mounts this file into vmalert next to its engine pack and defines
`obenhub.expected_collector`, `obenhub.expected_target` and
`obenhub.expected_scrape` in its own inventory group. Names follow
[ADR 0006](../../docs/adr/0006-naming-contract.md).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-collector*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/collector/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

It is `service.telemetry` only and has no pipeline.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_COLLECTOR_INSTANCE_ID` | service.instance.id of this Collector | `otelcol-pgha-1` |
| `OBENHUB_COLLECTOR_METRICS_ENDPOINT` | OTLP/HTTP URL that receives the self-metrics | `http://gateway:4318/v1/metrics` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
