# lab/oracle

The Oracle lab of [ADR 0008](../../docs/adr/0008-oracle-lab-scope.md). What
runs is the database side of the first slice, the `CDB19` Data Guard pair,
its Collector configuration, the backend the Collector pushes to and the fault
scenarios in `scenarios/` (below). The full suite
`oracle-20261116T190454Z-971f256` (commit `971f256`) passed 12 of 12 on
2026-11-16; its records are in [results/runs.jsonl](results/runs.jsonl).

## Prerequisites

The databases are not built from this repository (ADR 0008, Consequences).
The scripts expect, as `pair.sh` names them:

- ssh aliases `ora-au-lab`, `ora-dg-stby`, `ora-dg-obs` from this box, a user
  with passwordless sudo, the `oracle` OS user owning the Oracle homes;
- `CDB19` (19.33, open, primary) on `ora-au-lab` and `CDB19_STBY` (mounted,
  physical standby) on `ora-dg-stby`, one broker configuration with
  fast-start failover, SIDs listed in `/etc/oratab`, the listeners on port
  1521 under the `lab.local` names;
- a 19c Oracle home on `ora-dg-obs` (the observers'), used to check logins;
- Docker on this box for the backend, and `ora-dg-obs` able to reach this box
  at `10.0.0.11` (assumption: the lab LAN address; `gateway.sh` holds it).

What the repository sets up, in this order, before the scenarios:

1. `scripts/provision.sh` (below): the common users `C##OBENHUB_MON` and
   `C##OBENHUB_DG` on `CDB19` and the gitignored `lab/oracle/.env` with
   `ORA_MON_PASSWORD` and `ORA_DG_PASSWORD` (random values from
   `lab/scripts/gen-env.sh`, not 1Password references);
2. `mise run lab:oracle:mon:up`, the backend and the PKI;
3. `mise run lab:oracle:collector`, otelcol-contrib 0.164.0 on the three VMs
   (`OTELCOL_VERSION` in `lab/pgha/versions.sh`);
4. `mise run lab:oracle:rman`, the RMAN jobs the backup alerts read.

## Provision

`scripts/provision.sh` creates the monitoring profile and the two common
users on the primary (ADR 0008 decision 4), copies the primary's password
file to the standby when the two differ, and checks every login from
`ora-dg-obs`. It creates `.env` (gitignored) with the passwords on first use.
A rerun creates nothing new and keeps the passwords (it states the profile
limits and grants again); `--reset-passwords` sets the passwords from `.env`
again.

## Collector

One otelcol-contrib per VM (ADR 0008 decision 2), each started with two
configuration files that the Collector merges:
[files/otelcol-host.yaml](files/otelcol-host.yaml) on all three (host metrics,
the journal of `oracle-db` and the Collector itself, the kernel ring buffer,
the exporter to the gateway over mutual TLS, self-metrics for
`CollectorAbsent`) and one per-VM file:

| VM | Per-VM file | Adds |
| --- | --- | --- |
| `ora-au-lab` | [otelcol-db.yaml](files/otelcol-db.yaml) | alert log of `CDB19` |
| `ora-dg-stby` | [otelcol-db.yaml](files/otelcol-db.yaml) | alert log of `CDB19_STBY` |
| `ora-dg-obs` | [otelcol-obs.yaml](files/otelcol-obs.yaml) | the database receivers (`oracledb` on the primary, the [oracledb-dg pack](../packs/oracledb-dg) on both databases) and the journal of the `dg-observer@cdb19` and `@cdb19b` units |

Only the `CDB19` pair's alert logs are read; `CDB26`, `CDB19B` and
`CDB19B_STBY` are not. An alert log entry (timestamp line plus message lines)
becomes one log record with the entry's own timestamp, the first `ORA-` code
in `db.response.status_code` (assumption: the fitting semantic-conventions
name, not checked against the registry) and the resource attributes
`oracledb.database.unique_name`, `service.instance.id` (both the
`db_unique_name`) and `host.name`. The code is padded to five digits
(the log writes both `ORA-3136` and `ORA-00313`, so `ORA-3136` is stored as
`ORA-03136`), and the severity is `ERROR` for an entry with a code, `WARN` for
the client-event codes 00060, 00028, 01013, 02396 and 03136, and `INFO`
without a code (rules copied from the predecessor project's alert log
receiver, source in the YAML). The record starts at the end of the file, so
history is not sent. The observer unit is a oneshot whose journal holds only
its start and stop lines; the observer's own log file (`observer.log`) is not
read, so no observer events are collected. The database Collector needs `OBENHUB_NODE`,
`OBENHUB_DB_UNIQUE_NAME`, `OBENHUB_ALERT_LOG` and
`OBENHUB_GATEWAY_ENDPOINT`; the observer one also `ORA_MON_PASSWORD` and
`ORA_DG_PASSWORD` (the first 30 characters of the `.env` values); client
certificates sit under `/etc/otelcol-contrib/tls`. All of it is written by
the script below, in a root-only environment file.

```sh
mise run lab:oracle:collector                  # scripts/collector.sh, all three VMs, from this box over ssh
lab/oracle/scripts/collector.sh ora-dg-stby    # one VM
```

The script installs the otelcol-contrib `.rpm` of `OTELCOL_VERSION`
(`lab/pgha/versions.sh`, the pin all labs share) from the
opentelemetry-collector-releases release after checking its `.sha256` file,
then writes the two configuration files, the client certificate of that VM
from `pki/`, the environment file (read by systemd through a drop-in, which
also sets `SupplementaryGroups=systemd-journal` and the two `--config`
arguments) and, on the observer, the pack's `queries.yaml`. On a database VM
it also grants the service user read access to the alert log as POSIX ACLs
(`setfacl`): `--x` on the `diag` directories down to the instance, `r-x` on
`trace/`, `r--` on the file. Group `oinstall` is not used, because the `diag`
and `rdbms` directories are group-writable. The oracle-owned modes do not
change (`getfacl` shows the entries; remove them with `setfacl -x
u:otelcol-contrib`). A replaced alert log file loses its ACL, and the script re-applies it on
every run. Check with `ssh ora-au-lab sudo getfacl -p
/u01/app/oracle/diag/rdbms/cdb19/CDB19/trace/alert_CDB19.log` (an
`user:otelcol-contrib:r--` line); `getfacl` is the reliable check. The
Collector logs a permission-denied error for the file in its own journal
once when it finds the file unreadable (and again after a restart), not on
every poll; the `otelcol-contrib` journald receiver sends it to
VictoriaLogs, where the LogsQL query `service.name:host
service.instance.id:ora-au-lab journald._SYSTEMD_UNIT:otelcol-contrib.service
"permission denied"` with a `_time` filter covering the replacement finds it. It restarts a service only when the package or a file changed
and fails unless the service stays active. It needs `.env` (from
`provision.sh`), `pki/` (from `lab:oracle:mon:up` or `lab:oracle:pki`) and
`setfacl` on the database VMs. The script stops at the first VM that
fails, and it checks the certificates of all three VMs even when you name one.

On 2026-11-13 the observer configuration ran in the
`otel/opentelemetry-collector-contrib:0.164.0` container on this box with
the exporter replaced by `debug` and `file`: the receiver's 25 default
metrics from `CDB19` and every pack metric that applies to each role (lag,
apply and gap from the standby, the redo destination from the primary)
arrived. The first rpm install on `ora-dg-obs` (Oracle Linux 9.8) the same
day showed only the two `CDB_PROCEDURES` fallback warnings the receiver logs
at start. On 2026-11-14 the Collectors on all three VMs were running against
the backend: `system.*` metrics and journal records from each VM,
`otelcol_process_uptime` from each, and alert log records from `CDB19` and
`CDB19_STBY` after an `alter system switch logfile` on the primary. The
`ORA-` parsing was run in the Collector's `debug` output on a copy of 120 kB
of the primary's alert log and on a scratch log: `ORA-3136` came out as
`ORA-03136` with `WARN`, `ORA-1109` as `ORA-01109` and `ORA-00313` with
`ERROR`, an entry without a code with `INFO`. No live `ORA-` entry has been
collected yet.

## Backups

RMAN on the `CDB19` pair (ADR 0008 decision 9), converged by
`mise run lab:oracle:rman` ([scripts/rman.sh](scripts/rman.sh), idempotent; it
prints every change and starts no backup; `mise run lab:oracle:rman-test` runs
its stub tests). The same [rman-backup.sh](files/rman-backup.sh) is on both
database VMs; the script backs up only while `v$database.database_role` is
`PRIMARY` and otherwise logs one line to `rman-logs/<SID>-skipped.log` (kept to
200 lines) and exits 0, so backups follow the primary after a switchover. One
run per SID at a time (`flock`); a second one logs a skip.

The oracle crontabs differ per host and each managed line ends in the tag
`# obenhub: <SID>`: `CDB19` on `ora-au-lab`, `CDB19_STBY` on `ora-dg-stby`.
The hand-made `CDB26` lines on `ora-au-lab` (01:30 and :15) are untouched,
byte for byte; `rman.sh` replaces only lines with its own SID tag and aborts
rather than overwrite a crontab it could not read.

| What | When (VM time, UTC) | Command |
| --- | --- | --- |
| level 0 | Sunday 01:45 | `backup incremental level 0 database plus archivelog delete all input` |
| level 1 | Monday to Saturday 01:45 | the same, `level 1 cumulative` |
| archived logs | every 4 h at :45 | `backup archivelog all not backed up 1 times delete all input` |

Each run ends with `delete obsolete` and an archived log crosscheck. Logs are in
`/home/oracle/rman-logs` (RMAN logs for 30 days).

Settings, per database controlfile (`rman-backup.sh <SID> configure` reads the
current ones and prints `old -> new`): on a primary a retention recovery window
of 7 days, controlfile autobackup on, compressed backupset (`BASIC`, no extra
licence assumed), archivelog deletion policy `APPLIED ON ALL STANDBY BACKED UP
1 TIMES TO DISK`, and block change tracking beside datafile 1 (online; the
standby does not use it); on a standby only the deletion policy `APPLIED ON ALL
STANDBY`. Every database of a Data Guard broker configuration runs the primary
part before each backup while it is the primary (changes go to `<SID>-configure.log`
in the log directory), so a promoted standby is configured by its first
backup run, not by hand; `CDB26` (no broker) is not touched. The demoted side
is not: a former primary keeps the primary deletion policy, never backs up as a
standby, so its archived logs would not become reclaimable. After a role change
run `mise run lab:oracle:rman` (it configures each database for its current
role); `OracleRecoveryAreaFull` is the backstop. A failed block change tracking
enable is logged in `<SID>-configure.log` and does not stop the backup (a
backup without it only reads more); a failed `CONFIGURE` does. `configure` also
sets `control_file_record_keep_time` to 21 days on both pair databases
(`ALTER SYSTEM ... SCOPE=BOTH`, online, also on the mounted standby).

Where the backups are: the recovery area `/u02/fra`, 20 GB on each VM
(`v$recovery_file_dest`). A weekly level 0 and a 7-day recovery window keep two
level 0 chains until the older one ages out, so the on-disk horizon is about 13
to 14 days (restorable to any point in the last 7). The two sites' backups are
not visible to each other (no recovery catalog), so after a switchover the old
primary's backups stay on its own disk.

Observed on 2026-11-14, first level 0 on `CDB19` (`v$rman_backup_job_details`:
8.68 GiB read, 3.05 GiB written compressed, 326 s): the job ends `COMPLETED
WITH WARNINGS` with `RMAN-08120: archived log not deleted, not yet applied by
standby` for the newest logs. That is the normal result of `delete all input`
on a Data Guard primary, so the pack counts that status as completed.

Monitoring: the [oracledb-backup pack](../packs/oracledb-backup) reads
`V$RMAN_BACKUP_JOB_DETAILS` on the primary through the observer's Collector
(`oracledb.backup.age`, `oracledb.backup.failed`, per kind `database` or
`archivelog`) and the recovery area of both databases
(`oracledb.recovery_area.*`, readable on the mounted standby through `SYSDG`).
`OracleBackupStale` fires above 26 h (database) or 5 h (archived logs), the
limits recorded as `obenhub.backup_age.limit` in
[mon/vmalert/inventory.yml](mon/vmalert/inventory.yml); `OracleBackupFailed`
when the last finished job of a kind failed; `OracleBackupMissing` when a
database is primary (Data Guard pack) and has no database backup series for
30 minutes; `OracleRecoveryAreaFull` when used minus reclaimable space is above
85% of the limit for 10 minutes. `OracleBackupMissing` fires on a fresh primary
until its first database backup, and on a newly promoted primary until it has
run its own, by design. All four rules have unit tests. The scenario
`backup-failed` (below) delivered `OracleBackupFailed` in the suite;
`backup-stale` delivered `OracleBackupStale` in a single run on 2026-11-15
(`seconds_to_detect` 17221.6); `archiver-stuck` makes the condition of
`OracleRecoveryAreaFull` true but ends before its 10 minute hold.

Check by hand on a database VM (as `oracle`): `rman target /` then `list backup
summary;`, `show all;`. Revert: remove the crontab lines tagged `# obenhub:` for
that SID (`crontab -e`), `CONFIGURE ... CLEAR;` for the settings, `ALTER
DATABASE DISABLE BLOCK CHANGE TRACKING;`, `ALTER SYSTEM SET
control_file_record_keep_time = 7 SCOPE=BOTH;`.

## Backend

`mon/compose.yaml` runs on this box: a gateway Collector with a mutual-TLS
OTLP/HTTP receiver (the config is shared with [pgha](../pgha), at
`lab/mon/otelcol-gateway-mtls.yaml`), and the shared VictoriaMetrics,
VictoriaLogs, vmalert, Alertmanager and Grafana services of
[lab/mon](../mon). vmalert loads `mon/vmalert/inventory.yml` (the three Collectors and the two
databases), the shared Collector and [host](../packs/host/rules.yml) packs and
the Data Guard pack rules
([lab/packs/oracledb-dg](../packs/oracledb-dg/rules.yml)) and the RMAN backup
pack rules ([lab/packs/oracledb-backup](../packs/oracledb-backup/rules.yml):
`OracleBackupStale`, `OracleBackupFailed`, `OracleBackupMissing`,
`OracleRecoveryAreaFull`); the rules are unit-tested
(`mise run lab:oracle:rules-test`). The suite waits for 12 of the 18 Data
Guard pack alerts (20 rules: `OracleProcessesSaturation` and
`OracleTablespaceUsageHigh` have two tiers each) and for `OracleBackupFailed`;
the unit-tested-only ones are listed under Scenarios. Grafana provisions the shared host dashboard and "Oracle Data Guard"
([oracle-dg.json](../packs/oracledb-dg/dashboards/oracle-dg.json)): lag and
data age, apply state, fast-start failover, protection level and redo
destination, heartbeat and the observer Collector, and the firing alerts, plus
the panels "RMAN backup age" and "RMAN last job failed", "Processes in use and limit", "Tablespace usage against its maximum size",
"Oldest lock wait", "Monitoring accounts open", "Recovery area used, reclaimable
counted as free", and "Listener TCP
connect" and "Listener connect time" (the `tcpcheck` probe of both listeners,
ADR 0008 decision 7; a connect only, no login; the failing-listener path
ran in scenario `listener-stopped` (run started 2026-11-14T17:57:45Z: firing
at +73 s, delivered at +115 s; startsAt-to-delivery 42 s for every alert on
the stack, cause not yet found; two passing runs (17:57:45Z 166 s, 18:16:39Z 171 s, same result), Oracle 19.33, existing sessions only); each failed collection logs a multi-line error with a stack trace on the
observer).
`mise run lab:oracle:panels` runs its queries against the running Grafana.

