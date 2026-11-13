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

## Prerequisites

What `scripts/provision.sh` and the scenarios require; nothing else is
assumed.

- Three Debian 13 amd64 VMs with the addresses in `nodes.sh`
  (`pgha-1=10.0.0.16`, `pgha-2=10.0.0.17`, `pgha-3=10.0.0.18`, subnet
  `10.0.0.0/24`), able to reach the internet over https (apt, PGDG, GitHub
  release downloads) and the gateway at `GATEWAY_IP:GATEWAY_PORT` of
  `nodes.sh` (this box, `10.0.0.11:34318`).
- ssh aliases `pgha-1`, `pgha-2` and `pgha-3` (the node names) in the ssh
  configuration of the user who runs the scripts, key login without a
  prompt (`BatchMode=yes`), to a user with passwordless `sudo`. The scenarios
  use the same aliases.
- A watchdog device: Patroni runs with watchdog mode required and
  `provision.sh` stops when `/dev/watchdog` is missing; it only changes the
  group of an existing device (udev rule, group `postgres`) and loads no
  module. On the lab VMs the device comes from the kernel module `i6300esb`
  (the virtual watchdog of the hypervisor; observed on `pgha-1`, 2026-11-11).
  `softdog` would also create it (assumption: not used here).
- On this box: Docker (backend Compose project), `openssl` (certificates),
  `curl`, `jq` and the tools of [`mise.toml`](../../mise.toml); the backend
  and scenarios are run through `mise run` (`mise install` first).

## Commands

```sh
mise run lab:pgha:mon:up        # backend; creates mon/.env and the gateway certificates
mise run lab:pgha:provision     # VMs: converge over ssh, idempotent
mise run lab:pgha:mon:ps
mise run lab:pgha:mon:down      # also deletes the backend volumes
```

The backend services extend `lab/mon/compose.base.yaml`; the Alertmanager
config and Grafana provisioning are the shared ones in `lab/mon/`.

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
`host` service (host metrics and journal), and `obenhub.cluster.name` `pgha`.

The monitor password reaches the node in `/etc/otelcol-contrib/monitor.env`
(root only, read by systemd); it is not in the config.

## Alerts

