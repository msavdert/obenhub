# oracledbreceiver: role and open mode refreshed on every scrape (fix evidence)

Date of the runs: 2026-11-21, all times UTC. Follow-up to
[role-staleness-2026-11-13](../role-staleness-2026-11-13/README.md), which showed that contrib
`oracledbreceiver` reads `oracle.db.role` and `oracle.db.open_mode` once at start. This directory
keeps the timelines, the broker state before and after, the test Collector configurations and the
build manifests. The exported JSONL was not kept; the timelines are its collapsed form (one line per
run of identical `role | open_mode | version`, `xN` is the number of batches).

## Claim tested

Commit `638c8a8996a14b65f4b7cd1ef4bbba9816e9613b` ("[receiver/oracledb] Refresh database role and
open mode on every scrape") on the owner's fork, branch `receiver-oracledb-role-refresh`, parent
contrib `main` at `8f589e911d`, makes the receiver report the current role and open mode instead of
the values read at start. Not yet upstream: no issue or pull request exists for it at the time of
writing. The change is split: PR1 is the per-scrape refresh (this commit); PR2, a later retry of a
failed start-time detection, is not implemented.

An earlier run on commit `56dcc17b11` was superseded by this one and is not kept.

## Environment

- Databases: Oracle Database 19c, `19.0.0.0.0` as the receivers report it (`SUMMARY.txt`). CDB19 on
  ora-au-lab 10.0.0.12 and CDB19_STBY on ora-dg-stby 10.0.0.14, broker configuration `dgconfig`,
  MaxAvailability, Fast-Start Failover Enabled in Zero Data Loss Mode, observer
  `ora-dg-obs.lab.local1` (`broker-before.txt`).
- Two Collector builds with `ocb` (`v0.165.1-0.20261119222305-0c7a74cd0a4a`, go 1.27.4), identical
  except for the receiver source, taken in `replace` from a local worktree
  (`ocb-manifest-control.yaml`, `ocb-manifest-patched.yaml`; the file exporter is v0.165.1):
  control = contrib `main` at `8f589e911d` (`oralab-control`, sha256 prefix `5bdad4132ff3f3c9`);
  patched = the branch at `638c8a8996` (`oralab-patched`, sha256 prefix `bd2c5d6cf40690dd`).
- Configuration `otelcol-b1.yaml` (B1) and `otelcol-b2.yaml` (B2): collection interval 10 s, one file
  exporter per receiver. The control configurations differ only in the output paths. Passwords come
  from the environment (`ORA_MON_PASSWORD`, `ORA_DG_PASSWORD`); none is in the files.
  `primary` and `standby` log in as the plain user `C##OBENHUB_MON`; `primary_sysdg` and
  `standby_sysdg` as `C##OBENHUB_DG` with `DBA PRIVILEGE=SYSDG`, which can read a mounted standby.
- Each scenario ran the control and the patched binary side by side against the same databases.

## B1: switchover there and back (four receivers)

Switchover CDB19 -> cdb19_stby requested 05:19:32, command returned 05:20:19; after 150 s the
switchover back requested 05:22:50, returned 05:23:41; 150 s wait, done 05:26:12
(`timeline-b1.log`). Collapsed timelines in `B1-timelines.txt`.

Control: no attribute ever changes.

| Receiver | Control, whole run (05:18:49-05:26:19) |
| --- | --- |
| `primary` | PRIMARY / READ WRITE, 26 batches |
| `primary_sysdg` | PRIMARY / READ WRITE, 45 batches (CDB19 was a mounted standby 05:20-05:23) |
| `standby_sysdg` | PHYSICAL STANDBY / MOUNTED, 45 batches (CDB19_STBY was primary 05:20-05:23) |
| `standby` | no role, open mode or version, 20 batches 05:19:49-05:22:59 |

Patched:

| Receiver | Timeline (UTC) |
| --- | --- |
| `primary_sysdg` | 05:18:49-05:19:29 PRIMARY / READ WRITE x5; 05:19:39 PHYSICAL STANDBY / CLOSED BY SWITCHOVER x1; 05:19:59 no role, no open mode, version present x1; 05:20:09-05:22:59 PHYSICAL STANDBY / MOUNTED x18; 05:23:09-05:26:19 PRIMARY / READ WRITE x20 |
| `standby_sysdg` | 05:18:49-05:19:29 PHYSICAL STANDBY / MOUNTED x5; 05:19:39 PRIMARY / MOUNTED x1; 05:19:49-05:22:49 PRIMARY / READ WRITE x19; 05:22:59 PHYSICAL STANDBY / CLOSED BY SWITCHOVER x1; 05:23:19 no role, no open mode, version present x1; 05:23:29-05:26:19 PHYSICAL STANDBY / MOUNTED x18 |
| `primary` (plain user) | 05:18:49-05:19:29 PRIMARY / READ WRITE x5; 05:19:39 PHYSICAL STANDBY / CLOSED BY SWITCHOVER x1; then no batch until 05:23:10-05:26:19 PRIMARY / READ WRITE x20 |
| `standby` (plain user) | no role, open mode or version, x20 05:19:49-05:22:59, same as control |

After each switchover the patched `*_sysdg` receivers follow the database within the 10 s interval.
Values seen only in transition: `CLOSED BY SWITCHOVER` (one batch per receiver per switchover),
`PRIMARY / MOUNTED` (one batch), and one batch with the role and open mode absent but the version
present. The timelines do not say what caused the single batch without role; the cause was not
investigated here.

## B2: plain user, license-free (SNAPSHOT STANDBY, no Active Data Guard)

A plain-user standby is unreachable in the mounted state, so B1 cannot show a stale value for it.
B2 gets a plain-user receiver connected while the standby is open without Active Data Guard: the
broker converts CDB19_STBY to a snapshot standby, which opens READ WRITE. Steps (`timeline-b2.log`,
`otelcol-b2.yaml`): FSFO disabled 05:26:28; snapshot standby open 05:26:41; receiver `standby`
(`C##OBENHUB_MON` -> CDB19_STBY) started about 05:26:4x; 75 s later CONVERT TO PHYSICAL STANDBY,
mounted 05:29:45; switchover to cdb19_stby, primary READ WRITE logged 05:30:49; 150 s wait;
switchover back, CDB19 primary logged 05:34:08; FSFO re-enabled, broker state SUCCESS at 05:37:29
(`broker-after.txt`).

| Build | `standby` receiver, plain user (`B2-timelines.txt`) |
| --- | --- |
| control | 05:26:48-05:33:18 SNAPSHOT STANDBY / READ WRITE x30, unchanged through the conversion to physical standby and the time CDB19_STBY was primary |
| patched | 05:26:48-05:28:28 SNAPSHOT STANDBY / READ WRITE x11; no batch 05:28:28-05:30:19; 05:30:19-05:33:18 PRIMARY / READ WRITE x19 |

The control keeps reporting SNAPSHOT STANDBY while the database is PRIMARY / READ WRITE at the end
of the switchover; the patched build reports PRIMARY / READ WRITE.

## What PR1 deliberately does not fix

A receiver whose start-time detection failed still emits no version, role or open mode. In B1 the
plain-user `standby` receiver started against a mounted standby (login refused) and stays without them
in both builds, also after CDB19_STBY became primary and open at 05:20:20. The
retry of a failed detection is the planned PR2.

## Broker and FSFO state

`broker-before.txt` (05:18:42) and `broker-after.txt` (05:37:29) are identical apart from the
timestamp and the "status updated" age: cdb19 Primary, cdb19_stby Physical standby, SUCCESS,
Fast-Start Failover Enabled in Zero Data Loss Mode, threshold 30 s, target cdb19_stby, observer
`ora-dg-obs.lab.local1`; `v$database` PRIMARY / READ WRITE and PHYSICAL STANDBY / MOUNTED. FSFO was
active during B1 (the switchovers were not refused) and disabled only for B2, 05:26:28 until
re-enabled before 05:37:29.

## Limits of this evidence

- One pair, one run per scenario; no repetition.
- The `*_sysdg` receivers are a test construct (SYSDG login); the lab's configuration uses the plain
  user.
- The collapsed timelines show attributes only; scrape errors and Collector logs were not kept.
- The patched receiver was not exercised with a database that fails the role query after a
  successful start.
