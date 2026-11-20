# Host pack runbook

One section for each alert of `packs/host/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/host-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## HostFilesystemSpaceLow

Under 10 % of a mounted ext4, xfs or btrfs filesystem is free. Reference: [HostFilesystemSpaceLow](../reference/host-pack-alerts.md#hostfilesystemspacelow).

Look first: On the host, for the mount point in the alert.

```bash
df -B1 --output=avail,used <mountpoint>
```

Form from `fs_share` in `lab/pgha/scenarios/filesystem-filling.sh`, which computes the same share the rule does.

Seen in the lab:

- pgha: `filesystem-filling` (suite `pgha-20261118T225346Z-e47dc14`)

## HostMemoryAvailableLow

`MemAvailable` is under 10 % of the host's memory for 2 minutes. Reference: [HostMemoryAvailableLow](../reference/host-pack-alerts.md#hostmemoryavailablelow).

Look first: On the host.

```bash
grep -E '^(MemAvailable|MemTotal):' /proc/meminfo
```

`memkb` and `avail_share` in `lab/pgha/scenarios/memory-pressure.sh` read the same two fields.

Seen in the lab:

- pgha: `memory-pressure` (suite `pgha-20261118T225346Z-e47dc14`)

## HostRebooted

The host booted less than 5 minutes ago, whatever the reason. Reference: [HostRebooted](../reference/host-pack-alerts.md#hostrebooted).

Look first: First kernel line after the boot.

```logsql
host.name:=<host> _time:>$T_START "Linux version" | sort by (_time) | limit 1 | fields _time
```

`first_line_time` and its `"Linux version"` filter in `lab/pgha/scenarios/leader-killed.sh`, which find the boot of the old leader; run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`. Lines before it are the last ones of the previous boot.

Seen in the lab:

- pgha: `leader-killed`, `network-partition` (suite `pgha-20261118T225346Z-e47dc14`)