```sh
mise run lab:oracle:pki      # CA, gateway certificate, client certificate (lab/oracle/pki, gitignored)
mise run lab:oracle:mon:up   # writes mon/.env, then docker compose up --wait
mise run lab:oracle:mon:down # also deletes the volumes
```

`pki.sh` issues only what is missing and runs on every `mon:up`. After a
change of `GATEWAY_IP` in `gateway.sh`, delete `pki/gateway/` so the
gateway certificate is issued again with the new address.

Only the gateway listens on the LAN, the rest on `127.0.0.1`:

| Service | Host port |
| --- | --- |
| gateway (OTLP/HTTP, mutual TLS) | `10.0.0.11:54318` |
| VictoriaMetrics | 58428 |
| VictoriaLogs | 59428 |
| vmalert | 58880 |
| Alertmanager | 59093 |
| Grafana | 53000 |

The gateway certificate has `10.0.0.11` as its SAN. `ca.crt` and the VM's
client certificate (`pki/otelcol.*` for `ora-dg-obs`, `pki/<host>/otelcol.*`
for the others) go to `/etc/otelcol-contrib/tls` on each VM
(`OBENHUB_GATEWAY_ENDPOINT=https://10.0.0.11:54318`). On 2026-11-13 the
Collector configuration above ran in the contrib 0.164.0 container on this box
against this backend with the client certificate: 38 `oracledb.*` metric names
reached VictoriaMetrics, 34 for `CDB19` and 11 for `CDB19_STBY` (both pack
roles). A client without a certificate was refused (curl exit 56).

