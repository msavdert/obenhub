# pgha: the Patroni cluster on three Debian VMs

Three VMs (`pgha-1..3`, addresses in `nodes.sh`) each run etcd, Patroni,
PostgreSQL 18 and one Collector. The Collectors push to a gateway Collector
and a backend that run in Compose on this repository's host, so the VMs carry
no database for telemetry.

```text
pgha-N  Collector --OTLP/HTTP, mutual TLS--> gateway :34318 (LAN address of the host)
                                               |-> VictoriaMetrics, VictoriaLogs (127.0.0.1)
                                               '-> vmalert -> Alertmanager -> VictoriaLogs
```

## Commands

```sh
mise run lab:pgha:mon:up        # backend; creates mon/.env and the gateway certificates
mise run lab:pgha:provision     # VMs: converge over ssh, idempotent
mise run lab:pgha:mon:ps
mise run lab:pgha:mon:down      # also deletes the backend volumes
```

Backend ports, all on 127.0.0.1 except the gateway: VictoriaMetrics 38428,
VictoriaLogs 39428, vmalert 38880, Alertmanager 39093, Grafana 33000.

## What each node's Collector reads

It scrapes only its own node (`files/otelcol.yaml.tmpl`):

- PostgreSQL through the `postgresql` receiver and the shared `sql_query` pack
  (`lab/packs/postgresql/queries.yaml`), over `hostssl` with the lab CA.
- The Patroni REST API `/metrics` over https.
- etcd `/metrics` on `http://127.0.0.1:2381` (`--listen-metrics-urls`), so the
  Collector needs no etcd client certificate.
- The PostgreSQL `jsonlog` files.
- Host metrics (cpu, load, memory, paging, filesystem, disk, network,
  processes) and the journal (units `patroni`, `etcd`, `otelcol-contrib`, and
  the kernel ring buffer).
- Its own metrics, as `service.instance.id` `otelcol-<node>`.

Resource attributes follow `lab/stage3/otelcol/config.yaml`, with
`service.instance.id` `pgha-N` for `postgresql`, `patroni`, `etcd` and the
`host` service (host metrics and journal), and `db.cluster.name` `pgha`.

The monitor password reaches the node in `/etc/otelcol-contrib/monitor.env`
(root only, read by systemd); it is not in the config.

## Alerts

vmalert loads the shared packs `lab/packs/{postgresql,patroni,etcd}/rules.yml`
and `mon/vmalert/inventory.yml` (the Collectors and nodes this lab expects).
The Grafana instance provisions the stage 3 Patroni dashboard unchanged.

`CollectorAbsent` fires per Collector. Each node's targets are tagged with its
own Collector, so a stopped node Collector raises only its alert, and a stopped
gateway (which carries every node's telemetry) only the gateway's.
`mise run lab:pgha:rules-test` covers these cases.

The fault scenarios of stage 3 are not ported yet.
