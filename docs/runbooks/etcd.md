# etcd pack runbook

One section for each alert of `packs/etcd/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/etcd-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

Command several sections use:

```bash
etcdctl --endpoints=<all member client URLs> \
  --cacert=/etc/etcd/tls/ca.crt --cert=/etc/etcd/tls/etcdctl.crt --key=/etc/etcd/tls/etcdctl.key \
  endpoint status
```

From `etcd_status` and `ETCD_TLS` in `lab/pgha/scenarios/lib.sh` (run as root on a node; the stage3 lab runs the same `etcdctl endpoint status` without TLS flags, `lab/stage3/scenarios/lib.sh`).

## EtcdMemberAbsent

An expected etcd member has had no successful scrape for 2 minutes while the Collector that scrapes it is alive. Reference: [EtcdMemberAbsent](../reference/etcd-pack-alerts.md#etcdmemberabsent).

Look first: Which member answers, with `etcdctl endpoint status` (see the top of this page).

Seen in the lab:

- pgha: `etcd-member-down`, `quorum-lost` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `etcd-member-down`, `quorum-lost` (suite `stage3-20261118T214721Z-e47dc14`)

## EtcdInsufficientMembers

Fewer etcd members report than a majority of the inventory: quorum is lost or the cluster cannot be seen. Reference: [EtcdInsufficientMembers](../reference/etcd-pack-alerts.md#etcdinsufficientmembers).

Look first: Which members answer, with `etcdctl endpoint status` (see the top of this page).

Seen in the lab:

- pgha: `quorum-lost` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `quorum-lost` (suite `stage3-20261118T214721Z-e47dc14`)

## EtcdNoLeader

A reporting etcd member has had no leader for a minute. Reference: [EtcdNoLeader](../reference/etcd-pack-alerts.md#etcdnoleader).

Look first: Leader and members, with `etcdctl endpoint status` (see the top of this page).

Seen in the lab:

- pgha: `network-partition-replica`, `quorum-lost`, `synchronous-standby-cut` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `quorum-lost` (suite `stage3-20261118T214721Z-e47dc14`)

## EtcdHighLeaderChanges

Three or more leader changes within 5 minutes. Reference: [EtcdHighLeaderChanges](../reference/etcd-pack-alerts.md#etcdhighleaderchanges).

Look first: Current leader, with `etcdctl endpoint status` (see the top of this page). The scenario causes the changes with `etcdctl move-leader`.

Seen in the lab:

- pgha: `etcd-leader-changes` (suite `pgha-20261118T225346Z-e47dc14`)
- stage3: `etcd-leader-changes` (suite `stage3-20261118T214721Z-e47dc14`)