## Scenarios

`scenarios/` holds fault scenarios for the `CDB19` pair on the shared harness
([lab/scenarios/lib-core.sh](../scenarios/lib-core.sh)); `scenarios/lib.sh` is
the Oracle adapter. Each scenario injects one fault, waits for the alerts it
expects from the [Data Guard pack](../packs/oracledb-dg/rules.yml), reverts,
waits for them to resolve and fails on any other alert. The header of each
script gives its expectation and why. Results are appended to
`results/runs.jsonl`; the suite of record is the one named at the top, and
`scripts/check-evidence.sh --strict oracle` checks that it, with any targeted suites after it, is current.

Unit-tested only (no scenario waits for them): `OracleTargetAbsent`,
`OracleMultiplePrimaries`, `OracleNoPrimary`, `OracleStandbyLagUnknown`,
`OracleRedoGap`, `OracleFastStartFailoverNotSynchronized`,
`OracleBackupMissing` and `OracleRecoveryAreaFull`. `fsfo-failover` allows
`OracleRedoGap` and `OracleFastStartFailoverNotSynchronized` (the second fired
and resolved in the suite run, `extra.alerts_seen`), and `archiver-stuck`
allows `OracleRecoveryAreaFull` (not delivered, see below).

```sh
mise run lab:oracle:scenario control          # CONTROL_SECONDS (default 600), no fault
mise run lab:oracle:scenario apply-stopped    # broker APPLY-OFF on CDB19_STBY
mise run lab:oracle:scenario observer-stopped # stop the CDB19 FSFO observer
mise run lab:oracle:scenario transport-cut    # broker TRANSPORT-OFF on the primary
mise run lab:oracle:scenario listener-stopped # lsnrctl stop on the primary VM, then start
mise run lab:oracle:scenario password-expired # C##OBENHUB_MON password expired on CDB19, then restored
mise run lab:oracle:scenario processes-exhausted # holder sessions fill PROCESSES of CDB19 (ORA-00020 for new logins), then stopped
mise run lab:oracle:scenario tablespace-full     # a 20 MB tablespace of PDB19 filled to ORA-01653, then dropped
mise run lab:oracle:scenario blocking-session    # one session of PDB19 waits for a row lock another holds, then both are stopped
mise run lab:oracle:scenario archiver-stuck     # recovery area limit of the CDB19 primary lowered under its usage until ARCH fails (ORA-19809), then restored
mise run lab:oracle:scenario backup-failed      # one RMAN archived log job of the CDB19 primary fails (nonexistent backup piece directory), then one succeeds
mise run lab:oracle:scenario fsfo-failover     # SHUTDOWN ABORT of the CDB19 primary, the observer fails over to CDB19_STBY, then reinstate and switchover back
mise run lab:oracle:scenario backup-stale       # LONG, not in the suite: the archived log backup cron line is paused until OracleBackupStale fires (about 5 h), then restored
mise run lab:oracle:scenarios                 # the list in scenarios/suite.txt as one suite
```

