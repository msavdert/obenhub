# ADR 0008: Oracle lab - scope, topology and first slice

- Status: Accepted
- Date: 2026-11-13

## Context

ADR 0001 puts Oracle second, after PostgreSQL works end to end; the four
PostgreSQL suites are on `main` and the owner moved Oracle up on 2026-11-13
(`docs/roadmap.md`). ADR 0003 already chose the engine receiver plus SQL query
packs for Oracle; this ADR decides where the Oracle lab runs and what its
first slice covers.

What exists (read-only survey of 2026-11-13, all Enterprise Edition):

| VM | Address | Databases |
| --- | --- | --- |
| `ora-au-lab` | 10.0.0.12 | `CDB26` (23.26.3, PDB `PDB26`, no standby), `CDB19` (19.33, PDB `PDB19`), `CDB19B` (19.32, PDB `PDB19B`) |
| `ora-dg-stby` | 10.0.0.14 | `CDB19_STBY`, `CDB19B_STBY`, both mounted, real-time apply |
| `ora-dg-obs` | 10.0.0.15 | no database; two fast-start failover observers |

Each 19c pair is its own Data Guard broker configuration in MaxAvailability
with fast-start failover. No VM had a monitoring user, a Collector or an RMAN
backup; `CDB26` ran out of recovery area on about 2026-11-07 (fixed
2026-11-13: RMAN backups with a 7-day recovery window). The owner gave these
VMs to the project on 2026-11-13; their Oracle installation is outside the
repository (Oracle downloads need an account).

Upstream, read 2026-11-13 on contrib `main` at its v0.165.1 dependencies:
`oracledbreceiver` metrics are alpha (25 of 135 on by default), its events
(query samples, top queries) are development; it supports CDB/PDB with
`CDB_*` and `V$CON_*` grants; its driver `sijms/go-ora/v2` v2.9.0 is MIT and
needs no Oracle client. `db.system.name` has `oracle.db` (development). The
labs pin Collector contrib 0.164.0; which oracledb changes lie between 0.164.0
and 0.165.1 is unchecked.

From the private predecessor dbsight (Oracle in containers, never
on these VMs): the receiver reads role and open mode once at start, so they go
stale after a switchover; its `oracledb_up` stayed 1 with a stopped
listener (scenario ORA-LSNR-01; the record does not say which component
produced that metric and marks the connection reuse as an assumption); the receiver's query samples cost about
300 ms CPU per run against under 1 ms for a `V$SESSION` query through the
`sql_query` receiver; no Data Guard metric was ever built.

## Decision

1. **Lab.** `lab/oracle` runs on the three VMs above, not in containers. The
   repository provisions what monitoring needs (monitoring user, Collectors,
   scenarios, RMAN jobs), not the Oracle software. The lab README states the
   VMs, versions and Data Guard layout as prerequisites.
2. **Collectors.** The `lab/pgha` pattern (ADR 0005 decision 1): one
   Collector per VM for host metrics, journald and the Oracle alert logs, all
   pushing over mutual TLS to a gateway and the backend on this repository's
   host. The database receivers (`oracledb`, `sql_query`) run once, on
   `ora-dg-obs`: it holds no database, it is the observer's vantage point, and
   it keeps reporting when either database VM is down, which the failover
   scenarios need.
3. **First slice: the `CDB19` Data Guard pair.** Then `CDB26` as a second
   major version in the same lab. `CDB19B` stays out until a scenario needs a
   second configuration (for example rolling patching).
