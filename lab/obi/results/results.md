# OBI v1.0.0 against PostgreSQL 18: results

Measured 2026-11-07 on pg-lab; tables come from `lab/obi/analyze.py` (full
output: `analysis.md`). Question: what does OBI report for pgbench directly
against PostgreSQL and through PgBouncer (simple, extended, prepared), next to
pgbench's own latency?

- For simple and extended protocol OBI reports every `UPDATE`, `SELECT` and
  `INSERT` on three sides (pgbench, PgBouncer, PostgreSQL); its mean at pgbench
  is within 0.02 ms of pgbench's own `-r` mean (0.05 ms below with TLS).
- It never reports `BEGIN` or `END`. The statements it does report are
  10-16% of the `-r` transaction time in the cells with data (11.8% direct extended: 1.141 of 9.64
  ms); the 8-10 ms commit is invisible.
- Direct `-M prepared`: no data (OBI attaches to pgbench 7.2 s after it starts,
  after the statements were prepared). PgBouncer adds 0.09-0.11 ms per statement.

## What ran

| component | version | source |
|---|---|---|
| OBI | v1.0.0, revision d23be0d6b (its startup log) | release tarball `obi-v1.0.0-linux-amd64.tar.gz`, checked against the release `SHA256SUMS`; binary sha256 `b239d223...4462` |
| PostgreSQL, pgbench | 18.6 (PGDG), cluster `main` on 5432, pgbench scale 100, 4 vCPU Debian 13, kernel 6.12.113 | settings as in `lab/overhead/results/results.md` |
| PgBouncer | 1.26.1 (`1.26.1-1.pgdg13+1`) | PGDG apt; transaction pooling, `default_pool_size = 5`, `max_prepared_statements = 200` (needed for `-M prepared` through transaction pooling since 1.21; 0 breaks it), `server_tls_sslmode = disable` |
| Collector | otelcol-contrib 0.164.0 | OTLP/HTTP in, `file` exporter out (keeps every cumulative point) |

`tpcb-late.sql` (diagnostic cell) is pgbench's built-in TPC-B-like script plus a
sleep: `src/bin/pgbench/pgbench.c`, postgres/postgres tag REL_18_6 (commit
724edf9bde9d356724ad384a2e196edc3c9f80f7), PostgreSQL License.

## Method

- Load: `pgbench -n -M <protocol> -c 8 -j 4 -R 250 -T 80 -r --log`, role
  `obi_bench` over TCP, `PGSSLMODE=disable` except the TLS cell. OBI restarted
  before every cell, started 10 s before pgbench; CHECKPOINT and 20 s pause
  between cells; one run per cell. Order (from `t0`): direct extended OBI off,
  direct simple, extended, prepared, bouncer simple, extended, prepared,
  direct extended TLS, direct prepared late.
- OBI: discovery by full executable path; metrics only (no traces endpoint,
  no shared `OTEL_EXPORTER_OTLP_ENDPOINT`); 5 s interval; histogram bounds
  0.1 ms to 1 s (defaults 0, 5, 10, 25 ms are too coarse).
- Window: each service exports on its own 5 s phase; it is counted from its last
  export at or before pgbench second 20: pgbench from about 17.2 s
  (63 s), PgBouncer from about 15.2 s (65 s), postgres from 15.2-17.5 s
  depending on the cell (`analysis.md` section B).
  pgbench percentiles: nearest rank, with schedule lag; `-r` means: whole run;
  OBI percentiles: bucket-interpolated (approximate).

## What OBI attached to

From `cells/*/obi.log`, identical in all eight cells with OBI on:

- PostgreSQL postmaster `/usr/lib/postgresql/18/bin/postgres`: 7.8 s before
  pgbench started; the only attach line for PostgreSQL, backends appear as
  `service=postgres` instances (5 through PgBouncer, 8 direct).
- `/usr/sbin/pgbouncer`: 5.9 s before pgbench started.
- `/usr/lib/postgresql/18/bin/pgbench`: 7.2 s after pgbench started.