Prerequisites, on top of those above: the backend (`lab:oracle:mon:up`) and
the Collector (`lab:oracle:collector`) running, the pair healthy (broker
`SUCCESS`, fast-start failover enabled, observer present, lag 0), which the
pre-flight checks. The scenarios ssh to the VMs as the invoking user and run
`sudo -u oracle` there (passwordless sudo, see the prerequisites), with
operating-system authentication (`sqlplus / as sysdba`, `dgmgrl /`). Only
`password-expired` and `processes-exhausted` use a password: they read `ORA_MON_PASSWORD` from
`lab/oracle/.env` for the fresh-login checks (and `password-expired` for the restore), send it to
`sqlplus` on stdin only, and refuse to start unless a login with it works
(the `.env` value must be the one the database holds). Every remote command is bounded by `REMOTE_TIMEOUT`
(180 s), and each revert step is tried three times. The observer runs as the systemd unit
`dg-observer@cdb19` on `ora-dg-obs` (`/home/oracle/scripts/observer.sh`,
owner-provided and not in this repository).
`tablespace-full` creates the tablespace `OBENHUB_FILL` (one 20 MB datafile, no autoextend) and the user `OBENHUB_FILL_OWNER` in `PDB19` of the CDB19 primary, fills its one table until the insert fails with ORA-01653, and drops both with the datafile; it refuses to start unless `STANDBY_FILE_MANAGEMENT` is `AUTO` on both databases (the create and the drop reach the standby by redo apply) and the Collector already reports the tablespace series with `oracle.db.pdb` (`lab:oracle:collector`). No existing tablespace is touched.

