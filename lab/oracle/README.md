# lab/oracle

The Oracle lab of [ADR 0008](../../docs/adr/0008-oracle-lab-scope.md). What
runs so far is the database side of the first slice, the `CDB19` Data Guard
pair, its Collector configuration and the backend the Collector pushes to.
The first fault scenarios are in `scenarios/` (below); there is no suite
evidence yet, so the lab is not in the [lab table](../README.md).

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
run its own, by design. The four rules have unit tests only; no scenario has
exercised them.

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
(`mise run lab:oracle:rules-test`) and six of the Data Guard ones are exercised
by the scenarios below. Grafana provisions the shared host dashboard and "Oracle Data Guard"
([oracle-dg.json](../packs/oracledb-dg/dashboards/oracle-dg.json)): lag and
data age, apply state, fast-start failover, protection level and redo
destination, heartbeat and the observer Collector, and the firing alerts, plus
the panels "RMAN backup age" and "RMAN last job failed".
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
`results/runs.jsonl`.

```sh
mise run lab:oracle:scenario control          # CONTROL_SECONDS (default 600), no fault
mise run lab:oracle:scenario apply-stopped    # broker APPLY-OFF on CDB19_STBY
mise run lab:oracle:scenario observer-stopped # stop the CDB19 FSFO observer
mise run lab:oracle:scenario transport-cut    # broker TRANSPORT-OFF on the primary
mise run lab:oracle:scenarios                 # the list in scenarios/suite.txt as one suite
```

Prerequisites, on top of those above: the backend (`lab:oracle:mon:up`) and
the Collector (`lab:oracle:collector`) running, the pair healthy (broker
`SUCCESS`, fast-start failover enabled, observer present, lag 0), which the
pre-flight checks. The scenarios ssh to the VMs as the invoking user and run
`sudo -u oracle` there (passwordless sudo, see the prerequisites), with
operating-system authentication (`sqlplus / as sysdba`, `dgmgrl /`); no
password is involved. Every remote command is bounded by `REMOTE_TIMEOUT`
(180 s), and each revert step is tried three times. The observer runs as the systemd unit
`dg-observer@cdb19` on `ora-dg-obs` (`/home/oracle/scripts/observer.sh`,
owner-provided and not in this repository).
Only the `CDB19` configuration is touched, never `CDB19B` or `CDB26`.

There is no switchover or failover scenario: the `oracledb` receiver reads
the database role and open mode only when the Collector starts
([role-staleness-2026-11-13](results/role-staleness-2026-11-13)), so the
role-based rules cannot be exercised that way yet.
