# Host pack

`rules.yml` and `tests/` are the operating-system alerts; `dashboards/` holds the dashboard.

## Thresholds

Every policy threshold is a production default in the rule that a lab can override with a recorded series; the series, defaults and units are in the generated table [host-pack-alerts.md#thresholds](../../docs/reference/host-pack-alerts.md#thresholds).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-host*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/host/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not) without the logs pipeline, because the contrib image has no `journalctl`, and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_HOST_INSTANCE_ID` | service.instance.id, the machine name | `pgha-1` |
| `OBENHUB_HOST_JOURNAL_UNITS` | systemd units whose journal is collected, a YAML list | `[patroni, etcd, otelcol-contrib]` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