`blocking-session` creates the user `OBENHUB_BLOCK` (quota 1 MB) with a one-row table in `PDB19` of the CDB19 primary and starts two `sqlplus` sessions in the transient systemd unit `obenhub-blocking-session` on `ora-au-lab`: one updates the row and holds the transaction, the other updates the same row and waits (`enq: TX - row lock contention`). It first requires V$SESSION to show the waiter blocked, then waits for `OracleBlockedSessions` (the signal is `oracledb.lock.oldest_wait_age`, a primary-only `sql_query` of [queries-primary.yaml](../packs/oracledb-dg/queries-primary.yaml); upstream has no such metric). The revert stops the unit and drops the user; it refuses to start when `OBENHUB_BLOCK` exists, a session is already waiting on a lock, or the Collector does not yet report the series (`lab:oracle:collector`). Nothing else is touched.

`backup-failed` runs `backup archivelog all format '/nonexistent-obenhub/arch-%U'` as `oracle` on `ora-au-lab` under the managed script's lock, so one RMAN job ends in error and nothing else changes (no deletion, no parameter, no cron line); `OracleBackupFailed` is expected, and the revert is the managed script's own `rman-backup.sh CDB19 arch`, after which the newest job is completed and the alert resolves. The failed job row stays in the controlfile (21 days). It waits up to 25 min for the minutes around a managed cron job to pass before it starts. That the failed job is recorded as `FAILED` is an assumption the run checks and records.