vmalert loads the shared packs `lab/packs/{postgresql,patroni,etcd,host}/rules.yml`
and `mon/vmalert/inventory.yml` (the Collectors and nodes this lab expects).
The Grafana instance provisions the stage 3 Patroni dashboard unchanged and the
shared host dashboard, `lab/packs/host/dashboards/host.json` (filesystem,
memory, uptime, CPU, load, network, disk; the host alerts' expressions) and the
shared PostgreSQL dashboard of slice 1.
`mise run lab:pgha:panels` runs the queries of all three dashboards against the live Grafana.

`CollectorAbsent` fires per Collector. Each node's targets are tagged with its
own Collector, so a stopped node Collector raises only its alert, and a stopped
gateway (which carries every node's telemetry) only the gateway's.
`mise run lab:pgha:rules-test` covers these cases.

The host pack (`lab/packs/host/rules.yml`, tests with `mise run
lab:host:rules-test`) reads the series of the Collector's hostmetrics receiver
(`host_metrics` in the config). The two
memory metrics it needs are off by default and enabled in
`files/otelcol.yaml.tmpl`, as is the `system` scraper for `system.uptime`
(`HostRebooted`, uptime below 300 s).

## Fault scenarios

`mise run lab:pgha:scenario <name>` runs one scenario against the VMs;
`mise run lab:pgha:scenarios` runs all of them, `control` last, as a suite
(see [lab/README.md](../README.md)). Each result is one line in
`results/runs.jsonl`, with the same fields as
`lab/stage3/results/runs.jsonl` (component versions, read from the nodes, sit
under `images`). The machinery is `lab/scenarios/lib-core.sh`, shared with
slice 1, stage 3 and k8s; `scenarios/lib.sh` is the adapter that reaches the nodes over ssh.

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
| `network-partition` | nftables on the leader and on the other two nodes drops all traffic between the leader and them (ssh and OTLP stay open) |
| `network-partition-replica` | the same on the first replica |
| `synchronous-standby-cut` | `synchronous_mode` and strict on, then the synchronous standby is isolated, then the leader loses the other replica on tcp 5432 (see below) |
| `leader-killed` | `kill -STOP` on the leader's Patroni main process (PostgreSQL keeps running); the hardware watchdog resets the VM |
| `switchover` | `patronictl switchover` |
| `control` | no fault, 10 minutes of load |

The nftables scenarios add one table, `inet obenhub_fault`, on the victim
and delete it on revert; a left-over table fails the next run's precondition.
Patroni is stopped by no scenario except `leader-killed`, which freezes it on
purpose: its hardware watchdog (mode `required`) resets the VM.
`leader-killed` also writes from this box as role `app` (it needs `psql` here
and `APP_PASSWORD` in `lab/pgha/.env`). Client load is `obenhub-load.service` on every node (`files/load.sh`): the
same pgbench pattern as stage 3, as role `app` over TLS to the node IP
(`sslmode=require`, no CA verification), and only while the node is the primary.

Suites are recorded in `results/runs.jsonl` (the latest,
`pgha-20261112T105036Z-2d9245b`, has all sixteen scenarios, `pass` true, no
unexpected alert). Rows before 2026-11-12 have `suite` null and are told apart
by date and scenario. What the rows cannot show is below.

- `memory-pressure`: the replica did not reboot and `oom_kill` stayed 0, so the
  OOM settings of the hog unit were not exercised.
- `quorum-lost` demoted the leader without a watchdog reset (boot ids of the
  three VMs unchanged).

### Network partition

The table `inet obenhub_fault` is installed on all three nodes: on the
isolated node it drops packets from and to the two peers, on each peer it
drops packets from and to the isolated node. The first version had it on the
isolated node only, and nftables rules do not survive a reset: in the
`network-partition` row of 2026-11-10T21:25 (`pass` false) the reset of the old
leader ended the partition, it won the leader race again and the run failed
with "poller never saw a new writable leader". The proof reads the counters of
all three tables and requires drops on every output chain; input chains are
recorded only. The counters are read again in revert (`nft_drops_at_revert`).
The `extra` fields changed between script versions.

When the isolated node is the leader its VM is reset (row of 2026-11-10T22:24;
Patroni logs "Demoting self" about 12 s after the partition and the new
boot's first kernel line follows about 12 s later). The most likely cause is the
hardware watchdog (assumption, not read from Patroni source). Hypothesis for
why the demotion does not finish: dropped packets make every etcd call wait for
its timeout, so the HA loop overruns the watchdog timeout. The lab values are
ttl 30, loop_wait 10, retry_timeout 10, which meet the documented constraint
`loop_wait + 2 * retry_timeout <= ttl` with equality
([dynamic configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html),
`latest` docs, read 2026-11-12). `quorum-lost`, where connections are refused
at once, demotes without a reset. `pg_rewind` ran on the old leader. At
revert the surviving peers' tables still dropped what the rebooted node sent
(counters 280 in on both), so the partition outlived the reset. The branch
without a reset has never run.

`network-partition-replica`: the leader and timeline do not change and no VM
reboots (the watchdog is armed on the leader only: an assumption the boot ids
are consistent with, not proof). The slot alert on the leader sets
`seconds_to_detect` (about 300 s).

### Leader killed

Patroni's main process on the leader is frozen; its last journal line is the
loop before the freeze, PostgreSQL stays writable until the watchdog fires
(25 s timeout of the i6300ESB device, `timeout_seconds` read from sysfs before
the fault), and the new boot's first kernel line is about 33 s after the freeze.
The writer, through `target_session_attrs=read-write` from this box, lost none
of its acknowledged rows. `primary_gap_seconds` from `patroni_primary` is an
upper bound from 15 s steps.

Both recorded rows (2026-11-11T01:09 and the suite of 2026-11-12) are outcome
A: the old leader came back and kept the leader key, and no replica took over.
The timeline still rose by one, which is what `PatroniFailoverHappened` fires
on; why is not confirmed from a log. Outcome B (a replica takes over, the old
leader rejoins with `pg_rewind`) is known only from a smoke run on
2026-11-10 that is not in `runs.jsonl` (8.8 s without a writable node, 465 of
465 rows kept). Which outcome a run gets is a race, so the scenario does not
assert a leadership change.

### Synchronous standby cut

The lab runs asynchronously. `synchronous-standby-cut` sets `synchronous_mode`
and `synchronous_mode_strict` through `patronictl edit-config`, removes both
keys again in revert, and refuses to start while either key or the table
`inet obenhub_fault2` is left over. Strict mode is part of it: the
[Patroni replication modes page](https://patroni.readthedocs.io/en/latest/replication_modes.html)
(the `latest` docs, read 2026-11-11; no version stated, the pinned Patroni is
4.1.5) says that without strict the primary falls back to asynchronous
replication after the HA loop; that case was not run.
Step 1 isolates the synchronous standby (`isolate_node`, as
`network-partition-replica`); step 2 then drops tcp 5432 between the leader and
the other replica (`inet obenhub_fault2`, etcd stays reachable, no failover).
A sampler on the leader records `synchronous_standby_names`, the `sync_state`
of every WAL sender and the duration of a transactional
`pg_logical_emit_message` commit once per second. A commit wait shows as 8.0 s,
the client's limit (`statement_timeout` does not cut it); the probe stops after
20 waiting samples so that a long hold cannot exhaust connections.

Three smoke runs (2026-11-12 01:03, 01:38 and 02:08 UTC) showed the same
sequence. The raw sampler data was not kept, so what follows is "observed in
smoke runs" unless it names the Patroni journal of the 01:38 run (VictoriaLogs):

- Commits waited from the cut until Patroni changed the setting (37.8 s after
  the cut: `Updating synchronous privilege temporarily from ['pgha-3'] to []`,
  then `Assigning synchronous standby status to ['pgha-2']`). The other
  replica was listed `sync` 39.8 to 42.8 s after the cut and commits resumed.
  The delay is consistent with ttl 30 s and loop_wait 10 s (inferred, not
  proven).
- Step 2: the other replica's `sync` row disappeared about 65 s after its
  table was in place, consistent with `wal_sender_timeout` = 60 s (read with
  `SHOW` on pgha-2 on 2026-11-12). Patroni then logged `Updating synchronous
  privilege temporarily from ['pgha-2'] to []` and `Assigning synchronous
  standby status to ['*']`, repeated every 10 s until revert: strict mode
  leaves the setting at `*` and does not fall back. No commit succeeded from
  then until revert.
- Leader, timeline and boot ids did not change in any run.
- Alerts: `EtcdNoLeader`, `PostgresStandbyNotStreaming` for both standbys,
  `PostgresPhysicalSlotInactive` for the leader, and
  `PostgresSynchronousStandbyMissing` for the leader about 3 minutes after
  step 2 (the row has to vanish, then `for: 1m`). In the first two runs
  `PostgresSnapshotHeldTooLong` and `PostgresBlockedSessions` also fired on
  the leader; waiting commits keep snapshots and row locks, the likely cause
  (not checked). The scenario allows both. `PatroniReplicaNotEligible` never
  fired.
- Patroni's `/metrics` has `patroni_sync_standby` per node (Patroni 4.1.5
  `api.py` on the nodes) but no flag for whether synchronous mode is on, so an
  alert on "no synchronous standby" from Patroni alone cannot tell the
  asynchronous lab from a failure. The alert therefore reads PostgreSQL: the
  pack metrics `postgresql.replication.synchronous_standby.required` (the
  `num_sync` of `synchronous_standby_names`) and `.count` (`sync` or `quorum`
  rows of `pg_stat_replication`), and fires when count is below required.
  Without strict mode Patroni empties the setting and this alert is silent
  (not run; from the Patroni page).
