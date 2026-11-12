# stage3

Docker Compose project `obenhub-stage3`, with its own backend so the slice1
lab keeps running. Run it with `mise run lab:stage3:scenarios`; results are in
`results/runs.jsonl`. The same cluster on VMs is [pgha](../pgha).

Versions read 2026-11-07: Patroni 4.1.5 (MIT; PostgreSQL 18 support since
4.0.7) from the PGDG package in `postgres:18.6-trixie`, etcd 3.6.16
(Apache-2.0).

## What runs

- Three etcd members and three PostgreSQL 18 nodes under Patroni, `etcd3` DCS,
  defaults for `ttl`, `loop_wait` and `failsafe_mode` (failsafe is off).
- No HAProxy: clients use libpq multi-host strings with
  `target_session_attrs=read-write`.
- One Collector: the shared PostgreSQL pack on every node, named by node and
  never by role, `prometheusreceiver` on each node's Patroni `/metrics`
  (contrib has no Patroni receiver) and on each etcd member.
- Each scenario reloads vmalert and Alertmanager first, checks the reload
  counters and records the hash of the rule and Alertmanager files as the
  containers read them; a mismatch with the repository fails the run.

## Scenario notes

- `replica-not-eligible`: paused replay does not work here; Patroni 4.1.5
  measures lag from the received position and resumes paused replay unless
  the cluster is paused. The scenario cuts a replica from the replication
  network while the leader writes past `maximum_lag_on_failover`.
- Planned switchover raises no alert except the failover rule, which cannot
  tell planned from unplanned: both raise the timeline by one.
- Patroni is the container's main process, so stopping it stops PostgreSQL
  too. The scrape-absent scenario blocks the Collector's scrape of one
  node's REST API instead.
- Unit tests only, no scenario: failsafe mode active (lab runs it off),
  transaction ID wraparound (the lab cannot reach those ages), and the two
  etcd disk-latency rules (no latency injection was attempted).
- The shared PostgreSQL rules for snapshot age, connection saturation and
  SeriesVanished are fired by slice1 scenarios, not here.

Sources for the rule coverage review of 2026-11-07: pigsty v4.5.0, the etcd
mixin at v3.7.3 and pgMonitor (Apache-2.0, copied with provenance);
awesome-prometheus-alerts (CC BY 4.0) and AGPL sources gave ideas only.