`backup-stale` is long (about 5 h) and is not in `suite.txt` (it is listed in `scenarios/long.txt`, which `scripts/check-evidence.sh` reads). It comments out the managed archived log line in the crontab of `oracle` (`lab/oracle/files/cron-pause.sh`, installed as `/usr/local/sbin/obenhub-cron-pause`) until `OracleBackupStale` fires for `archivelog`, then restores the line, compares the whole crontab with the copy taken before, and runs one archived log backup. The alert fires 5 h (`obenhub.backup_age.limit`) after the END of the last completed archived log job, and a daily level job (01:45, not paused) counts too: the scenario prints the expected fire time, bounds the wait at 6 h and refuses to start when that is not enough. A safety net is installed first, a systemd timer on `ora-au-lab` (`obenhub-cron-restore.timer`, enabled, restores at start + 7 h, 5 min after any boot once the deadline has passed, and every 15 min after it until a restore succeeds, without a cap; the runs before the deadline do nothing), so a killed script or box does not leave the line paused. Start it detached: `setsid nohup mise run lab:oracle:scenario backup-stale > ~/work/obenhub-runs/backup-stale-$(date +%Y%m%d).log 2>&1 &`. `BACKUP_STALE_TRIAL_SECONDS=300` holds the pause for 300 s and expects no alert (the limit is a constant recording rule, so the alert itself cannot be shortened); it checks the mechanics only.

