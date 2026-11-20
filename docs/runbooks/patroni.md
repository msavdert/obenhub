# Patroni pack runbook

One section for each alert of `packs/patroni/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/patroni-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## PatroniNoWritablePrimary

No member of the cluster reports `patroni_primary` 1, so the cluster cannot take writes. Reference: [PatroniNoWritablePrimary](../reference/patroni-pack-alerts.md#patroninowritableprimary).

Look first: Members and roles.

```bash
patronictl -c /etc/patroni/config.yml list
```

From `ptl` in `lab/pgha/scenarios/lib.sh` (as the postgres user on a node; the stage3 lab runs `patronictl list` inside the container, `lab/stage3/scenarios/lib.sh`).

Look first: The DCS behind it.

```bash
etcdctl --endpoints=<all member client URLs> \
  --cacert=/etc/etcd/tls/ca.crt --cert=/etc/etcd/tls/etcdctl.crt --key=/etc/etcd/tls/etcdctl.key \
  endpoint status
```

From `etcd_status` and `ETCD_TLS` in `lab/pgha/scenarios/lib.sh` (run as root on a node; the stage3 lab runs the same `etcdctl endpoint status` without TLS flags, `lab/stage3/scenarios/lib.sh`).

Seen in the lab:

- pgha: `quorum-lost` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `quorum-lost` (suite `stage3-20261118T214721Z-e47dc14`)

## PatroniFailoverHappened

The highest PostgreSQL timeline of the cluster rose within the last hour: a switchover or a failover, which the metrics cannot tell apart. Reference: [PatroniFailoverHappened](../reference/patroni-pack-alerts.md#patronifailoverhappened).

Look first: Leader and timeline.

```bash
patronictl -c /etc/patroni/config.yml list
```

From `ptl` in `lab/pgha/scenarios/lib.sh` (as the postgres user on a node; the stage3 lab runs `patronictl list` inside the container, `lab/stage3/scenarios/lib.sh`). The harness reads the leader's `TL` from `patronictl list -f json`, `timeline()` in `lab/scenarios/lib-core.sh`.

Seen in the lab:

- pgha: `leader-killed`, `network-partition`, `switchover` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `leader-killed`, `switchover` (suite `stage3-20261118T214721Z-e47dc14`)

## PatroniReplicaNotEligible

A replica's WAL position is more than 16 MiB behind the leader's, so Patroni will not promote it. Reference: [PatroniReplicaNotEligible](../reference/patroni-pack-alerts.md#patronireplicanoteligible).

Look first: Members and their lag.

```bash
patronictl -c /etc/patroni/config.yml list
```

From `ptl` in `lab/pgha/scenarios/lib.sh` (as the postgres user on a node; the stage3 lab runs `patronictl list` inside the container, `lab/stage3/scenarios/lib.sh`).

Seen in the lab:

- pgha: `network-partition-replica`, `replica-not-eligible` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `replica-not-eligible` (suite `stage3-20261118T214721Z-e47dc14`)

## PatroniClusterPaused

The cluster has been in maintenance mode for 3 minutes, which disables automatic failover. Reference: [PatroniClusterPaused](../reference/patroni-pack-alerts.md#patroniclusterpaused).

Look first: Look for `Maintenance mode: on`, end it with resume.

```bash
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml resume --wait
```

From `ptl` in `lab/pgha/scenarios/lib.sh` (as the postgres user on a node; the stage3 lab runs `patronictl list` inside the container, `lab/stage3/scenarios/lib.sh`). The `Maintenance mode: on` line is what `cluster_paused` greps in `lab/scenarios/lib-core.sh`; `resume --wait` is the revert of `lab/scenarios/patroni/cluster-paused.sh`.

Seen in the lab:

- pgha: `cluster-paused` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `cluster-paused` (suite `stage3-20261118T214721Z-e47dc14`)

## PatroniPendingRestart

A PostgreSQL parameter changed on a member needs a restart to take effect. Reference: [PatroniPendingRestart](../reference/patroni-pack-alerts.md#patronipendingrestart).

Look first: The member flagged as pending restart.

```bash
patronictl -c /etc/patroni/config.yml list
```

From `ptl` in `lab/pgha/scenarios/lib.sh` (as the postgres user on a node; the stage3 lab runs `patronictl list` inside the container, `lab/stage3/scenarios/lib.sh`). The flag shows in the `patronictl list` output (comment in `lab/pgha/scripts/provision.sh`).

Seen in the lab:

- pgha: `pending-restart` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `pending-restart` (suite `stage3-20261118T214721Z-e47dc14`)

## PatroniTargetAbsent

Patroni's REST endpoint of a member has not answered for 2 minutes while that node's PostgreSQL heartbeat is present: no failover logic runs there. Reference: [PatroniTargetAbsent](../reference/patroni-pack-alerts.md#patronitargetabsent).

Look first: Patroni's log on the node.

```logsql
host.name:=<node> syslog.identifier:=patroni _time:>$T_START | sort by (_time desc) | limit 20 | fields _time,_msg
```

Field names from `lab/pgha/scenarios/leader-killed.sh` (pgha lab, Patroni under systemd); run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`. The stage3 lab runs Patroni in a container and has no such log source (assumption, not checked).

Seen in the lab:

- pgha: `patroni-down` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `patroni-down` (suite `stage3-20261118T214721Z-e47dc14`)
