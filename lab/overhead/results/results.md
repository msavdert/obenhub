# Collector overhead on pg-lab: results

Measured 2026-11-12 with `lab/overhead/setup.sh` and `lab/overhead/run.sh`, with
the shared PostgreSQL pack as of commit 5266555 (`lab/packs/postgresql/
queries.yaml`, sha256 `c5b2401f4ff5...`, nine queries, ADR 0006 names). The
first measurement (2026-11-07, three-query pack) is kept in
`2026-11-07-old-pack/` for comparison and is not the current result.

Tables: `./summarize.sh --from-block 2 results/runs.csv` (TPC-B arm) and
`./summarize.sh --from-block 2 results/runs-cpu.csv` (CPU-saturated arm); raw
per-run data in `runs*.csv`, warm-ups in `warmup*.csv`, the per-query cost of
the pack in `pack-cost.csv` (from `pgss*.csv`, `./pack-cost.py`).

## Conditions

- Host: pg-lab (10.0.0.13), Debian 13, kernel 6.12.113, 4 vCPU, 7.8 GB RAM,
  PostgreSQL 18.6 (PGDG), otelcol-contrib 0.164.0 (tarball, sha256 verified
  against the release's `.sha256` file), started and stopped with systemd as
  `obenhub-otelcol.service` (own cgroup).
- PostgreSQL: shared_buffers 128MB and max_connections 100 (unchanged Debian
  defaults). Changed (`conf.d/90-overhead.conf`): shared_preload_libraries
  pg_stat_statements, reserved_connections 8, logging_collector on,
  log_destination jsonlog in /var/log/postgresql, log_timezone UTC,
  log_lock_waits on, deadlock_timeout 1s, log_min_duration_statement 1000,
  track_io_timing on. Role `otel_monitor` as in the slice 1 lab (pg_monitor,
  pg_use_reserved_connections, statement_timeout 5s).
- Collector: `otelcol.yaml`, one server on localhost: postgresql receiver on
  database postgres (with the optional `postgresql.deadlocks` metric on, as in
  slice 1), `sql_query` with the whole shared pack (`${file:...}`), file_log
  on the jsonlog files, scrape interval 15 s for both metric receivers,
  max_open_conn 3, `debug` exporter (verbosity basic) instead of the Victoria
  stack. Each ON run therefore makes about one scrape of every pack query per
  15 s (20 per 300 s run, 12 per 180 s run).
- Database: pgbench scale 100, 2144 MB after the series (larger than
  shared_buffers; the whole database fits in the page cache of the 7.8 GB VM).
- Load, two arms, both pgbench 18.6 against database postgres, per-transaction
  log, percentiles nearest-rank over every transaction of the run:
  - `tpcb` (the original arm): built-in TPC-B-like script, simple protocol,
    8 clients, 4 threads, 300 s per run. PostgreSQL used 0.37-0.45 of the 4
    cores.
  - `cpu` (new): select-only (`-S`), prepared protocol, 64 clients, 4
    threads, 180 s per run, chosen after a 30 s probe (32 clients left 6-12%
    idle, 64 left 0%). Host CPU busy 99.9% (median, from /proc/stat, including
    steal and pgbench's own CPU), PostgreSQL 2.7-2.9 of the 4 cores. Latency
    here includes run-queue wait.
- Order, both arms: one discarded warm-up run (OFF), then four ABBA blocks of
  alternating orientation (OFF ON ON OFF, ON OFF OFF ON, ...); the `cpu` arm
  was extended to eight blocks (16 OFF, 16 ON) because four were not
  conclusive. Each run: Collector stopped (OFF) or freshly started (ON),
  CHECKPOINT, 60 s wait, `pg_stat_statements_reset()`, pgbench, Collector
  stopped, 30 s pause. Wall-clock: `cpu` 17 + 16 runs at about 4.7 min, `tpcb`
  17 runs at about 6.6 min, about 4.5 h in all, run detached with
  `systemd-run --user`.
- Per run: PostgreSQL and Collector cgroup CPU (`cpu.stat` usage_usec delta
  over the pgbench window), Collector `memory.peak` (includes the 60 s before
  pgbench), otel_monitor sessions every 5 s, CPU steal and total busy share
  from /proc/stat, mean I/O latency of the data disk /dev/sdb, and the
  otel_monitor rows of pg_stat_statements for the window (ON runs).

## Result, TPC-B arm (8 OFF, 8 ON, medians and min-max)

| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |
|---|---|---|---|
| tps | 470.6 (456.9-495) | 483.6 (440-552.8) | +13 |
| latency mean ms | 16.99 (16.15-17.49) | 16.53 (14.46-18.17) | -0.46 |
| latency p50 ms | 13.86 (13.33-14.68) | 13.68 (12.12-14.51) | -0.18 |
| latency p95 ms | 31.44 (29.61-32.26) | 30.52 (26.06-34.56) | -0.92 |
| latency p99 ms | 62.58 (59.55-69.48) | 60.72 (52.24-76.21) | -1.85 |
| failed transactions | 0 | 0 | 0 |
| PostgreSQL CPU s per run | 118.3 (109.8-134.8) | 117.5 (110.4-132.3) | -0.8 |
| CPU steal % | 2.83 (1.63-5.91) | 2.64 (1.55-4.17) | -0.19 |
| data disk await ms | 4.47 (4.40-4.68) | 4.39 (3.89-4.85) | -0.08 |

Collector only (ON runs): CPU 5.89 s per 300 s run (5.43-6.76), memory.peak
68.9 MB (66.4-70.3), 3 otel_monitor sessions, 20-22 exporter batches per run.
That is 2.0% of one core and 5.1% of PostgreSQL's CPU (median of per-run
ratios).

Paired ABBA difference (each ON run minus the mean of the two OFF runs in its
block):

| pairs | n | d tps min / median / max | d p50 ms | d p95 ms | d p99 ms |
|---|---|---|---|---|---|
| blocks 1-4 | 8 | -19.65 / +2.65 / +79.85 | -1.81 / -0.01 / +0.12 | -5.16 / -0.16 / +2.67 | -9.37 / -1.89 / +13.11 |
| blocks 2-4 | 6 | -19.65 / +0.10 / +51.45 | -1.33 / +0.08 / +0.12 | -2.79 / +0.38 / +2.67 | -6.06 / -1.89 / +13.11 |

Verdict: within noise. The ON-OFF differences have both signs and the spread
between pairs (about 4% in tps) is larger than any median difference. The
database is commit-bound here (see Caveats), so the load leaves 3.5 cores idle
and says little about CPU contention; the `cpu` arm is for that.

## Result, CPU-saturated arm (16 OFF, 16 ON, medians and min-max)

| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |
|---|---|---|---|
| tps | 30090 (24040-32860) | 30340 (23810-33100) | +248 |
| latency mean ms | 2.12 (1.94-2.64) | 2.10 (1.93-2.66) | -0.02 |
| latency p50 ms | 1.93 (1.81-1.99) | 1.93 (1.85-2.01) | +0.01 |
| latency p95 ms | 4.16 (3.74-6.80) | 4.30 (3.73-6.72) | +0.13 |
| latency p99 ms | 7.11 (6.18-17.56) | 7.28 (6.00-16.48) | +0.17 |
| failed transactions | 0 | 0 | 0 |
| PostgreSQL CPU s per 180 s run | 523.6 (485.7-527.4) | 518.8 (494.9-524.1) | -4.8 |
| CPU steal % | 2.80 (1.52-17.09) | 3.64 (1.30-16.34) | +0.84 |
| host CPU busy % | 99.88 (92.4-99.92) | 99.85 (99.6-99.94) | -0.03 |

Collector only (ON runs): CPU 2.96 s per 180 s run (2.69-3.53), memory.peak
about 69 MB (66.9-71.1), 3-4 otel_monitor sessions, 19-24 batches. That is
1.65% of one core and 0.57% of PostgreSQL's CPU.

Paired ABBA difference:

| pairs | n | d tps min / median / max | d p50 ms | d p95 ms | d p99 ms | d tps/(1-steal) |
|---|---|---|---|---|---|---|
| blocks 1-8 | 16 | -6008 / -732 / +3014 | -0.07 / -0.01 / +0.06 | -0.72 / +0.17 / +2.34 | -2.66 / +0.16 / +9.12 | -2489 / -636 / +2349 |
| blocks 2-8 | 14 | -6008 / -732 / +3014 | -0.07 / -0.00 / +0.06 | -0.55 / +0.17 / +2.34 | -1.18 / +0.16 / +9.12 | -2489 / -636 / +2349 |
| blocks 5-8 | 8 | -1256 / -43 / +1173 | -0.03 / -0.01 / +0.06 | -0.10 / +0.08 / +0.23 | -0.48 / -0.05 / +0.34 | -1041 / -31 / +1190 |

The last column is tps divided by (1 - steal share of the run), a post hoc
correction for CPU the hypervisor took away.

Verdict: not distinguishable from zero, with an upper bound the data does not
shrink below a few percent. Over all 16 pairs the median ON run is 732 tps
(2.4%) below its block's OFF mean, 10 of 16 pairs negative; the p95 median is
+0.17 ms (4%) and p99 +0.16 ms (2%). Throughput moved far more with steal than
with the Collector: run tps ranged 23.8k-33.1k and the low runs (OFF 12, ON 10,
11 and 13) are the ones with steal of 15-17%. Blocks 5-8, which had steal of
1.3-4.2%, show a median of -43 tps (0.1%) and 4 of 8 pairs below zero. The
steal correction moves the full-series median only from -732 to -636, so it
does not explain the sign; the first four blocks (the noisy ones, medians
about -2000 tps) carry the negative median. Whether the Collector costs about
0.1% or about 2% at saturation cannot be settled with 16 pairs on a VM with
this steal; the Collector's own CPU, 1.65% of one core against 4 cores
saturated (0.4% of the machine), is consistent with the lower end.

## Cost of the pack's own queries (pg_stat_statements)

`pack-cost.csv` has one row per statement of role otel_monitor and arm. Times
are pg_stat_statements `total_exec_time` and `mean_exec_time` over the
window of every ON run (execution only: parse, plan and network are not in
it; track_planning is off). Labels are the first metric of the pack query;
`receiver` rows are the postgresql receiver's own statements. All times are
milliseconds.

| pack query (first metric) | tpcb mean ms | cpu mean ms | cpu share of pack |
|---|---|---|---|
| postgresql.snapshot.oldest_age | 0.156 | 5.216 | 44.7% |
| postgresql.transaction.idle_age | 0.086 | 2.631 | 27.6% |
| postgresql.lock.waiting_session.count | 0.157 | 2.112 | 26.3% |
| postgresql.database.xid_age | 0.018 | 0.129 | 0.7% |
| postgresql.recovery.active | 0.011 | 0.102 | 0.2% |
| postgresql.replication_slot.active | 0.010 | 0.179 | 0.2% |
| postgresql.subscription.enabled | 0.009 | 0.242 | 0.2% |
| postgresql.subscription.conflict | 0.006 | 0.056 | 0.1% |
| postgresql.collection.heartbeat | 0.006 | 0.006 | 0.0% |

The three queries that read `pg_stat_activity` or `pg_locks` are 99% of the
pack's execution time at saturation (the pg_locks scan added since the first
measurement is the third). In the saturated arm their means are 13 to 33 times
the TPC-B arm's because 64 busy backends make `pg_stat_activity` bigger and
because execution time includes waiting for a CPU; the maxima reach 100 ms
(snapshot query). Per second, the whole pack executes for 0.03 ms (tpcb) and
0.52 ms (cpu), the postgresql receiver's statements for 0.18 ms and 5.4 ms
(its per-table statistics query alone averages 36 ms in the saturated arm).
The Collector process itself used 20 ms (tpcb) and 16 ms (cpu) of CPU per
second, so the Collector's cost is mostly outside the database: query
the pack's execution inside PostgreSQL is 0.2% (tpcb) to 3% (cpu) of what the
Collector process burns on the same host.

