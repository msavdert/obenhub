# Collector overhead on pg-lab: results

Measured 2026-11-26 (03:19-07:46 UTC) with `lab/overhead/setup.sh` and
`lab/overhead/run.sh` at commit dad67be, for roadmap F4: the overhead of the
current pack after its `pg_stat_activity` reads were merged into one statement
(#176). The pack measured is kept as `pack-measured/queries.yaml`: twelve
queries, sha256
`f62667b504db01e2290ce4074cc3fdd18eb0de74d8c21549daf366db6d5490b7`, the same
file as `packs/postgresql/queries.yaml` at dad67be (the run log compared the
hash of the copy the Collector read with the repository's). The previous series
(2026-11-12, nine-query pack) is summarised under "Compared with the 2026-11-12
series"; its raw data is readable at dad67be.

Tables: `./summarize.sh results/runs.csv` (TPC-B arm) and `./summarize.sh
results/runs-cpu.csv` (CPU-saturated arm); raw per-run data in `runs*.csv`,
warm-ups in `warmup*.csv`, the per-query cost of the pack in `pack-cost.csv`
(from `pgss*.csv` and `pack-measured/`, `./pack-cost.py`), block-level
statistics with `./block-stats.py results/runs*.csv`. `observations.txt` holds
side observations from the 2026-11-12 session (probe runs, `pg_test_fsync`) and
the host facts and timings taken on 2026-11-27 that this page cites.

## Conditions

- Host: pg-lab (10.0.0.13), Debian 13, kernel 6.12.111, 4 vCPU, 7.8 GB RAM,
  PostgreSQL 18.7 (PGDG), otelcol-contrib 0.165.0 (all read on the VM on
  2026-11-27, `observations.txt`), started and stopped with systemd as
  `obenhub-otelcol.service` (own cgroup). The VM had been rolled back to its
  clean snapshot; `setup.sh` installed PostgreSQL and built the database before
  the series. The data directory is on the root disk (`/dev/sdb1`); the
  2026-11-12 page measured a separate data disk (`/dev/sdb`). That the
  rollback caused the move is an assumption.
- PostgreSQL: shared_buffers 128MB and max_connections 100 (Debian defaults).
  Changed (`conf.d/90-overhead.conf`): shared_preload_libraries
  pg_stat_statements, reserved_connections 8, logging_collector on,
  log_destination jsonlog, log_timezone UTC, log_lock_waits on,
  deadlock_timeout 1s, log_min_duration_statement 1000, track_io_timing on.
  Role `otel_monitor` as in the slice 1 lab (pg_monitor,
  pg_use_reserved_connections, statement_timeout 5s).
- Collector: `otelcol.yaml`, one server on localhost: postgresql receiver on
  database postgres (with `postgresql.deadlocks` on, as in slice 1),
  `sql_query` with the whole shared pack, file_log on the jsonlog files,
  scrape interval 15 s for both metric receivers, max_open_conn 3, `debug`
  exporter (verbosity basic) instead of the Victoria stack.
- Database: pgbench scale 100 (1627 MB on 2026-11-27, after the series,
  `observations.txt`; it fits in the page cache).
- Load, two arms, both pgbench against database postgres, per-transaction log,
  percentiles nearest-rank over every transaction of the run:
  - `tpcb`: built-in TPC-B-like script, simple protocol, 8 clients, 4 threads,
    300 s per run. Host CPU busy 17% (median).
  - `cpu`: select-only (`-S`), prepared protocol, 64 clients, 4 threads, 180 s
    per run. Host CPU busy 99.8% (median, from /proc/stat, including steal and
    pgbench's own CPU); latency includes run-queue wait.
- Order: one discarded warm-up run (OFF) per arm, then ABBA blocks of
  alternating orientation (OFF ON ON OFF, ON OFF OFF ON, ...): `tpcb` 4 blocks,
  `cpu` 8 blocks, both counts fixed before the series started. Each run:
  Collector stopped (OFF) or freshly started (ON), CHECKPOINT, 60 s wait,
  `pg_stat_statements_reset()`, pgbench, Collector stopped, 30 s pause. Run
  detached; nothing else ran on pg-lab, and the lab chain on the box had
  stopped before the series began.
- Per run: PostgreSQL and Collector cgroup CPU (`cpu.stat` usage_usec delta
  over the pgbench window), Collector `memory.peak` (includes the 60 s before
  pgbench), otel_monitor sessions every 5 s, CPU steal and busy share from
  /proc/stat, mean I/O latency of the data disk, and the otel_monitor rows of
  pg_stat_statements for the window (ON runs).

## Result, TPC-B arm (8 OFF, 8 ON)

| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |
|---|---|---|---|
| tps | 408.5 (367.4-438) | 407.3 (370.1-422.8) | -1.2 |
| latency p50 ms | 15.66 (14.52-16.57) | 15.63 (14.56-16.79) | -0.02 |
| latency p95 ms | 40.55 (37.05-46.9) | 40.82 (38.99-46.2) | +0.27 |
| latency p99 ms | 82.66 (74.14-110.3) | 86.65 (75.95-102.9) | +3.99 |
| PostgreSQL CPU s | 124.1 (118.3-132.9) | 123.7 (118.2-127.6) | -0.42 |
| steal % | 5.41 (4.29-6.91) | 5.58 (4.89-6.04) | +0.18 |
| data disk await ms | 5.12 (4.84-6.14) | 5.34 (4.98-6.01) | +0.22 |

Collector (ON runs): CPU 6.98 s per run (6.68-7.37), 2.33% of one core;
memory.peak 58.5 MB (56-60.2).

Block level (n = 4, `./block-stats.py results/runs.csv`), ON mean minus OFF
mean with the 95% t-interval: tps -0.9 (-0.2%) [-13.1, +11.3]
([-3.2%, +2.8%]); p95 +0.24 ms (+0.6%) [-1.80, +2.29]; p99 +1.2 ms (+1.4%)
[-10.4, +12.9]. Block differences in tps: +10.2, -1.6, -6.9, -5.2.

Verdict: within noise; the design resolves about +-3% in tps. The load is
commit-bound and leaves most of the 4 cores idle, so the precise number of
this arm is the Collector's own CPU.

## Result, CPU-saturated arm (16 OFF, 16 ON)

| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |
|---|---|---|---|
| tps | 25570 (24770-26060) | 25240 (22320-25740) | -325 |
| latency p50 ms | 2.104 (2.081-2.127) | 2.102 (2.03-2.132) | -0.002 |
| latency p95 ms | 5.473 (5.328-5.732) | 5.588 (5.45-7.227) | +0.116 |
| latency p99 ms | 11.57 (11-13.43) | 11.96 (11.44-20.75) | +0.39 |
| PostgreSQL CPU s | 522.5 (518.7-523.7) | 518.8 (501.2-520.4) | -3.7 |
| steal % | 7.87 (7.29-9.48) | 8.15 (7.44-17.21) | +0.28 |

Collector (ON runs): CPU 3.23 s per run (3.02-3.98), 1.79% of one core,
0.45% of the 4-vCPU machine; memory.peak 59.4 MB (56.8-68.7).

Block level (n = 8, `./block-stats.py results/runs-cpu.csv`), ON mean minus
OFF mean with the 95% t-interval:

| metric | block difference | 95% interval |
|---|---|---|
| tps | -427 (-1.67%) | [-813, -41] ([-3.19%, -0.16%]) |
| p50 ms | -0.011 (-0.5%) | [-0.026, +0.003] |
| p95 ms | +0.20 (+3.6%) | [-0.03, +0.43] |
| p99 ms | +0.91 (+7.8%) | [-0.25, +2.07] |

Block differences in tps: -234, -239, -1540, -113, -362, -464, -200, -262.
All 16 ON runs are below the mean of their block's OFF runs (`summarize.sh`,
paired table). Block 3 holds ON run 10, the only run with steal above 10%
(17.2%, 22320 tps); without block 3 the mean of the other seven is -268 tps
(-1.05%). OFF run spread in tps: SD 287 (1.1% of the mean), MAD 103 (0.4%).

Verdict: at saturation the Collector costs about 1% of throughput (-1.67% with
the steal outlier, -1.05% without it), and the 95% interval excludes zero. The
2026-11-12 series could not resolve this (OFF spread 7.7%, interval
[-6.1%, +0.8%]); this one had steady steal (7.3-9.5% in 31 of 32 runs) and a
1.1% OFF spread. The size is plausible from the CPU taken: the Collector process
1.8% of one core, plus the pack and receiver statements inside PostgreSQL
(11 ms per second, about 1.1% of one core, below), together about 2.9% of one
core, or 1.0% of the 2.9 cores PostgreSQL used: the same order as the loss (an
accounting check, not a model). p95 and p99 are higher on ON with intervals
that contain zero.

## Cost of the pack's own queries (pg_stat_statements)

`pack-cost.csv` has one row per statement of role otel_monitor and arm. Times
are pg_stat_statements `total_exec_time` and `mean_exec_time` over the window
of every ON run (execution only; track_planning is off). Labels are the first
metric of the pack query; `receiver` rows are the postgresql receiver's own
statements. Every pack query ran once per scrape (20 calls per 300 s run, 12
per 180 s run). The mean columns are over all calls; the share column is
`pct_of_pack_exec`, the median over ON runs of the query's share of the pack's
execution time, so a query with one slow call can show a high mean and a 0.0%
share.

| pack query (first metric) | tpcb mean ms | cpu mean ms | cpu share of pack |
|---|---|---|---|
| postgresql.statement.execution_time | 2.597 | 45.540 | 48.4% |
| postgresql.statement.deallocation | 1.900 | 27.550 | 30.4% |
| postgresql.snapshot.oldest_age | 0.270 | 8.916 | 10.7% |
| postgresql.replication.synchronous_standby.required | 0.108 | 4.112 | 5.2% |
| postgresql.lock.waiting_session.count | 0.233 | 3.354 | 3.7% |
| postgresql.archiver.archived_file | 0.073 | 0.967 | 1.0% |
| postgresql.database.xid_age | 0.020 | 0.532 | 0.5% |
| postgresql.recovery.active | 0.014 | 0.244 | 0.0% |
| postgresql.replication_slot.active | 0.019 | 0.121 | 0.0% |
| postgresql.subscription.enabled | 0.010 | 0.165 | 0.0% |
| postgresql.subscription.conflict | 0.009 | 0.224 | 0.0% |
| postgresql.collection.heartbeat | 0.007 | 0.007 | 0.0% |

Per second, the pack executes for 0.34 ms (tpcb) and 5.8 ms (cpu); the
receiver's statements for 0.19 ms and 5.4 ms (its per-table statistics query
alone averages 35 ms at saturation). The Collector process used 23 ms (tpcb)
and 18 ms (cpu) of CPU per second.

The two `pg_stat_statements` queries are 86% (tpcb) and 79% (cpu) of the
pack. Both run the same guard (`pg_extension` and a `pg_settings` lookup of
`shared_preload_libraries`), so each scrape pays the settings scan twice. On
pg-lab, idle, on 2026-11-27 (psql `\timing`, three tries each, raw lines in
`observations.txt`): the `pg_settings` lookup took 2.7-4.3 ms (`EXPLAIN
ANALYZE`: a function scan of `pg_show_all_settings()` removing 404 rows,
2.9 ms execution); `SELECT dealloc FROM pg_stat_statements_info` 0.3-0.7 ms;
the totals query's own read of `pg_stat_statements` (37 entries) 1.8-2.4 ms.
These are client-side times including the round trip (a bare `SELECT now()`
took 4.8 ms in the same session), so they rank the parts but are not
comparable with the pg_stat_statements means above. By that ranking the
guard is most of the deallocation query and at least as large as the view read
in the totals query. The `pg_extension` part of the guard was not timed, and
the split at saturation was not measured.

The merged `pg_stat_activity` statement (label `snapshot.oldest_age`;
before PR #176 the same metrics took six `pg_stat_get_activity` scans in three
statements, per the #176 commit message) averages 0.27 ms on TPC-B and 8.9 ms at
saturation. The 2026-11-12 pack read the view in two statements (snapshot and
idle transaction, 0.24 ms and 7.8 ms together) that covered fewer metrics. The
pre-#176 pack with three statements was never measured, so this series gives
the cost of the merged statement, not the saving of the merge.

## F6: one statement and a cheaper guard

Roadmap F6 merged the two `pg_stat_statements` queries into one statement and
replaced the `pg_settings` lookup in the guard by `pg_has_role()` and
`current_setting('shared_preload_libraries')` (`packs/postgresql/queries.yaml`;
the unit tests are `mise run packs:sql-test`). Measured 2026-11-27 (08:14-08:51
UTC on the box clock) on pg-lab, same host, load definitions and
`measure-run.sh` as above, but a smaller run: ON runs only, no OFF runs, two
runs per pack and arm, the 2026-11-26 pack (`f6/old/pack-measured`) and the F6
pack (`f6/new/pack-measured`) alternating in one session (tpcb: old new new
old at 300 s; cpu: new old old new at 180 s; 20 s wait before pgbench instead
of 60 s). Raw rows and summaries: `f6/old` and `f6/new` (`pgss*.csv`,
`runs*.csv`, `pack-cost.csv` by `./pack-cost.py f6/<pack> f6/<pack>/pack-measured/queries.yaml`).
The new pack file differs from the one that ran in comments and in one
later addition, a `to_regclass('pg_stat_statements_info')` branch for
extension versions before 1.9 that adds one catalog lookup per scrape (not
measured; the SQL of the measured statement is otherwise unchanged). The journal of every run has no error line and the one feature-gate
warning per start.

The host was noisier than on 2026-11-26 (CPU steal 9-29% against 4-7%, tpcb
tps 245-334 against 367-438), so the same-session old rows, not the 2026-11-26
means, are the control. Mean execution time of the statements of role
otel_monitor, ms per call (statement query, 20 calls per tpcb run and 12 per
cpu run, 40 and 24 calls per pack):

| | 2026-11-26 (F4, 8 runs) | old pack today (2 runs) | F6 pack today (2 runs) |
|---|---|---|---|
| tpcb, totals query | 2.597 | 3.376 | 1.786 (one statement) |
| tpcb, deallocation query | 1.900 | 2.289 | (in the same statement) |
| tpcb, both together | 4.497 | 5.665 | 1.786 |
| cpu, totals query | 45.540 | 36.488 | 22.445 (one statement) |
| cpu, deallocation query | 27.550 | 24.668 | (in the same statement) |
| cpu, both together | 73.090 | 61.156 | 22.445 |
| pack execution per second, tpcb / cpu | 0.34 / 5.8 ms | 0.44 / 6.09 ms | 0.18 / 3.36 ms |

Against the same-session old pack the statement cost fell 68% (tpcb) and 63%
(cpu), and the pack's execution per second 58% (tpcb) and 45% (cpu); the
receiver's statements were unchanged (0.30 against 0.26 ms per second on tpcb,
6.52 against 6.41 on cpu). Two runs per arm and pack is a small sample (the cpu
means have max values of 70-120 ms), so read the ratios as an order of
magnitude, not as a precise saving. That the saving comes from the guard and
the second read rather than the view read itself was not separated: the
statement now runs one `pg_extension` lookup, one `current_setting()` and one
`pg_stat_statements` read where it ran two of each, and the new `UNION ALL`
adds one `pg_stat_statements_info` read inside the same statement.

## Compared with the 2026-11-12 series

Same VM and load definitions; `setup.sh` (installs PostgreSQL) and
`measure-run.sh` (finds the data disk with `findmnt -T`, so disk await is
read on the root disk now) changed in between. The pack grew from nine to
twelve queries (`pg_stat_statements` totals and deallocation, archiver,
synchronous standby; the `pg_stat_activity` merge) and the Collector from
0.164.0 to 0.165.0.

| | 2026-11-12 | 2026-11-26 |
|---|---|---|
| pack execution, ms per s (tpcb / cpu) | 0.030 / 0.52 | 0.34 / 5.8 |
| receiver execution, ms per s (tpcb / cpu) | 0.18 / 5.4 | 0.19 / 5.4 |
| Collector CPU, % of one core (tpcb / cpu) | 2.0 / 1.65 | 2.33 / 1.79 |
| Collector memory.peak MB, tpcb median | 68.9 | 58.5 |
| TPC-B tps, OFF median | 470.6 | 408.5 |
| cpu arm tps, block difference (95% interval) | -2.7% [-6.1%, +0.8%] | -1.67% [-3.19%, -0.16%] |

The pack's own execution grew about elevenfold, almost all from the two
`pg_stat_statements` queries; the receiver's is unchanged. The Collector
process grew by 0.1-0.3 points of one core. Lower memory.peak was not
investigated (the Collector version and the run environment changed together).
TPC-B throughput is not comparable across the series: the data directory
moved from a separate data disk to the root disk, and the TPC-B load is commit-bound, so it follows that disk's synchronous write
latency (assumption, as in 2026-11-12; no `pg_test_fsync` was run this time).

## Evidence that ON runs collected

Every ON run: 3 otel_monitor sessions at mid-run (cpu arm: 3-4), 20-21 (tpcb)
and 14-19 (cpu) debug-exporter metric batches in the window, and every pack
query in pg_stat_statements once per scrape. Every OFF run: Collector inactive
and 0 otel_monitor sessions. The Collector's journal over the series (counted
on 2026-11-27, `observations.txt`) has no error line and one warning per ON
start (24), the postgresql receiver's notice that feature gate `receiver.postgresql.separateSchemaAttr` is not enabled.

## Caveats

- One server, one pgbench database, 128MB shared_buffers, no standby, the
  `debug` exporter instead of the Victoria stack: export cost is not in the
  Collector CPU here.
- On this primary the slot, subscription, conflict and synchronous standby
  queries return no rows, so their cost is that of an empty result.
- `pg_stat_statements` here holds pgbench's few statements; a server with
  thousands of distinct statements makes the totals query read more rows (not
  measured).
- File logging is barely exercised: log_min_duration_statement 1000 produces
  almost no log lines under either load.
- The CPU-saturated arm shares the 4 vCPUs between PostgreSQL, pgbench and the
  Collector; latency percentiles include run-queue wait. A real saturated
  server has its clients elsewhere.
- Steal and disk await see only what reaches this VM.