`archiver-stuck` lowers `DB_RECOVERY_FILE_DEST_SIZE` of the CDB19 primary with `ALTER SYSTEM ... SCOPE=MEMORY` (never the SPFILE, so an instance restart returns the original) to 90% of (space used - reclaimable space - bytes of flashback logs), all read before the change, and runs `ALTER SYSTEM SWITCH LOGFILE` in the transient systemd unit `obenhub-archiver-stuck` on `ora-au-lab` until ARCH fails to archive to the local destination (`V$ARCHIVE_DEST` destination 1 `ERROR`, ORA-19809) and the online groups wait for archiving. Oracle deletes reclaimable files (archived logs that are applied and backed up, flashback logs past retention) when it needs room (unverified: from memory, not read in the documentation), so the pre-flight requires the new limit to be below the space used minus the reclaimable space, and at least 1 GiB. Flashback logs are subtracted as well because Oracle may delete them under space pressure even inside the retention target (assumption); the reclaimable flashback logs are then subtracted twice, which only lowers the limit. The record has the space used, the reclaimable space and the flashback log count and bytes before, during and after. No table is needed: log switches alone fill the three online groups, so no user or object is created. The alert is `OracleRedoDestinationInvalid` for destination 1: the `oracledb.archive_dest.*` query of the [oracledb-dg pack](../packs/oracledb-dg) lists the local archive destination as well as the remote ones (its `GAP_STATUS` is empty, so it never reads as a gap), and the local destination reads `ERROR` while the archiver cannot write. The run requires the delivered notification to name destination 1 and `V$ARCHIVE_DEST_STATUS` to read `LOCAL ERROR`. `OracleRecoveryAreaFull` (the same fault seen from the `oracledb.recovery_area.*` series of the [oracledb-backup pack](../packs/oracledb-backup), collected every 60 s) needs 10 minutes of it: the run ends long before, so that alert is allowed and the record says whether it was delivered. The revert stops the unit first, then restores the saved limit, waits for ARCH to resume (when it has not after 90 s the revert runs `ALTER SYSTEM ARCHIVE LOG ALL` and the record notes it; it was not needed in the kept run), requires a log switch and the pair healthy with no gap, and fails when `FLASHBACK_ON` changed. A failed step is recorded and the later steps still run, and a late re-check retries the stop and the restore. It refuses to start unless the fast-start failover health condition `Stuck Archiver` is `NO` and no Oracle error condition is configured (otherwise a stuck archiver could fail the primary over), destination 1 is `VALID`, and the Collector reports the limit the database reads and destination 1 of both databases as valid (`lab:oracle:collector`). While the archiver is stuck, a fresh login of an account without SYSDBA fails with ORA-00257 (seen with `C##OBENHUB_MON`) and sessions that commit are expected to hang (not tested); the record lists what worked and what did not (a SYSDBA `SELECT`, `dgmgrl`, a fresh `C##OBENHUB_MON` login, which needs `lab/oracle/.env` and is skipped without it, the Collector heartbeat). Nothing is ever deleted by hand from `/u02/fra`.

