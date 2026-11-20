# pgBackRest pack

`rules.yml` and `tests/` are the alerts on backup state; the metrics come from woblerr/pgbackrest_exporter (ADR 0007).

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-pgbackrest*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/pgbackrest/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base, starts the Collector once with it (a receiver that cannot reach its target is fine, one that cannot start is not), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_CLUSTER_NAME` | obenhub.cluster.name, unique within the backend (ADR 0006 decision 7) | `pgha` |
| `OBENHUB_PGBACKREST_HOST` | host of pgbackrest_exporter; also server.address | `pgbackrest-exporter` |
| `OBENHUB_PGBACKREST_INSTANCE_ID` | service.instance.id | `pgbackrest` |
| `OBENHUB_PGBACKREST_PORT` | its port; also server.port | `9854` |
| `OBENHUB_SERVICE_NAMESPACE` | service.namespace of every series | `obenhub-lab` |
