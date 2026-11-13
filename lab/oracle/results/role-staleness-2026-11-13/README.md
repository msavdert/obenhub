# oracledbreceiver: oracle.db.role and oracle.db.open_mode after a Data Guard role change

Date of the runs: 2026-11-13, all times UTC. This directory keeps the attribute summaries and
timelines, the database states, the test Collector configuration and the source references. The full
Collector logs, journals, exported JSONL and source copies (about 4 MB) were not kept; file names of
those are given where a number came from one.

## Claim tested

contrib `oracledbreceiver` reads the resource attributes `oracle.db.role` and `oracle.db.open_mode`
once at start (`instance_info.go`), so after a Data Guard role change they stay stale until the
Collector restarts.

## Verdict

Confirmed, with two additions observed on the same runs:

1. A receiver whose start-time query failed (login refused by a mounted standby) starts anyway,
   emits no `oracle.db.role`, `oracle.db.open_mode` or `oracle.db.version` attributes and keeps
   emitting without them after the database becomes a primary, until restart.
2. A receiver that logs in as a plain user (`C##OBENHUB_MON`, the lab's configuration) to a database
   that becomes a mounted standby does not emit stale attributes: it emits nothing (ORA-01033 on every
   query) until the database is open again. Stale attributes are visible only where the login still
   works on both roles (here: `C##OBENHUB_DG` AS SYSDG).

Decisive observation (contrib 0.164.0, receiver `oracledb/standby_sysdg`, data source with
`C##OBENHUB_DG` AS SYSDG on CDB19_STBY, started while CDB19_STBY was a mounted physical standby):

| | v$database on ora-dg-stby | attributes on the metrics from that receiver |
| --- | --- | --- |
| before the switchover | PHYSICAL STANDBY, MOUNTED | role='PHYSICAL STANDBY', open_mode='MOUNTED' |
| 19:20:12-19:24:27, after the switchover (same process, 26 batches) | PRIMARY, READ WRITE | role='PHYSICAL STANDBY', open_mode='MOUNTED' (all 26) |
| after restarting the process (19:24:58) | PRIMARY, READ WRITE | role='PRIMARY', open_mode='READ WRITE' |

The same inversion for `oracledb/primary_sysdg` on CDB19 (PRIMARY/READ WRITE kept while CDB19 was a
mounted standby). Repeated with contrib 0.165.0 on the switch-back: both stale again, both correct
after restart (section "Observed values").

## Environment

- Databases: Oracle Database 19c Enterprise Edition 19.33.0.0.0 on ora-au-lab (`v$version`, read before the
  switchover); the receiver logs `version 19.0.0.0.0` for both. Pair: CDB19 (db_unique_name `CDB19`,
  `cdb19` in the broker) on ora-au-lab 10.0.0.12 and CDB19_STBY on ora-dg-stby 10.0.0.14, both
  CDB, Data Guard broker configuration `dgconfig`, protection mode MaxAvailability, Fast-Start Failover
  Enabled in Zero Data Loss Mode, observer `ora-dg-obs.lab.local1`, Real Time Query OFF (standby is MOUNTED).
- Test Collector: `otel/opentelemetry-collector-contrib:0.164.0`
  (`sha256:340c9ca6a36617084c6661bdc4f0fe92b7cda5a805d61673ec8db375fddc522b`; the log shows
  `oracledbreceiver@v0.164.1`) and `otel/opentelemetry-collector-contrib:0.165.0`
  (`sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea`; log shows
  `oracledbreceiver@v0.165.0`). The image tag `0.165.1` does not exist
  (`docker pull` says not found; the opentelemetry-collector-releases tags end at `v0.165.0`), so the
  repeat used 0.165.0. The source at the contrib tag `v0.165.1` was read separately (below).
- Config: `otelcol-test.yaml` (no secret in it). Four `oracledb` receivers, `collection_interval: 10s`, one
  `file` exporter each (`primary`, `standby`, `primary_sysdg`, `standby_sysdg`):
  `primary`/`standby` as in `lab/oracle/files/otelcol-obs.yaml` (endpoint, service, user
  `C##OBENHUB_MON`, password from the environment); `*_sysdg` through a `datasource` with
  `C##OBENHUB_DG` and `DBA PRIVILEGE=SYSDG` (the login the oracledb-dg pack uses), added because the
  plain user cannot log in to a mounted standby. Containers ran with
  `--add-host ora-au-lab.lab.local:10.0.0.12 --add-host ora-dg-stby.lab.local:10.0.0.14`.
- The installed Collector on ora-dg-obs: otelcol-contrib 0.164.0 rpm, `lab/oracle/files/otelcol-obs.yaml`,
  started 19:11:40 and never restarted during the runs (NRestarts=0).

## Source reading (raw.githubusercontent.com at full commit SHAs)

Commits (`git ls-remote`, `refs.txt`): contrib `v0.164.0` -> `18fcec7bd1f5b4702a40a1861e0b5eb95f9a3152`;
module tag `receiver/oracledbreceiver/v0.164.1` -> `9d85835bdee87a7e33e315da1a875cbaabd50b91` (the
module version the 0.164.0 binary logs); module tag `receiver/oracledbreceiver/v0.165.0` ->
`f56f9a38c9864e892af542f1dbd28f475d6779dc`; contrib `v0.165.1` ->
`6083b2c53d78b21d0925b703194aaed920c01af5`; `main` -> `6b96aab83ba5be641d04d3b944cdcf5d80926754`
(read 2026-11-13). The copies read then were not kept; the commits above reproduce them.

`instance_info.go` is byte-identical in all five (md5 prefix bfcf0241). Lines (same in all five):

- :15 comment "oracleInstanceInfo holds Oracle deployment metadata detected once at scraper start time".
- :47 `instanceCDBSQL = "SELECT cdb, database_role, open_mode FROM v$database"`.
- :74-76 `detectInstanceInfo` "queries Oracle at startup"; :87 5 s timeout (`instanceInfoDetectTimeout`, :45).
- :92-97 the version query runs first; on error or no rows it logs Warn "failed to detect Oracle version.
  oracle.db.version and oracle.db.edition will not be set" and returns the empty struct, so role and open mode
  are never queried.
- :116-121 the CDB query; on error or no rows it logs Warn "failed to detect CDB status; assuming non-CDB" and
  returns without role.
- :123-124 `info.databaseRole`, `info.openMode` are set here, from the first row.
- :74 doc comment: "Failures are logged at Warn level; affected fields retain their zero value."

`scraper.go` (line numbers for v0.164.0 and the module tag v0.164.1 / for module v0.165.0, v0.165.1, main):

- :474-477 field `instanceInfo oracleInstanceInfo`, comment "detected once at start()". Same lines in all.
- :566 `func (s *oracleScraper) start`; :569-572 the only error return: `dbProviderFunc()` failing ("failed to open
  db connection"); :579-589 the single call of `detectInstanceInfo` (`grep -c 'detectInstanceInfo('` = 1 in
  every version); :638 `return nil`. `start` lines :560-640 are identical across the versions compared.
  A failed query in `detectInstanceInfo` therefore does not fail `start`.
- `factory.go:79` `sql.Open("oracle", dsn)` in `defaultSQLOpener`; `database/sql` `Open` does not itself
  connect (Go standard library documentation, not re-verified here), consistent with the observed start
  against the mounted standby. `factory.go:135` `scraperhelper.NewMetricsController`.
- Attachment on every scrape: `scrape` is :641; :1372 `rb := s.setupResourceBuilder(s.mb.NewResourceBuilder())`
  and :1374 `out := s.mb.Emit(metadata.WithResource(rb.Emit()))`. `setupResourceBuilder` is :2692 (v0.164.0,
  v0.164.1) / :2693 (v0.165.0, v0.165.1, main); it copies `s.instanceInfo` fields onto the resource.
  Role: `if s.instanceInfo.databaseRole != ""` -> `rb.SetOracleDbRole` at :2715 (v0.164.x) / :2716
  (v0.165.0, v0.165.1, main); open mode `rb.SetOracleDbOpenMode` at :2718 / :2719. The setters are
  skipped when the value is empty, so an empty `instanceInfo` yields metrics without the attributes.
  The logs path calls the same function (:2154, :2348, :2438/:2439, :2584/:2585).
- No other writer of `instanceInfo.databaseRole` / `openMode` and no timer or refresh in `instance_info.go` or
  in the `scraper.go` start/scrape paths read (a `grep` for refresh/ticker found only the unrelated
  `vsqlRefreshLag` comment at main `scraper.go:2787`).

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 19:11:40 | ora-dg-obs Collector started (installed in the same task) |
| 19:17:36 | first test run, two receivers (replaced; its data was not kept) |
| 19:18:12 | test run 0.164.0 with the four receivers (before state, `a-*`) |
| 19:18:50 | `SWITCHOVER TO cdb19_stby` as OS-authenticated `dgmgrl /`: refused when the broker connected to the standby (ORA-01017), no change (`b-switchover1.txt`) |
| 19:19:15 | `SWITCHOVER TO cdb19_stby` logged on as `C##OBENHUB_DG` AS SYSDG; `validate database cdb19_stby` before it: Ready for Switchover Yes |
| 19:20:11 | "Switchover succeeded, new primary is cdb19_stby"; the broker restarted instance CDB19 and mounted it |
| 19:21:07 | `show configuration` SUCCESS (WARNING with ORA-16824, ORA-16854 from 19:20:15 to 19:20:57) |
| 19:24:27 | end of the 4-minute observation of the same 0.164.0 process (data copy `c-data164-after-switchover`) |
| 19:24:58 | restart of the 0.164.0 container (control) |
| 19:25:45 | 0.165.0 container started (roles still swapped) |
| 19:26:22 | `SWITCHOVER TO cdb19` (connected to cdb19_stby as SYSDG) |
| 19:27:15 | "Switchover succeeded, new primary is cdb19"; the broker restarted instance CDB19_STBY and mounted it |
| 19:28:10 | `show configuration` SUCCESS |
| 19:30:22 | end of the 3-minute observation of the 0.165.0 process |
| 19:30:31 | restart of the 0.165.0 container (control) |
| 19:31:21 | final check (`g-final-state.txt`) |

## Observed values (resource attributes on the exported metrics; `attrs-summary.txt`, `c-attrs-timeline.txt`)

FSFO: `show fast_start failover` before: Enabled in Zero Data Loss Mode, Active Target cdb19_stby,
Observer ora-dg-obs.lab.local1; the switchover was not refused and FSFO was not disabled; `show configuration`
after each switchover still says "Fast-Start Failover: Enabled in Zero Data Loss Mode".

Before (0.164.0, `a-before-state.txt`): dgmgrl: cdb19 Primary, cdb19_stby Physical standby, SUCCESS;
v$database: CDB19 PRIMARY / READ WRITE (switchover_status TO STANDBY), CDB19_STBY PHYSICAL STANDBY /
MOUNTED (NOT ALLOWED), MRP0 APPLYING_LOG, FS_FAILOVER_STATUS SYNCHRONIZED on both.

| Receiver (target) | Before | After the switchover, same process (4 min) | After restart |
| --- | --- | --- | --- |
| `primary` (C##OBENHUB_MON -> CDB19) | PRIMARY / READ WRITE, 25 metrics per scrape | no batch after 19:19:24; every scrape fails ORA-01033 (CDB19 is a mounted standby) | no batch while mounted; start log: "failed to detect Oracle version ... ORA-01033" |
| `standby` (C##OBENHUB_MON -> CDB19_STBY) | no batch (empty `{}`); start log "failed to detect Oracle version ... ORA-01033: ORACLE initialization or shutdown in progress"; every scrape error ORA-01033 | from 19:19:44, when CDB19_STBY opened: 23-25 metrics per scrape with no `oracle.db.role`, `oracle.db.open_mode`, `oracle.db.version` (role=None, 26 batches) | PRIMARY / READ WRITE, version 19.0.0.0.0, 25 metrics |
| `primary_sysdg` (SYSDG -> CDB19) | PRIMARY / READ WRITE | PRIMARY / READ WRITE (all 26 batches) although CDB19 is PHYSICAL STANDBY / MOUNTED (confirmed in `c-state-after-switchover.txt`) | PHYSICAL STANDBY / MOUNTED (matches v$database) |
| `standby_sysdg` (SYSDG -> CDB19_STBY) | PHYSICAL STANDBY / MOUNTED | PHYSICAL STANDBY / MOUNTED (all 26 batches) although CDB19_STBY is PRIMARY / READ WRITE | PRIMARY / READ WRITE (matches v$database) |

After the switchover the `*_sysdg` receivers did not stop: they emitted 23 or 25 metrics per scrape with
scrape errors in the log every cycle (`primary_sysdg`: ORA-01219 on `CDB_TABLESPACE_USAGE_METRICS`
while CDB19 is mounted; `standby_sysdg`: "failed to parse int64 for OracledbTablespaceSizeUsage ...
parsing \"\""). The receiver scrape errors per component after 19:20: 27 each for `oracledb/primary`,
`oracledb/primary_sysdg`, `oracledb/standby_sysdg` in 4 min 27 s.

0.165.0, switch-back (stale exactly as in 0.164.0, `attrs-summary.txt` second block):

| Receiver | Before (roles swapped, 19:25:45) | After switch-back, same process (19:27:16-19:30:31, 19 batches each) | After restart (19:30:31) |
| --- | --- | --- | --- |
| `primary` (MON -> CDB19) | no batch (CDB19 mounted standby) | from 19:26:37, when CDB19 opened: 25 metrics, role=None open_mode=None version=None (19 batches) | PRIMARY / READ WRITE |
| `standby` (MON -> CDB19_STBY) | PRIMARY / READ WRITE | last batch 19:26:27, then none (CDB19_STBY mounted) | no batch (mounted) |
| `primary_sysdg` (SYSDG -> CDB19) | PHYSICAL STANDBY / MOUNTED | PHYSICAL STANDBY / MOUNTED while CDB19 is PRIMARY / READ WRITE | PRIMARY / READ WRITE |
| `standby_sysdg` (SYSDG -> CDB19_STBY) | PRIMARY / READ WRITE | PRIMARY / READ WRITE while CDB19_STBY is PHYSICAL STANDBY / MOUNTED | PHYSICAL STANDBY / MOUNTED |

Log excerpts (`d-log164-full.txt`, `e-log165-after-switchback.txt`, resource fields removed):

```text
19:18:13.516Z warn oracledbreceiver@v0.164.1/instance_info.go:94 failed to detect Oracle version. oracle.db.version and oracle.db.edition will not be set {"otelcol.component.id": "oracledb/standby", ... "error": "ORA-01033: ORACLE initialization or shutdown in progress\n error occur at position: 0"}
19:18:13.576Z service.go:256 "Everything is ready. Begin running and processing data."   (the Collector starts despite the warning above)
19:18:14.620Z error scraperhelper@v0.164.0/obs_metrics.go:61 Error scraping metrics {"otelcol.component.id": "oracledb/standby", ... "error": "error executing select * from v$sysstat: ORA-01033: ORACLE initialization or shutdown in progress ..."}
```

No log line in either image states that role or open mode changed or is stale.

## ora-dg-obs Collector (target of `oracledb` = CDB19, started 19:11:40 while CDB19 was the primary)

- Journal (`c-obs-journal-after-switchover.txt`, `g-obs-journal-full.txt`): error-level lines from 19:19:26
  (`sql_query/primary`: ORA-16456 "switchover to standby in progress or completed", then "scraper: EOF"; `oracledb`
  scrape errors from 19:19:41), about two per minute until 19:29:41, none after 19:30. Service stayed active,
  NRestarts=0, no restart needed.
- VictoriaMetrics (127.0.0.1:58428), series with `oracle.db.role` (from the `oracledb` receiver, e.g.
  `oracledb.sessions.usage`, `service.instance.id=CDB19`): `PRIMARY / READ WRITE` from 19:11:41, last
  sample 19:19:11, no samples 19:19:11-19:26:41 (gap, no stale-value series), `PRIMARY / READ WRITE` again from
  19:26:41 to the end of the runs. The `oracledb.database.primary` series (oracledb-dg pack, from the
  `sql_query` receivers) changed value in step with the roles: CDB19 1 -> 0 and CDB19_STBY 0 -> 1 at 19:19:26;
  the switch-back values were not read separately (the final check shows CDB19 `recv PRIMARY` at 19:31:11).
- For this Collector the `oracledb` receiver kept its start-time attributes, which happen to be correct again
  after the switch-back (roles restored), so it needed no restart.

## End state (`g-final-state.txt`, 19:31)

- dgmgrl `show configuration`: cdb19 Primary database, cdb19_stby Physical standby database, SUCCESS,
  Fast-Start Failover Enabled in Zero Data Loss Mode (Active Target cdb19_stby, Observer
  ora-dg-obs.lab.local1); transport and apply lag 0 seconds.
- v$database: CDB19 PRIMARY / READ WRITE; CDB19_STBY PHYSICAL STANDBY / MOUNTED; FS_FAILOVER_STATUS
  SYNCHRONIZED on both; MRP0 APPLYING_LOG on the standby.
- ora-dg-obs Collector delivers `CDB19` (pack and `oracledb` receiver) and `CDB19_STBY` (pack) to VictoriaMetrics,
  last samples 19:31:11, 3 minutes window; not restarted.
- Test containers removed.

## Limits of this evidence

- One pair, one switchover per image; the stale-then-correct sequence was seen on both images.
- The `*_sysdg` receivers are a test construct (data source with SYSDG); the lab's `oracledb` receiver
  uses the plain monitoring user, whose behaviour on a mounted standby is the ORA-01033 case above.
- The "sql.Open does not connect" statement is the standard library's documented behaviour, not checked here
  beyond the observation that `start` succeeded against a database that refused the login.