`processes-exhausted` starts up to about 250 holder sessions (one bequeath `sqlplus` and its server process each, about 10 MB per holder) in the transient systemd unit `obenhub-processes-exhausted` on `ora-au-lab`, so that stopping the unit removes them; it refuses to start with less than 4.5 GB `MemAvailable` there, and the holders end by themselves after 900 s. While the limit is reached the scenario's own bequeath logins fail too.

`fsfo-failover` aborts the `CDB19` primary (`SHUTDOWN ABORT`) and is the one scenario that swaps the roles of the pair: the observer fails over to `CDB19_STBY`, and the revert mounts `CDB19`, lets the observer reinstate it (the command is run when it does not within 180 s) and switches over back. [scripts/restore-roles.sh](scripts/restore-roles.sh) is that revert as a script that is safe to rerun by hand from any intermediate state (old primary down, mounted and not yet reinstated, reinstated, roles swapped); `restore-roles.sh status` only prints the states. The switchover and a manual reinstate are run logged on as `C##OBENHUB_DG` AS SYSDG (password from `.env`, on stdin only): with operating-system authentication the broker refuses a switchover (ORA-01017). Lab finding (suite run of 2026-11-16): a managed archived log backup with DELETE INPUT shortly before the failover removes the archived logs that flashback of the old primary needs, and the reinstate fails with ORA-16653 and ORA-38761 in the broker log of CDB19; the script reads the sequence from that log, restores the archived logs on CDB19 with RMAN from the backup (from 10 sequences below it, up to 4 rounds, the needed sequence can move back between rounds) and retries the reinstate at once. The rounds are in the run record as archivelog_restore_rounds. It refuses to touch two databases that are both open read write as primary, and run by hand it takes the lab lock, so it cannot start in the middle of a scenario or suite. Before the abort the scenario arms a transient user timer (`obenhub-fsfo-restore`, about 108 minutes, computed from the scenario's own timeouts) that runs the script if the scenario's shell is killed; it is stopped after a good revert and does not survive a reboot of the box. The scenario refuses to start while a managed backup cron job is due within its window, and it restarts the Collector on `ora-dg-obs` after the switchback only if the `oracledb` receiver's role labels differ from the database.

Only the `CDB19` configuration is touched, never `CDB19B` or `CDB26`, with one exception: `listener-stopped` stops the listener of `ora-au-lab`, which all three databases share, so their new connections fail during the outage (about 3 minutes). That includes the fast-start failover pair `CDB19B` (its own configuration and observer, Shutdown Primary TRUE): the scenario refuses to start unless `CDB19B` is SYNCHRONIZED with a SUCCESS configuration, guards it like `CDB19` (a role change, or two failed reads in a row, restarts the listener at once and fails the run) and records its states in `extra`. The listener is restarted with the `TNS_ADMIN` of the running one; without it a started listener reads no `listener.ora` and lacks the static `*_DGMGRL` services (found in the first trial, 2026-11-14T17:50Z, recorded as a failed run). Both trials read `TNS_ADMIN` from a listener the scenario or a manual repair had started, not from one started by `oracle-db.service` (`start_all.sh` exports it, so it is expected to work).

`fsfo-failover` is the only scenario that changes roles; there is none for a
planned switchover. The `oracledb` receiver reads the database role and open mode only when the
Collector starts ([role-staleness-2026-11-13](results/role-staleness-2026-11-13)), so its
`oracle.db.role` labels cannot be trusted after a role change: the scenario records what the receiver and the
`sql_query` pack (role read again on every collection) report after the failover and after the
switchback, and restarts the Collector only if the receiver's labels then differ from the database.