## Compared with the 2026-11-07 measurement

Three queries then, nine now, plus `postgresql.deadlocks`. Collector CPU per
second of TPC-B load rose from 12 ms to 20 ms (3.65 s to 5.89 s per 300 s run,
1.2% to 2.0% of one core); memory.peak from 56.6 MB to 68.9 MB. Which part of
that is the pack, which the deadlocks metric and which a different run
environment was not separated (assumption: mostly the pack, whose extra
queries add rows and attribute sets to convert). Throughput is not comparable
across the two series: the 2026-11-07 TPC-B arm ran at about 1060 tps with a
data disk await of 1.7 ms, this one at about 475 tps with 4.4 ms. A
`pg_test_fsync` after the series reported 4.9 ms per fdatasync on the data
disk (nothing comparable was recorded in 2026-11-07), so the data disk's
synchronous write latency, a property of the Proxmox host, is the probable
cause (assumption: not tested further). The 2026-11-07 verdict (within noise)
is unchanged for the TPC-B arm.

## Evidence that ON runs collected

Every ON run: Collector unit active with one process before pgbench and again
at its end (a check `measure-run.sh` now makes), 3 (cpu arm: 3-4) otel_monitor
sessions in pg_stat_activity at mid-run, 19-24 debug-exporter metric batches in
the window; the unit journal of the whole series has no error or warning line.
Every OFF run: Collector inactive and no otelcol process before pgbench, 0
otel_monitor sessions. The pg_stat_statements rows add that every pack query
ran about once per scrape (20.1 calls per 300 s run, 12.0 per 180 s run).

