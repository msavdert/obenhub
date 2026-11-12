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

The backend's Alertmanager and Grafana files are the ones in `lab/stage3/`
(`alertmanager`, `grafana`).

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
The Grafana instance provisions the stage 3 Patroni dashboard unchanged.

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
| `network-partition` | nftables on the leader and on the other two nodes drops all traffic between the leader and them (ssh and OTLP stay open) |
| `network-partition-replica` | the same on the first replica |
| `leader-killed` | `kill -STOP` on the leader's Patroni main process (PostgreSQL keeps running); the hardware watchdog resets the VM |
| `switchover` | `patronictl switchover` |
| `control` | no fault, 10 minutes of load |

The nftables scenarios add one table, `inet obenhub_fault`, on the victim
and delete it on revert; a left-over table fails the next run's precondition.
Patroni is stopped by no scenario except `leader-killed`, which freezes it on
purpose: its hardware watchdog (mode `required`) resets the VM.
`leader-killed` also writes from this box as role `app` (it needs `psql` here
and `APP_PASSWORD` in `lab/pgha/.env`). Client load is `obenhub-load.service` on every node (`files/load.sh`): the
same pgbench pattern as stage 3, through the local socket, and only while the
node is the primary.

The full suite of twelve scenarios (before the two partition scenarios) passed on 2026-11-10 (`results/runs.jsonl`,
`suite-2`) with no unexpected alert. `filesystem-filling` was detected after
179 s and `memory-pressure` after 183 s; in `memory-pressure` the replica did
not reboot and `oom_kill` stayed 0, so the OOM settings of the hog unit were
not exercised. In the earlier ten-scenario run, `quorum-lost` demoted the
leader without a watchdog reset (boot IDs of the three VMs unchanged).

### Network partition (runs 2026-11-10, `results/runs.jsonl`)

Baselines: "from the partition" is `extra.partition_start`; `seconds_to_detect`
and the alert times are from the start of inject (a few seconds earlier).

The table `inet obenhub_fault` is installed on all three nodes: on the
isolated node it drops packets from and to the two peers, on each peer it
drops packets from and to the isolated node. The first version had it on the
isolated node only. nftables rules do not survive a reset, and in the
suite-3 `network-partition` row (21:25, `pass=false`, kept in `runs.jsonl`) the
reset of the old leader pgha-1 ended the partition: it came back, won the
leader race again (timeline 10 to 11, last writable sample after the reboot, no
other node writable, no `pg_rewind`) and the run failed with "poller never
saw a new writable leader". The two earlier smoke runs had the majority
promote first, so that outcome is a race. The proof reads the counters of all
three tables and requires drops on every output chain; input chains are
recorded only, since once all three tables are in place each side drops what
it sends. The counters are read again in revert (`nft_drops_at_revert`).
The `extra` fields of these rows changed between script versions (the 21:25
row has `nft_drops_in`/`nft_drops_out`, later rows `nft_drops` per node).

Suite-3 (2026-11-10, 14 scenarios) passed the first ten scenarios and
failed at `network-partition` (the 21:25 row above). After the table moved to
the peers as well, the remaining four ran on their own (rows from 21:37); after
the last audit fixes `network-partition`, `network-partition-replica` and
`control` ran again (rows from 22:24). The numbers below are from those last
rows.

