# ADR 0008: Oracle lab - scope, topology and first slice

- Status: Proposed
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
stale after a switchover; `oracledb_up` stays 1 with a stopped listener
because pooled sessions survive; the receiver's query samples cost about
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
   follows the receiver README and is tested on each major version; whether
   `CONTAINER_DATA` works for this user on 19c is unverified. How the
   mounted standby is read (a `SYSDG` connection, or only primary-side
   views such as `V$ARCHIVE_DEST_STATUS`) is decided in the first slice and
   recorded here.
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
7. **Availability from outside the pool.** Listener and service
   availability is probed with a new connection per check, not inferred from
   the receiver's `up` metric.
8. **First scenarios**, each with a control run: archiver stuck (recovery area
   limit lowered under the archive volume), transport cut and apply stopped
   (lag and gap alerts), fast-start failover after the primary is aborted
   (role read again, failover alert), listener stopped, processes exhausted
   (ORA-00020), blocking session, tablespace full, monitoring password
   expired, and a stale RMAN backup.
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