4. **Monitoring user.** One common user per CDB with single-view grants, no
   `SELECT_CATALOG_ROLE` and no `SELECT ANY`, with `CONTAINER_DATA` for the
   PDB metrics, and a profile whose password never expires (an expired
   monitoring password is a known incident, ORA-28001). The grant list
   follows the receiver README and is tested on each major version. On
   19.33 `CONTAINER_DATA=ALL` works for this user: from the root it sees
   all three containers in `V$CON_SYSSTAT` (lab, 2026-11-13).
   The mounted standby is read with a second common user that holds only
   the `SYSDG` administrative privilege and is used by `sql_query` alone, on
   both databases of a pair (owner decision, 2026-11-13). The monitoring
   user above stays the only user of `oracledb` and reads the open primary.
   Reasons, from the `CDB19` pair on 2026-11-13: a mounted database admits
   only administrative connections, and on 19.33 `V$DATAGUARD_STATS` is
   empty on the primary, so apply lag exists only on the standby. Contrib
   v0.164.0 `oracledbreceiver` has no field for an administrative
   connection; the go-ora v2.9.0 data source takes `DBA PRIVILEGE=SYSDG`,
   which `sql_query` passes through unchanged. A `SYSDG` login is checked
   against the password file, so the standby's file must match the
   primary's. In the lab the first `SYSDG` login on the standby failed until
   the primary's file was copied; a later password change on the primary
   reached the standby's file through redo without a copy. The provision
   script therefore copies the file only when the two differ. `SYSDG` covers more
   than reading (it can stop apply or fail over); the lab accepts that for
   this user only, with its password from `.env`, never in the
   repository.
5. **Data Guard telemetry.** No receiver reads it, so a pack
   `lab/packs/oracledb-dg/` holds `sql_query` statements for transport and
   apply lag, archive gap, apply state, protection mode, role, open mode
   and fast-start failover state, read on every collection (not once at
   start). Alerts follow ADR 0006.
6. **Diagnostics and Tuning Packs.** Every instance has
   `CONTROL_MANAGEMENT_PACK_ACCESS=DIAGNOSTIC+TUNING`, which enables the
   packs but licenses nothing. The lab reads no pack view
   (`V$ACTIVE_SESSION_HISTORY`, `DBA_HIST_*`, AWR), so what it shows works
   without the packs. Session sampling, when added, reads `V$SESSION`; that
   neither pack lists `V$SESSION` is a reading of the Licensing Information
   User Manual by omission, not a statement in it.
7. **Availability from outside the pool.** The intent is to probe listener
   availability with a new connection per check rather than through pooled
   sessions, which can survive a stopped listener. What runs (amended
   2026-11-14): the `tcpcheck` receiver (alpha, registered as `tcp_check` in
   contrib v0.164.0) on the observer's Collector makes a TCP connect to both
   listeners every 15s (`tcpcheck.status`, alert `OracleListenerUnreachable`),
   so the intent is met for the listener only, with no login; the failing
   path ran in scenario `listener-stopped` (run started 2026-11-14T17:57:45Z,
   `lab/oracle/results/runs.jsonl`): firing at +73 s, delivered at +115 s;
   startsAt-to-delivery 42 s for every alert on the stack, cause not yet
   found; resolved 54 s after the start. Recorded gap: none of `sqlquery`, `oracledb` and `tcpcheck`
   at v0.164.0 does a login per check; other components were not surveyed.
   `sqlqueryreceiver` builds a pool (`receiver.go:56`, `internal.NewPool`
   with `max_open_conn`) and `oracledbreceiver` holds a `*sql.DB`
   (`scraper.go`, field `db`); `oracledbreceiver/metadata.yaml` lists no
   up-style metric (searched, not read line by line). A listener that
   accepts connections while an account is expired or sessions are exhausted
   therefore looks healthy to the probe. Conversely, a pooled session does
   keep the database metrics flowing with the listener stopped: during the
   166 s outage of that run the `oracledb` receiver (30 s) delivered 5 of 5
   expected samples of `oracledb.sessions.usage`, `oracledb.processes.usage`
   and `oracledb.cpu_time`, the `sql_query` heartbeat (15 s) 11 of 11, and the
   Collector logged only the 11 error-level lines of the probe, all
   `connection refused` (the count covers error level only). Only
   the new-connection probe saw the outage (two passing runs, 17:57:45Z and
   18:16:39Z, Oracle 19.33, existing sessions only). No custom probe code is written; no upstream proposal
   is written yet; its lab evidence is the three scenarios in this
   paragraph (no suite yet). Listener stopped has run as two passing trials. Monitoring
   password expired (scenario `password-expired`, one passing trial started
   2026-11-14T18:44:44Z, Oracle 19.33) shows the same for an account: with
   `C##OBENHUB_MON` expired for 169 s the `oracledb` receiver kept its one
   pooled session (V$SESSION logon age grew with the clock), delivered 5 of 5
   expected samples and logged no error-level line, while a fresh login got
   ORA-28001. The alert `OracleMonitoringAccountNotOpen` reads the account
   state through the other account's session (`queries-primary.yaml`).
   Processes exhausted (scenario `processes-exhausted`, one passing trial
   started 2026-11-14T20:16:57Z, Oracle 19.33) shows the same for the
   instance: 252 holder sessions were started against PROCESSES (320) (242
   client processes still alive at the end of the ramp, an approximate
   count); for 175 s fresh logins got ORA-00020 on a bequeath connection and
   ORA-12537 through the listener. In that window the `oracledb` receiver
   delivered 6 samples of each of its series (usage maximum 319 over 6
   samples), the `sql_query` heartbeat 12, `tcpcheck.status` 12 samples with
   minimum and maximum 1, and the Collector logged no error-level line. The
   alert `OracleProcessesSaturation` fired 125 s after the ramp ended (first
   delivery of either tier; the critical tier was delivered too, its time is
   not recorded).
