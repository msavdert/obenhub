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

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-collector*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/collector/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

It is `service.telemetry` only and has no pipeline.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_COLLECTOR_INSTANCE_ID` | service.instance.id of this Collector | `otelcol-pgha-1` |
| `OBENHUB_GATEWAY_ENDPOINT` | OTLP/HTTP base URL the self-metrics go to (`/v1/metrics` is appended); the same variable the base exporter uses | `http://gateway:4318` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
