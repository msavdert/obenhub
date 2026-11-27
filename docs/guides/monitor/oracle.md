# An Oracle database

The Collector connects to the listener of an Oracle container database (CDB)
and sends to the backend of [the guide's index](index.md). Do step 1 there
(backend) and use this page for the rest: the index's step 2 and its table of
database changes are PostgreSQL's. The page is written from
[`deploy/test/oracle-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/oracle-test.sh),
which runs this layout; where the test differs from what you would run, the text
says so.

## What the Oracle test proves, and what it does not

The latest run (2026-11-27 09:33 UTC, commit 909010f plus the uncommitted G3
files, so the line says `git_dirty`; to be repeated on the committed tree; line
with `"test": "oracle-test"` in `deploy/results/runs.jsonl`) passed in 1142 s
against Oracle AI Database 26ai Free 23.26.4.0.0 in a container with default
settings (ready after 160 s), on a shared box. After a 720 s settle the heartbeat
of the database was in VictoriaMetrics, nothing but `Watchdog` fired and nothing
was pending, the dead-man receiver got
`Watchdog` six times 60 s apart, and 18 panels of the Oracle dashboard had data;
5 are empty by design (below). The Collector log had two lines with "error":
the two `CDB_PROCEDURES` warnings of step 2. It does not exercise a database on
another host than a container, the alert log, a standby or broker, a PDB-only
service, 19c, RAC or ASM, a Collector as a host binary with these packs, or
Oracle Linux packages of any kind.

## What you need

- An Oracle container database (a CDB, with PDBs or none), 19c or later,
  and SYSDBA access to its root on the primary. A non-CDB is not covered: the
  accounts are common users (`C##` prefix). The queries of the packs also ran
  as SQL*Plus statements on 19.32, 19.33 and 26ai (23.26.3) primaries of the lab
  on 2026-11-24 ([`packs/oracledb-dg/README.md`](https://github.com/msavdert/obenhub/blob/main/packs/oracledb-dg/README.md),
  "Oracle version"); this page's test is the first run of the Collector
  against a database the lab did not provision.
- `sqlplus` on a host that reaches the database as SYSDBA, or `docker exec` into
  an Oracle container as the test does.
- The listener reachable from the Collector, and the service name of the CDB
  root (`FREE` in the test), not a PDB service: the receiver reads the
  per-container views from the root.
- `remote_login_passwordfile` EXCLUSIVE or SHARED, because the second account
  logs in `AS SYSDG`, which Oracle checks against the password file (ADR 0008
  decision 4). The Free image runs with the value printed in the test's log
  (`oracle: remote_login_passwordfile = ...`).
- Memory for what you start. The test refuses to start with less than 4 GiB of
  `MemAvailable` (an assumption, from memory and not checked here: Oracle Free's own limit
  is 2 GiB of RAM for the instance); the Free container used 2.3 GiB in the recorded run.

## 1. The backend

Step 1 of the [index](index.md#1-the-backend), then tell vmalert what you
expect. The shipped `deploy/compose/inventory.yml` expects one PostgreSQL
(`pg-1`) and would alert on its absence; replace the `obenhub.expected_target`
record by the Oracle database (the Collector's own record stays) and reload:

```sh
cd deploy/compose
# in inventory.yml
#   - record: obenhub.expected_target
#     expr: label_set(vector(1), "service.namespace", "obenhub", "service.name", "oracledb",
#                     "obenhub.cluster.name", "main", "service.instance.id", "ORCL",
#                     "obenhub.collector", "otelcol-host-1")
docker compose kill -s SIGHUP vmalert
```

`obenhub.cluster.name` and `service.instance.id` are the values of
`OBENHUB_CLUSTER_NAME` and `OBENHUB_ORACLE_DB_UNIQUE_NAME` below. The test writes
the file in place (it is bind-mounted; an editor that replaces the file leaves
the container with the old one) and signals vmalert before the Collector starts.

If the Collector runs as a container on the backend's network, give `tls.sh` the
name `gateway` too, as the [container page](container.md) explains.

## 2. The monitoring users

[`deploy/oracle/monitoring-user.sql`](https://github.com/msavdert/obenhub/blob/main/deploy/oracle/monitoring-user.sql)
creates two common users and a profile. The passwords are read from standard
input by two `ACCEPT` commands, so they are in no command line and no file; they
are 12 to 30 letters and digits (Oracle allows 30, ORA-00972). On the database
host, as the Oracle software owner, from the repository root:

```sh
printf '%s\n%s\n' "$MON_PASSWORD" "$DG_PASSWORD" \
  | sqlplus -s -L / as sysdba @deploy/oracle/monitoring-user.sql
```

The test runs the same file inside the container (`docker cp` of the file, then
the same `printf` into `docker exec -i ... sqlplus`) and fails on an error. It
prints `created profile`, `created user` twice and `granted SYSDG`; a second run
prints `reset password of` for both users (the script is safe to run again). On
a terminal the passwords would be echoed: pipe them in. Input that ends early, an empty
line, or a password that is not 12 to 30 letters and digits stops the script with a
non-zero exit status before any change (shown on a Free container).

| Created | What it holds | Why |
| --- | --- | --- |
| Profile `C##OBENHUB_MON` | `PASSWORD_LIFE_TIME`, grace, reuse time and reuse max all `UNLIMITED` | An expired monitoring password is ORA-28001 at the next login, and the receivers' pooled sessions hide it until they restart (ADR 0008 decision 4, scenario `password-expired`) |
| `C##OBENHUB_MON` | `CREATE SESSION`; `SELECT` on 17 single `V_$` and `DBA_`/`CDB_` views (the list of the oracledb receiver README at contrib v0.164.0); `CONTAINER_DATA=ALL` | The `oracledb` receiver. No role and no `SELECT ANY`. From the root it then sees every container: the test checks that `V$CON_SYSSTAT` and `V$CONTAINERS` count the same containers (3 on Free) |
| `C##OBENHUB_DG` | `SYSDG` only | The `sql_query` receivers of the packs, which log in `AS SYSDG` |

Do you need the second user on a database with no standby? Yes. The heartbeat,
role and open mode, protection level, fast-start failover state and RMAN queries
of the packs run through it (`packs/oracledb-dg/queries.yaml`, `queries-primary.yaml`,
`packs/oracledb-backup/queries.yaml`), and the account-state query reads
`DBA_USERS` through it so that an expired `C##OBENHUB_MON` is seen even while
the receivers' pooled sessions live. `SYSDG` is more than reading (it can stop
apply or fail over); the lab accepts that for this user only (ADR 0008
decision 4). The script is run on the primary
only: on a Data Guard pair the users reach the standby through redo, and a
`SYSDG` login on the standby is checked against its password file, which must
match the primary's (ADR 0008 decision 4; the lab's `provision.sh` copies it).

What changes on the database, all of it from that script: the profile, the two
users, the grants. No parameter, no restart, no package. What it leaves alone:
the Diagnostics and Tuning Pack views (the packs read none, ADR 0008 decision 6),
ASM, and the receiver's events (query samples, top queries), which are off. The
receiver therefore logs two warnings at start, `CDB_PROCEDURES not readable` and
`CDB_PROCEDURES/CDB_OBJECTS not readable`: those two views are only for the events
([receiver README at v0.165.0](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.165.0/receiver/oracledbreceiver/README.md),
"CDB-root connections"; the test's log shows exactly these two lines and no other
error).

The users and the grants come from the lab's
[`mon-lib.sh`](https://github.com/msavdert/obenhub/blob/main/lab/oracle/scripts/mon-lib.sh),
which `provision.sh` still runs for the lab. `mise run lint:oracle-user-sql`
(part of `mise run check`) fails when the two grant lists differ.

## 3. The Collector

The files are laid out as [the VM page](vm.md#3-the-files-of-the-packs) lays
them out, with the packs `collector`, `oracledb-dg` and, if you take RMAN
backups, `oracledb-backup`, and the variables in
[`deploy/collector/obenhub-oracle.env.example`](https://github.com/msavdert/obenhub/blob/main/deploy/collector/obenhub-oracle.env.example)
(each variable is explained in the "Collector fragment" table of
`packs/oracledb-dg/README.md`). The fragment of the `oracledb-dg` pack holds the
`oracledb` receiver (30 s), the `sql_query` receivers (15 s, `SYSDG`), a TCP
probe of the listener and the alert log reader; the backup fragment adds one
`sql_query` receiver (60 s) over the same connection. Both read their query files
from `/etc/otelcol-contrib/packs/<pack>/`.

The test starts the Collector as a container on the Oracle container's network.
The image is the gateway's, as in the [container page](container.md), and the
packs are copied into a scratch directory:

```sh
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' deploy/compose/compose.yaml)"
oc="$(mktemp -d)"
install -d "$oc/packs" "$oc/tls"
cp packs/otelcol-base.yaml "$oc/packs/"
for p in collector oracledb-dg oracledb-backup; do cp -r "packs/$p" "$oc/packs/"; done
cp deploy/collector/otelcol-tls.yaml "$oc/"
cp deploy/collector/obenhub-oracle.env.example "$oc/obenhub.env"
cp deploy/compose/tls/ca.crt deploy/compose/tls/client.crt deploy/compose/tls/client.key "$oc/tls/"
chmod 0600 "$oc/obenhub.env"
# edit $oc/obenhub.env: gateway endpoint, cluster name, db_unique_name, host, service,
# the two passwords and the alert log path (in an editor: a password typed in a sed
# command is in the process list)
( umask 077; sed -n "s/^\([A-Z_0-9]*\)='\(.*\)'$/\1=\2/p;t;/^[A-Z_0-9]*=/p" "$oc/obenhub.env" > "$oc/docker.env" )
docker run -d --name otelcol --network <the Oracle container's network> --user "$(id -u):$(id -g)" \
  --env-file "$oc/docker.env" --tmpfs /var/lib/otelcol-contrib:mode=1777 \
  -v "$oc:/etc/otelcol-contrib:ro" "$OTELCOL_IMAGE" \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/oracledb-dg/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/oracledb-backup/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml
docker network connect obenhub_mon otelcol
```

As a host binary or under systemd the list of `--config` files is the same and
the rest is [the VM page](vm.md) (assumption: not run with these packs). In the
test `OBENHUB_ORACLE_HOST` is `ora`, the network alias of the Oracle container,
`OBENHUB_ORACLE_SERVICE` is `FREE`, `OBENHUB_ORACLE_DB_UNIQUE_NAME` is `FREE` and
`OBENHUB_CLUSTER_NAME` is `free`. The user name of the `sql_query` receivers is
percent-encoded in the data source URL (`C%23%23OBENHUB_DG`); the one of the
`oracledb` receiver is not (`C##OBENHUB_MON`).

Two things the test does not do. The alert log reader needs the Collector on the
database host: the log is a file (in the image, `-rw-r----- oracle:oinstall`, so
the Collector's user needs the `oinstall` group or a copy), and in the test it is
inside the Oracle container, so `OBENHUB_ORACLE_ALERT_LOG` points at a path that
does not exist and no Oracle log reaches VictoriaLogs. The host dashboard and the
journald logs of the [VM page](vm.md) are not part of this page's layout (the
`host` pack is a separate fragment).

## 4. What you should see

[Step 4 of the index](index.md#4-what-you-should-see) applies with these
differences. The wait is the longest `for:` of the `collector` and `oracledb-dg`
rules plus 120 s: 720 s (`OracleCollectionIntervalTooLong`, 10 m). The rule
`OracleBackupMissing` (30 m) is not waited for, see the table below.

1. The heartbeat is one series (the instance id is your `db_unique_name`):

   ```sh
   curl -fsS http://127.0.0.1:8428/api/v1/query \
     --data-urlencode 'query=count(last_over_time({__name__="oracledb.collection.heartbeat","service.instance.id"="ORCL","obenhub.cluster.name"="main"}[2m]))' \
     | jq -r '.data.result[0].value[1]'
   ```

2. Only `Watchdog` fires and nothing is pending, and `Watchdog` reaches the
   dead-man receiver every 60 s: the two commands of the index, unchanged.
3. The dashboard "Oracle Data Guard" (uid `obenhub-oracle-dg`) is provisioned
   from `packs/oracledb-dg/dashboards/oracle-dg.json`. The test runs every panel
   query through Grafana; from the repository root:

   ```sh
   scripts/check-panels.sh packs/oracledb-dg/dashboards/oracle-dg.json \
     http://127.0.0.1:3000 deploy/compose/.env
   ```

## Which signals need a standby, a broker or RMAN

On a database with none of them the packs stay quiet by design. The test
records the first column below as empty panels, and every alert of the pack stayed
inactive.

| Signal | On a single database | Source |
| --- | --- | --- |
| Transport and apply lag, lag data age, redo apply running, missing logs | No series: the queries return rows on a standby only. Panels "Standby lag", "Lag data age", "Redo apply running" and "Redo apply and archive gap" are empty; `OracleStandbyApplyStopped`, `OracleStandbyLag`, `OracleStandbyDataStale`, `OracleStandbyLagUnknown` and `OracleRedoGap` cannot fire | `packs/oracledb-dg/queries.yaml` comments; test run |
| Protection level | Series present, value 0: on the Free image the protection mode and level are both `MAXIMUM PERFORMANCE`, so `OracleProtectionDegraded` stays quiet | test run: the series `oracledb.dataguard.protection.degraded` is asserted to be 0, labels read in a debug run |
| Fast-start failover | Series present: `status` `DISABLED`, `enabled` 0, `observer_present` 0, `synchronized` 0. The two FSFO alerts need `enabled` 1 and so cannot fire | test run |
| Redo destinations | One series for the local destination (`VALID`, no gap); a remote destination appears when one is configured | test run |
| RMAN backup age and failure, `OracleBackupStale`, `OracleBackupFailed` | Series appear after the first completed RMAN job, as the primary only. **Without one, `OracleBackupMissing` fires 30 minutes after the first heartbeat of a primary**: that is the rule working, and it is the one alert a fresh database will show. The test takes one online `backup database` before the Collector starts and asserts that the rule's own expression returns nothing | `packs/oracledb-backup/rules.yml`; test run |
| Recovery area | No series when `db_recovery_file_dest` is unset (the Free image leaves it unset): the panel "Recovery area used, reclaimable counted as free" is empty and `OracleRecoveryAreaFull` cannot fire | `packs/oracledb-backup/queries.yaml`; test run |
| Alert log | Not run in the test, see step 3 | |

## Limits

- A CDB on its primary, one database per Collector process (the pack README).
  A standby, a pair, RAC, ASM, a non-CDB and a PDB-only connection are not
  covered here; the lab covers the CDB19 pair (`lab/oracle/README.md`).
- The Oracle test ran Collector 0.165.0, the gateway's image. The lab's own
  Oracle Collectors are pinned to 0.164.0 (ADR 0008).
- `oracledbreceiver` metrics are alpha (ADR 0008 context); the packs are tested
  on the metrics of v0.164.0 and the test saw them on v0.165.0.
- The monitoring passwords are in the Collector's environment file `obenhub.env` and in `docker.env`, both mode 0600, and the container runs as the user who owns them (`--user`), so nothing is made world-readable; the client key is copied with the mode `tls.sh` gave it (0600).

## Licence of the test image

`mise run deploy:oracle-test` pulls `container-registry.oracle.com/database/free`
by digest (Oracle AI Database 26ai Free, image label version 23.26.0, the
database reports 23.26.4.0.0), for the test only. The repository neither ships
nor redistributes it. Its terms are the Oracle Free Use Terms and Conditions,
which the image carries at `/licenses/license.txt` and Oracle publishes at
[oracle.com/downloads/licenses/oracle-free-license.html](https://www.oracle.com/downloads/licenses/oracle-free-license.html)
(read 2026-11-27): it grants internal use for developing, testing, prototyping and
demonstrating. It is a database the test runs against, like the Oracle
Database of the lab ([ADR 0008](../../adr/0008-oracle-lab-scope.md)), not
a dependency of what the repository ships ([ADR 0004](../../adr/0004-licence-policy.md)).
Your own Oracle database has your own licence.

## 5. Take it down

The backend: [step 5 of the index](index.md#5-take-it-down). The Collector:
`docker rm -f otelcol` (and `rm -rf "$oc"`). On your database the two users and the
profile stay until you drop them; the test's database is a throwaway container
and goes with it.

## Run the test yourself

```sh
mise run --skip-tools deploy:oracle-test
```

Needs Docker, `jq`, `curl`, `openssl`, 4 GiB of free memory and a pull of a
6.7 GB image on the first run; takes about 25 minutes and is not part of
`mise run check`. It appends a line to `deploy/results/runs.jsonl` and prints a
final `oracle-test: PASS in <n>s, ...` line; set `ORACLE_TEST_EVIDENCE=0` to skip
the line.