Full paths are used because pg-lab also runs `postgresql-src18.service`
("PostgreSQL 18 source build (/usr/local/pgsql, port 5433)", on 127.0.0.1:5433
and 10.0.0.13:5433, seen over ssh by the coordinator); a `*/postgres` glob
attached to it during setup (log not kept). OBI exported
`db.client.operation.duration`, `db.server.operation.duration` and
`target.info`; the Collector's trace and log files stayed 0 bytes.

## Transactions, pgbench's view (window of 63 s)

| cell | OBI | tps | avg ms | p50 ms | p95 ms | p99 ms | lag ms | OBI CPU s / 80 s |
|---|---|---|---|---|---|---|---|---|
| direct simple | on | 252.2 | 55.19 | 9.98 | 326.19 | 941.12 | 42.6 | 5.8 |
| direct extended | on | 249.9 | 16.33 | 8.83 | 23.71 | 310.96 | 6.6 | 7.1 |
| direct prepared | on | 249.7 | 10.61 | 8.02 | 19.61 | 51.53 | 1.8 | 1.9 |
| bouncer simple | on | 251.0 | 16.26 | 9.56 | 36.22 | 194.68 | 5.6 | 11.3 |
| bouncer extended | on | 249.0 | 25.05 | 10.26 | 110.02 | 361.07 | 13.2 | 14.5 |
| bouncer prepared | on | 244.2 | 31.09 | 9.67 | 156.91 | 528.13 | 19.6 | 13.7 |
| direct extended | off | 248.0 | 14.24 | 7.96 | 25.94 | 227.04 | 5.0 | 0 |
| direct extended, TLS | on | 251.5 | 15.46 | 9.57 | 25.86 | 203.34 | 5.1 | 5.9 |

Eight cells held 244-252 tps against the 250 rate. The late cell (OBI on, not
in the table) did not: 222.7 tps in the window, 188.4 over the run, schedule
lag 16 s, never caught up after the 12 s sleep; only OBI against `-r` inside
it is used. Transaction time as
pgbench measured it (sum of `-r` means): direct 8.9-11.8 ms, through PgBouncer
10.5-11.5 ms, of which `END;` is 7.95-10.4 ms (4.3 in the late cell). Through
PgBouncer `BEGIN` costs 0.94-1.28 ms (0.13-0.19 direct): the wait for a pooled
server connection (pool 5, 8 clients). Averages and tails are noisy (direct
simple: 55 ms average, normal p50; cause unknown, its steal 0.40% is the cells'
highest but within their 0.08-0.40% range); the medians, 8.0-10.3 ms, are the
stable part.

## Statements: pgbench, OBI and each hop

Mean SELECT latency in ms (others: `analysis.md` section C). `-r`: whole run;
OBI columns: each service's own window. "bouncer in" is PgBouncer's
`db.server.operation.duration`, "bouncer out" its `db.client.operation.duration`,
"postgres" the backend's `db.server.operation.duration`.

| cell | statement | pgbench -r | OBI pgbench | bouncer in | bouncer out | postgres |
|---|---|---|---|---|---|---|
| direct simple | SELECT | 0.186 | 0.175 | - | - | 0.079 |
| direct extended | SELECT | 0.184 | 0.174 | - | - | 0.087 |
| direct prepared | SELECT | 0.124 | no data | - | - | no data |
| direct prepared, late | SELECT | 0.133 | 0.117 | - | - | 0.036 |
| bouncer simple | SELECT | 0.274 | 0.264 | 0.182 | 0.167 | 0.082 |
| bouncer extended | SELECT | 0.292 | 0.284 | 0.199 | 0.183 | 0.094 |
| bouncer prepared | SELECT | 0.233 | 0.223 | 0.142 | 0.127 | 0.047 |
| direct extended, TLS | SELECT | 0.294 | 0.239 | - | - | 0.453 (35% of calls) |

Cross-service differences are approximate (windows differ by about 2 s, call
sets differ). Bouncer simple at face value: 0.08 ms pgbench to PgBouncer, 0.015
inside it, 0.085 to PostgreSQL, 0.082 in PostgreSQL.