`network-partition` (row of 22:24): pgha-1 was the leader (timeline 13);
pgha-2 became leader (timeline 14). The old leader's VM was reset: Patroni's
"Demoting self" line is 12.4 s after the partition in VictoriaLogs and the new
boot's first kernel line 12.3 s after that. The most likely cause is the
hardware watchdog (assumption, not read from Patroni source); hypothesis for
why the demotion did not finish: dropped packets make every etcd call wait for
its timeout, so the HA loop overruns the watchdog timeout (ttl 30 = loop_wait
10 + 2 * retry_timeout 10), whereas `quorum-lost`, where connections are
refused at once, demoted without a reset. A first attempt outside
`runs.jsonl` (VictoriaLogs, 18:47:50 to 18:48:23) had the same sequence. The
poller (383 samples over three nodes, about one per second per node) saw the
old leader last writable at 22:24:55.6 and pgha-2 first writable at 22:25:07.2,
11.7 s apart, and no sample with two writable nodes; `primary_gap_seconds`
from `patroni_primary` read 0 (15 s steps hide gaps of this size). pgha-1 had
7 error samples and a longest blind window of 14.2 s; the others none.
`pg_rewind` ran on the old leader (3 journal lines). Drops (in/out) at the
proof: pgha-1 16/861, pgha-2 0/71, pgha-3 0/25; at revert, when pgha-1's own
table was gone with its reset, pgha-2 280/804 and pgha-3 280/215: the peers
dropped what the rebooted node sent, so the partition outlived the reset.
`seconds_to_detect` 91.3 s (`PatroniFailoverHappened`, `HostRebooted` for
pgha-1), `seconds_to_resolve` 297.1 s, no unexpected alert. The branch without
a reset has never run.

`network-partition-replica` (row of 22:31): pgha-1 isolated, leader pgha-2
and timeline 14 unchanged, no VM rebooted (the watchdog is armed on the leader
only: an assumption these runs' boot ids are consistent with, not proof).
`EtcdNoLeader`, `PostgresStandbyNotStreaming`, `PatroniReplicaNotEligible` (the leader
keeps writing while the replica receives nothing) and `PostgresPhysicalSlotInactive`
for the replica's slot on the leader all fired; the last one sets
`seconds_to_detect`, 304.1 s. In the 21:44 row they came 115, 194, 222 and
300 s after the start of inject (VictoriaLogs). All resolved within 101.3 s of
the revert, no unexpected alert. Drops at revert: pgha-1 35/2402, pgha-2
0/3044, pgha-3 0/873. Attempts outside `runs.jsonl` (VictoriaLogs and
VictoriaMetrics, 2026-11-10 19:11 to 19:23) were reverted at about 3 minutes
or lacked the last two alerts in EXPECT; the script comments name them.

### Leader killed (runs 2026-11-10 and 2026-11-11)

Suite-4 (`results/runs.jsonl` rows from 2026-11-10 23:58, all fifteen scenarios) passed with
no unexpected alert; it is the first suite on the poller shared through
`scenarios/lib.sh`.

`leader-killed` (row of 01:09): Patroni's main process on the leader pgha-2
was frozen at 01:09:21.6; its last line was the 01:09:19.8 loop ("no action.
I am (pgha-2), the leader with the lock"). PostgreSQL stayed writable until
01:09:44.76, the last loop plus the 25 s timeout of the i6300ESB watchdog
(`timeout_seconds` read from sysfs before the fault), and the new boot's first
kernel line is 33.0 s after the freeze. pgha-2 came back and kept the leader
key (outcome A, timeline 18 to 19, no `pg_rewind`). The poller saw 18.4 s
without a writable node and no sample with two; the writer, through
`target_session_attrs=read-write` from this box, saw 18.8 s between two
acknowledged inserts and lost none of its 503 acknowledged rows.
`seconds_to_detect` 118.7 s (`PatroniFailoverHappened`, `HostRebooted` for
pgha-2), `seconds_to_resolve` 280.7 s. `primary_gap_seconds` read 45, an
upper bound from 15 s steps. Why the timeline rises when the same node keeps
the key (a promotion after crash recovery) is not confirmed from a log.

Two smoke runs on the script before its audit fixes (not in `runs.jsonl`;
2026-11-10 23:12 and 23:21, `HostRebooted` for pgha-2 in VictoriaLogs at both)
had one outcome each: 23:12 outcome A (18.4 s, 531 of 531 rows), 23:21
outcome B, where pgha-1 took over (timeline 15 to 16, 8.8 s without a
writable node, 465 of 465 rows, `pg_rewind` on pgha-2). Which outcome a run
gets is a race; the asynchronous replication did not lose a row in either.