## Set-aside series

`contaminated-2026-11-06/` holds the first series (6 OFF, 6 ON, no steal or
await columns), not used: another VM on the same Proxmox host ran load during
it. `2026-11-07-old-pack/` is the 2026-11-07 series (8 OFF, 8 ON, 22 columns,
no `host_cpu_busy_pct`) from before the pack grew; it is superseded, not
faulty.

## Caveats

- One server, one pgbench database, 128MB shared_buffers, no standby, the
  `debug` exporter instead of the Victoria stack. Assumption: export cost is
  small next to the queries; not measured, so the Collector CPU here is a
  lower bound for the slice 1 setup.
- The pack was written for primaries and standbys; on this primary the
  slot, subscription and conflict queries return no rows, so their cost is
  the cost of an empty scan. A server with slots or subscriptions pays more
  (not measured).
- File logging is barely exercised: log_min_duration_statement 1000 produces
  almost no log lines under either load.
- The CPU-saturated arm shares the 4 vCPUs between PostgreSQL, pgbench and the
  Collector, with 1-17% steal; pgbench's CPU was not measured separately.
  Latency percentiles there include run-queue wait. A real saturated server
  has its clients elsewhere.
- Both arms run on a VM whose disk latency changed between series; the
  comparisons that matter (ON against OFF) are inside one series.
- Steal and disk await see only what reaches this VM.
