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

vmalert loads the shared packs `lab/packs/{postgresql,patroni,etcd,host}/rules.yml`
and `mon/vmalert/inventory.yml` (the Collectors and nodes this lab expects).
The Grafana instance provisions the stage 3 Patroni dashboard unchanged.

`CollectorAbsent` fires per Collector. Each node's targets are tagged with its
own Collector, so a stopped node Collector raises only its alert, and a stopped
gateway (which carries every node's telemetry) only the gateway's.
`mise run lab:pgha:rules-test` covers these cases.

The host pack (`lab/packs/host/rules.yml`, tests with `mise run
lab:host:rules-test`) reads the series of the Collector's hostmetrics receiver
(`host_metrics` in the config). The two
memory metrics it needs are off by default and enabled in
`files/otelcol.yaml.tmpl`.

## Fault scenarios

`mise run lab:pgha:scenario <name>` runs one scenario against the VMs;
`mise run lab:pgha:scenarios` runs all of them, `control` last. Each result is
one line in `results/runs.jsonl`, with the same fields as
`lab/stage3/results/runs.jsonl` (component versions, read from the nodes, sit
under `images`). The machinery is `lab/scenarios/lib-core.sh`, shared with
stage 3; `scenarios/lib.sh` is the adapter that reaches the nodes over ssh.

| Scenario | Fault |
| --- | --- |
| `quorum-lost` | `systemctl stop etcd` on pgha-2 and pgha-3 |
| `etcd-member-down` | `systemctl stop etcd` on one non-leader member |
| `etcd-leader-changes` | `etcdctl move-leader` four times, 15 s apart |
| `patroni-down` | nftables drops the Collector's scrape of Patroni `:8008` on one replica |
| `filesystem-filling` | `fallocate` on one replica until 7 % of `/` is available (`HostFilesystemSpaceLow`) |
| `memory-pressure` | a resident memory hog (`obenhub-memhog`, OOM score 1000) on one replica until MemAvailable is about 6 % of MemTotal (`HostMemoryAvailableLow`) |
| `replica-not-eligible` | nftables drops tcp 5432 between one replica and the leader, 100 MB written |
| `replay-paused` | `pg_wal_replay_pause()` on one replica, cluster paused |
| `cluster-paused` | `patronictl pause` |
| `pending-restart` | `patronictl edit-config` of `shared_buffers` |
| `switchover` | `patronictl switchover` |
| `control` | no fault, 10 minutes of load |

The two nftables scenarios add one table, `inet obenhub_fault`, on the victim
and delete it on revert; a left-over table fails the next run's precondition.
Patroni is never stopped: its hardware watchdog (mode `required`) resets the
VM. Client load is `obenhub-load.service` on every node (`files/load.sh`): the
same pgbench pattern as stage 3, through the local socket, and only while the
node is the primary.

The full suite of twelve scenarios passed on 2026-11-10 (`results/runs.jsonl`,
`suite-2`) with no unexpected alert. `filesystem-filling` was detected after
179 s and `memory-pressure` after 183 s; in `memory-pressure` the replica did
not reboot and `oom_kill` stayed 0, so the OOM settings of the hog unit were
not exercised. In the earlier ten-scenario run, `quorum-lost` demoted the
leader without a watchdog reset (boot IDs of the three VMs unchanged).