## What OBI saw and missed

OBI count divided by what pgbench issued in the same window (UPDATE 3, SELECT 1,
INSERT 1, BEGIN 1, END 1 per transaction). Wherever there was data without TLS,
UPDATE, SELECT and INSERT are within 0.3% of 1.000 on every service (largest
1.003, late cell, PostgreSQL side); window edges are the suspected cause, not
tested. Per-operation counts, means and p50/p95: `analysis.md` sections B, D.

- `BEGIN` and `END` are never reported (ratio 0 in all cells), under no name.
  Issue #3703 (COMMIT/ROLLBACK, per the roadmap) was not checked.
- `PREPARED STATEMENT` appears exactly twice per transaction in prepared cells
  with data, mean matching pgbench's (`BEGIN` + `END`) / 2: late 2.19 ms vs
  2.21, bouncer prepared 5.05 vs 4.88. That it is `BEGIN`/`END` is an inference.
- Direct prepared reported nothing from any service although OBI logged
  pgbench as instrumented. Evidence: pgbench prepares each statement in its
  first transaction, OBI attaches 7.2 s later, and the late cell (clients
  sleep 12 s first) gives full data. OBI's docs say statements prepared before
  OBI starts may lack query text; "starts" has to mean "attaches to the process".
- Through PgBouncer with `-M prepared` OBI did name pgbench's statements
  although `Parse` preceded attachment; why is not known.
- TLS (direct, extended): pgbench side complete; PostgreSQL side saw 34-36% of
  calls, its means (UPDATE accounts 1.04 ms vs 0.19 without TLS) a biased
  sample. Cause not investigated.

## Indicative overhead pair (direct extended)

One pair: the OBI-off cell ran first of all cells, on fresher tables; the OBI-on
cell third. Direction plausible, magnitude not established.

| | OBI off | OBI on |
|---|---|---|
| txn avg / p50 / p95 / p99 ms | 14.24 / 7.96 / 25.94 / 227.04 | 16.33 / 8.83 / 23.71 / 310.96 |
| `-r` SELECT / UPDATE accounts ms | 0.150 / 0.254 | 0.184 / 0.287 |
| `-r` BEGIN / END ms | 0.134 / 8.088 | 0.186 / 8.313 |

The seven statements are one correlated run, not seven samples; the ON cells'
own p50 spread (8.0-10.3 ms) is as large as the p50 difference. OBI used 7.1 s
of CPU in the 80 s run (9% of one core), 5.8 s in direct simple, 11.3-14.5 s
in the PgBouncer cells (four observations per statement), 1.9 s in direct
prepared (no events); the Collector 0.02-0.08 s.

## Caveats and unconfirmed

- Another lab was being built on the same Proxmox host (10.0.0.11) during the
  runs (known to the coordinator, not recorded in the data): absolute latencies are noisy, comparisons hold within a cell. iowait
  17-19%, steal 0.1-0.4% everywhere.
- Late cell: UPDATE tellers/branches averaged 11.9 and 19.1 ms vs a 0.28 ms
  UPDATE p50; lock waits during catch-up are an inference, not measured.
- Unconfirmed: the cause of the 7.2 s attach delay (no setting found in the
  docs read, none tried), why `BEGIN`/`END` are missing, why PgBouncer-prepared
  statements were named, the TLS shortfall, the cause of the 0.3%.
- Not tested: drivers/ORMs, TLS PgBouncer to PostgreSQL, several client
  processes, pool sizes, repeats, OBI config v2, OBI memory.
- Script edits after the kept run (`setup.sh`, `measure-cell.sh` attach
  assertion, `run.sh` comments, `analyze.py` guard) do not change what was
  measured; `analysis.md` is unchanged.

Reproduce: `lab/obi/setup.sh`, `lab/obi/run.sh` (about 20 minutes, changes only
pg-lab), `lab/obi/analyze.py`. Raw data: `cells/`, `metrics.jsonl.gz`.
