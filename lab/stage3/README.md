# stage3

Docker Compose project `obenhub-stage3`, with its own backend so the slice1
lab keeps running. Run it with `mise run lab:stage3:scenarios`; results are in
`results/runs.jsonl`. The same cluster on VMs is [pgha](../pgha).

Versions read 2026-11-07: Patroni 4.1.5 (MIT; PostgreSQL 18 support since
4.0.7) from the PGDG package in `postgres:18.6-trixie`, etcd 3.6.16
(Apache-2.0).

## Prerequisites

Docker with Compose, and `mise install` for the tools. `mise run lab:stage3:up` starts
the lab and generates its `.env` with random passwords; `mise run lab:stage3:down`
stops it. Do not run it together with a slice1 suite: both use the host lock.

## What runs

- Three etcd members and three PostgreSQL 18 nodes under Patroni, `etcd3` DCS,
  defaults for `ttl`, `loop_wait` and `failsafe_mode` (failsafe is off).
- No HAProxy: clients use libpq multi-host strings with
  `target_session_attrs=read-write`.
- One Collector: the shared PostgreSQL pack on every node, named by node and
  never by role, `prometheusreceiver` on each node's Patroni `/metrics`
  (contrib has no Patroni receiver) and on each etcd member.
- `mise run lab:stage3:panels` runs the Patroni dashboard's panel queries
  against the live Grafana.
- The Collector config `otelcol/config.yaml` is rendered from
  `otelcol/config.yaml.tmpl` (`scripts/gen-otelcol.sh`; `mise run
  lab:stage3:otelcol-check` fails when the two disagree): edit the template.
- Each scenario reloads vmalert and Alertmanager first, checks the reload
  counters and records the hash of the rule and Alertmanager files as the
  containers read them; a mismatch with the repository fails the run.

## Scenario notes

- `replica-not-eligible`: paused replay does not make a replica ineligible
  here (`replay-paused` expects no `PatroniReplicaNotEligible`, and passed:
  `results/runs.jsonl`). Why is unverified: the scenario's comment says Patroni
  compares max(received, replayed) with the leader's position, and that it
  resumes paused replay unless the cluster is paused; no Patroni source or doc
  page was read for either claim. The scenario cuts a replica from the
  replication network while the leader writes past `maximum_lag_on_failover`
  (the setting is documented: "the maximum bytes a follower may lag to be able
  to participate in leader election",
  [dynamic configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html),
  `latest` docs, read 2026-11-12).
- Planned switchover raises no alert except the failover rule, which cannot
  tell planned from unplanned: both raise the timeline by one (switchover rows in `results/runs.jsonl`:
  `timeline_before` 44, `timeline_after` 45 in the latest suite; that an
  unplanned failover does the same is unverified here).
- Patroni is the container's main process, so stopping it stops PostgreSQL
  too. The scrape-absent scenario blocks the Collector's scrape of one
  node's REST API instead.
- Unit tests only, no scenario: failsafe mode active (lab runs it off),
  transaction ID wraparound (the lab cannot reach those ages), and the two
  etcd disk-latency rules (no latency injection was attempted).
- The shared PostgreSQL rules for snapshot age, connection saturation and
  PostgresSeriesVanished are fired by slice1 scenarios, not here.

Sources for the rule coverage review of 2026-11-07: pigsty v4.5.0, the etcd
mixin at v3.7.3 and pgMonitor (Apache-2.0, copied with provenance);
awesome-prometheus-alerts (CC BY 4.0) and AGPL sources gave ideas only.
