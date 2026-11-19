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
   second configuration (for example rolling patching). (Amended 2026-11-16:
   the first slice closed with the `CDB19` pair only; `CDB26` is not
   monitored and is deferred.)
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
   `packs/oracledb-dg/` holds `sql_query` statements for transport and
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
   paragraph (the trials recorded here; all three passed again in the suite of decision 8,
   amended 2026-11-16). Listener stopped has run as two passing trials. Monitoring
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
   expired, a failed RMAN job (`backup-failed`), and a stale RMAN backup
   (`backup-stale`, long, outside the suite).
   Amended 2026-11-16: all but `backup-stale` run as one suite
   (`lab/oracle/scenarios/suite.txt`, control last); the suite
   `oracle-20261116T190454Z-971f256` (commit `971f256`) passed 12 of 12 on
   2026-11-16, and `backup-stale` (`lab/oracle/scenarios/long.txt`) passed in
   a single run on 2026-11-15, both in `lab/oracle/results/runs.jsonl`. The
   trial records below predate the suite.
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
   Blocking session (scenario `blocking-session`, one passing trial started
   2026-11-15T01:39:52Z, Oracle 19.33; an earlier trial and control run of the
   same day ran on earlier versions of the script and their records were not
   kept): in `PDB19` one session held a row lock and a second waited for it
   (`enq: TX - row lock contention`, class Application, on the scenario's own
   table, read in `V$SESSION` before the alert was waited for).
   `OracleBlockedSessions` was delivered 124.8 s after the start, 42.1 s after
   the `startsAt` of the alert (77 s after the waiter was seen blocked), and
   resolved 86.3 s after the revert began (the unit stopped and the user
   dropped). oracledbreceiver (contrib v0.164.0) has no metric for a lock wait
   (`oracledb.lock.time` is a cumulative statistic, off by default; the
   blocking attributes are on a disabled log event; `metadata.yaml` read
   2026-11-15 UTC), so one primary-only `sql_query`,
   `oracledb.lock.oldest_wait_age` (`WAIT_TIME_MICRO` of the longest waiter
   with a blocker, class Application), reads it from the CDB root. The 19c
   Database Reference for `V$SESSION`
   (<https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-SESSION.html>,
   read 2026-11-15 UTC) gives `WAIT_TIME_MICRO` as the time spent in the
   current wait while the session is waiting and marks `SECONDS_IN_WAIT`
   deprecated in its favour. In the trial the series held 10 of 10 expected
   samples from the start of the unit to the release, the first positive one
   4.8 s (4 s after the waiter was seen blocked) and the maximum 139.8 s, with
   0 in the 120 s before the start and from 45 s after the release; the 3 s timeouts of the
   enqueue wait did not reset it. `V$SESSION` at the root lists the sessions
   of `PDB19` for `C##OBENHUB_DG` (`SYSDG`, through the Collector in the
   trial) and for `C##OBENHUB_MON` (a manual probe on 2026-11-15 UTC, not a
   recorded run), without a `CONTAINER_DATA` change. The lag stayed 0 s, the
   Collector logged no error-level line and no other alert fired.
   Archiver stuck (scenario `archiver-stuck`, one passing trial started
   2026-11-15T04:02:36Z, Oracle 19.33; earlier draft trials of other versions
   of the script were not kept): `DB_RECOVERY_FILE_DEST_SIZE` of the `CDB19`
   primary was lowered with `SCOPE=MEMORY` from 21474836480 to 3998220288
   bytes, 90% of 4442524160 (8429985280 used - 1470878720 reclaimable -
   2516582400 bytes of flashback logs), and log switches were run. Seven
   seconds after the switch unit started `V$ARCHIVE_DEST` destination 1 read
   `ERROR` with ORA-19809 and two online groups waited for archiving; the
   alert log held ORA-19809 twice, ORA-19804, ORA-19815 and ORA-16038 once
   each. The third log switch waited in `switch logfile command` (two of six
   had returned). Oracle deleted nothing: the space used, the reclaimable space
   and the flashback logs (12 files, 2516582400 bytes) were unchanged for the
   whole fault of 147 s, although 1470878720 bytes counted as reclaimable; that
   the limit was below what could be freed is the reading of ORA-19804, not
   checked in the documentation. The signal is the local destination itself:
   the `oracledb.archive_dest.*` query of the Data Guard pack listed remote
   destinations only, and now also lists `TYPE LOCAL`. `GAP_STATUS` is empty
   for a local row, so it reads as no gap, and at rest both databases show
   their local destination `VALID` (read 2026-11-15 UTC; the standby's
   `TYPE UNKNOWN` destination 32 stays out). `OracleRedoDestinationInvalid`
   (existing rule, reworded for "archive destination") was delivered 110.6 s
   after the start for destination 1 (named in the notification; the
   receiver's series read `ERROR` = 0 and `V$ARCHIVE_DEST_STATUS` read
   `LOCAL ERROR`); its `startsAt` was 61 s after the archiver was seen stuck
   and the delivery 42.1 s after that. It resolved 67.4 s after the revert
   began; ARCH resumed 1 s after the limit was restored and
   `ALTER SYSTEM ARCHIVE LOG ALL` was not needed. `OracleRecoveryAreaFull` was
   not delivered: the fault lasted 147 s and the rule holds for 10 minutes
   ((usage - reclaimable) / limit read 1.741 at the alert; the receiver of the
   oracledb-backup pack collects every 60 s, sample times read 2026-11-15, and
   showed the lowered limit). While the archiver was stuck a SYSDBA `SELECT`
   and `dgmgrl show configuration` (`SUCCESS`) worked, the `sql_query`
   heartbeat of both targets kept 10 samples against 9 expected with no gap
   above 15 s, the Collector logged no error-level line, and a fresh login as
   `C##OBENHUB_MON` failed with ORA-00257. The lag stayed 0 s. After the
   restore a log switch succeeded, the standby reported no gap and
   `FLASHBACK_ON` stayed `YES`. Before the run the broker showed the health
   condition Stuck Archiver as `NO` and no Oracle error condition (read
   2026-11-15; a stuck archiver could otherwise be a failover trigger);
   fast-start failover did not act.
   Fast-start failover (scenario `fsfo-failover`, eight trials on
   2026-11-15, Oracle 19.33, all rows in `runs.jsonl`; trials 1, 3 and 4
   failed on alerts that were not yet allowed, the evidence row is the eighth,
   started 17:01:13Z). The broker showed fast-start failover enabled in
   zero-data-loss mode, MaxAvailability, threshold 30 s, active target
   `cdb19_stby`, Shutdown Primary TRUE, Auto-reinstate TRUE (`dgmgrl`,
   asserted before every run). `SHUTDOWN ABORT` of `CDB19` (abort at +0):
   `CDB19_STBY` was seen `PRIMARY` and open read write at +40 s (35 to 40 s
   across the eight trials, polled every 2 s), the observer's log read
   "Failover succeeded" at +47 s, and the `OraclePrimaryChanged` notification
   was delivered 103.5 s after the start of the injection (the seven other
   trials: 93.7 to 106.0 s). The sql_query pack read the role again on every
   collection: `CDB19_STBY` flag 1, no sample of `CDB19` for the whole outage;
   the `oracledb` receiver's series of `CDB19` kept the labels
   `PRIMARY`/`READ WRITE` and its newest sample was 118 s old (no new sample
   while the instance was down or mounted; 101 times ORA-01034 and ORA-27101,
   13 ORA-01033 in the Collector's journal). After the switchback its labels
   were correct (`PRIMARY`/`READ WRITE`, newest sample 43 s old) and the
   Collector was not restarted. That is no test of the stale-label gap of the
   2026-11-13 record: the receiver started as primary and the pair ended with
   the same roles. The revert mounted `CDB19` at +151 s (the heartbeat of
   `CDB19` was absent from the abort until then: first sample 139 to 151 s
   after the abort across the eight trials). The observer reinstated it by
   itself in every trial (the manual command never ran): "Issuing REINSTATE"
   17 s after the mount, "Successfully reinstated" at +221 s, 70 s after the
   mount; `CDB19` was seen as a physical standby at +188 s, `switchover to
   cdb19` ran at +228 s, roles were restored at +299 s and the pair was
   healthy at +327 s; the run took 7 min 56 s. The switchover must be run
   logged on as `C##OBENHUB_DG` AS SYSDG: with operating-system authentication
   the broker refuses it with ORA-01017 (as on 2026-11-13, and in the first
   trial here). A mounted old primary reports role `PRIMARY` until it is
   reinstated (about 50 s): `OracleMultiplePrimaries` fired for it in all five
   trials that read the role only, so the rule (and `OracleNoPrimary`) now
   also requires `oracledb.database.open` 1, a separate metric of the same
   query, and it stayed quiet in the last three trials. In the eighth trial
   `OracleProtectionDegraded` and `OracleFastStartFailoverNotSynchronized`
   fired for the new primary and resolved, and `OracleProtectionDegraded` for
   `CDB19` fired after the switchback (also in trial 4, so 2 of 8);
   `OracleRedoGap` for `CDB19_STBY` (destination 2, "RESOLVABLE GAP") fired in
   2 of the 8 trials, not in the eighth. `OracleNoPrimary`, `OracleTargetAbsent`
   (the heartbeat gap is shorter than the 3 minutes the rule needs; the
   margin is about 30 s, so a detection slower than about 130 s would fail the
   run on it) and the standby rules stayed quiet. `OraclePrimaryChanged` fired
   at the failover (17:02:57Z) and resolved once, at 17:08:42Z, 150 s after the
   roles were restored (17:06:12Z; 313.4 s from the start of the revert); in
   some other trials it resolved 3 minutes after the failover and fired again
   at the switchback. A transient user timer on the box
   (`obenhub-fsfo-restore`, 4650 s, computed from the scenario's own bounds) is
   armed before the abort to run `lab/oracle/scripts/restore-roles.sh` if the
   scenario's shell dies, and was cancelled after the revert; it does not
   survive a reboot of the box.
9. **Backups.** RMAN with a recovery window, archived logs deleted after
   backup (and, on the Data Guard primaries, after apply on the standby);
   the backup state comes from `V$RMAN_BACKUP_JOB_DETAILS` through
   `sql_query`, as pgBackRest's does for PostgreSQL (ADR 0007).

## Consequences

- The Oracle lab cannot be rebuilt from the repository alone; a reader
  without these VMs gets the monitoring parts, not the databases. Oracle
  Database Free in a container stays a possible later variant for readers.
- Queries copied from `oracle/oracle-db-appdev-monitoring` (MIT and UPL-1.0)
  or from dbsight record source, licence and commit (ADR 0004).
- Pack views stay unused even though these instances could answer them; a
  scenario that needs ASH or AWR is a separate decision.