8. **First scenarios**, each with a control run: archiver stuck (recovery area
   limit lowered under the archive volume), transport cut and apply stopped
   (lag and gap alerts), fast-start failover after the primary is aborted
   (role read again, failover alert), listener stopped, processes exhausted
   (ORA-00020), blocking session, tablespace full, monitoring password
   expired, and a stale RMAN backup.
   Tablespace full (scenario `tablespace-full`, one passing trial started
   2026-11-14T21:53:39Z, Oracle 19.33; three earlier trials of the same day ran
   on earlier versions of the script and their records were not kept): a 20 MB
   tablespace without autoextend in `PDB19` was filled until ORA-01653 (9544
   rows of 2 KB, 2 s); `OracleTablespaceUsageHigh` was delivered as critical
   122.8 s after the start (the alert's `startsAt` 21:55:00Z), a fresh insert
   from a new session failed with ORA-01653, and the alert resolved 57.0 s
   after the revert began (the drop). The signal is the receiver's own
   `oracledb.tablespace_size.usage` and `.limit` (enabled by default,
   `metadata.yaml` at contrib v0.164.0; the limit is `TABLESPACE_SIZE` of
   `DBA_TABLESPACE_USAGE_METRICS`, the autoextend maximum, read in
   `scraper.go` at that tag), so no `sql_query` was added. One lab finding: on
   a CDB-root connection the receiver emits one data point per container, but
   `oracle.db.pdb` is opt-in per metric, so without it the root's and the
   PDB's `SYSTEM` were averaged into one series (read 2026-11-14); the lab
   Collector enables it for these two metrics. The view read 1.0 (2560 of 2560
   blocks) when the table segment held 19922944 bytes, 95% of the file: it
   counts the 1 MB Oracle reserves in a new datafile as used (an interactive
   sqlplus observation of 2026-11-14, not a recorded measurement: 128 of 2560
   blocks, 0.05, on an empty one). `STANDBY_FILE_MANAGEMENT` is `AUTO` on both
   databases; the create and the drop reached the standby, the lag stayed 0 s
   and no other alert fired.
9. **Backups.** RMAN with a recovery window, archived logs deleted after
   backup (and, on the Data Guard primaries, after apply on the standby);
   the backup state comes from `V$RMAN_BACKUP_JOB_DETAILS` through
   `sql_query`, as pgBackRest's does for PostgreSQL (ADR 0007).

## Consequences

- The Oracle lab cannot be rebuilt from the repository alone; a reader
  without these VMs gets the monitoring parts, not the databases. Oracle
  Database Free in a container stays a possible later variant for readers.
- The Collector version is checked against the oracledb changelog between
  0.164.0 and the pinned version before the first slice merges.
- Queries copied from `oracle/oracle-db-appdev-monitoring` (MIT and UPL-1.0)
  or from dbsight record source, licence and commit (ADR 0004).
- Pack views stay unused even though these instances could answer them; a
  scenario that needs ASH or AWR is a separate decision.
