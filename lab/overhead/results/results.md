# Collector overhead on pg-lab: results

Measured 2026-11-12 with `lab/overhead/setup.sh` and `lab/overhead/run.sh`.
The pack measured is kept as `pack-measured/queries.yaml` next to these
results: nine queries, sha256
`c5b2401f4ff59415b143d64221ba9fd5dd0537a70f58f064027485f6817526ee`. It is not
the pack on main (`lab/packs/postgresql/queries.yaml`, eleven queries, sha256
`7e28cc96aa960bc1f82875b9680f52e621225d7aef50bd7f50f706ec7b7ec29a` at the time
of writing). Main's adds the archiver query (`pg_stat_archiver`,
`pg_ls_archive_statusdir()`) and the synchronous standby query, and changes two
existing ones: the snapshot query gained a prepared-transaction term and an
xmin horizon subquery, and the slot query uses `greatest(receive, replay)` LSN.
None of this is in the measurement, so every pack cost below understates what
main's pack would cost. The first measurement (2026-11-07, three-query pack) is
kept in `2026-11-07-old-pack/` for comparison and is not the current result.

Tables: `./summarize.sh --from-block 2 results/runs.csv` (TPC-B arm) and
`./summarize.sh --from-block 2 results/runs-cpu.csv` (CPU-saturated arm); raw
per-run data in `runs*.csv`, warm-ups in `warmup*.csv`, the per-query cost of
the pack in `pack-cost.csv` (from `pgss*.csv` and `pack-measured/`,
`./pack-cost.py`), block-level statistics with `./block-stats.py
results/runs-cpu.csv [first last]`, and raw output of the side observations in
`observations.txt`.

## Conditions

- Host: pg-lab (10.0.0.13), Debian 13, kernel 6.12.113 (`observations.txt`), 4 vCPU, 7.8 GB RAM,
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
- Database: pgbench scale 100, 2144 MB after the series (`observations.txt`) (larger than
  shared_buffers; the whole database fits in the page cache of the 7.8 GB VM).
- Load, two arms, both pgbench (version 18.6 assumed from the PGDG package; not printed, see `observations.txt`) against database postgres, per-transaction
  log, percentiles nearest-rank over every transaction of the run:
  - `tpcb` (the original arm): built-in TPC-B-like script, simple protocol,
    8 clients, 4 threads, 300 s per run. PostgreSQL used 0.37-0.45 of the 4
    cores.
  - `cpu` (new): select-only (`-S`), prepared protocol, 64 clients, 4
    threads, 180 s per run, chosen after a 30 s probe (32 clients left 6-12%
    idle, 64 left 0%; raw lines in `observations.txt`). Host CPU busy 99.9% (median, from /proc/stat, including
    steal and pgbench's own CPU), PostgreSQL 2.7-2.9 of the 4 cores. Latency
    here includes run-queue wait.
- Order, both arms: one discarded warm-up run (OFF), then four ABBA blocks of
  alternating orientation (OFF ON ON OFF, ON OFF OFF ON, ...); the `cpu` arm
  was extended to eight blocks (16 OFF, 16 ON). That extension was decided
  after the summary of blocks 1-4 had been read (it showed ON below OFF, with
  an interval spanning zero); it started about 2 h after block 4 ended, after
  the TPC-B arm, and blocks 1-4 and 5-8 ran in different steal regimes (below).
  Both are reported; the 8-block figure is the primary one only because it uses
  all the data, and the stopping rule was not fixed in advance. Each run: Collector stopped (OFF) or freshly started (ON),
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

The two ON runs of a block share that block's OFF mean, so the run-level pairs
above are not independent. The unit is the block (n = 4):
`./block-stats.py results/runs.csv`. Block difference, ON mean minus OFF mean
(95% t-interval, 3 degrees of freedom): tps +16.2 (+3.4%; [-19.9, +52.3],
[-4.2%, +11.0%]); p95 -0.63 ms (-2.0%; [-3.30, +2.04] ms); p99 -1.6 ms (-2.6%;
[-8.0, +4.8] ms). The four block differences in tps are +48.4, +15.9, -0.3 and
+0.8; the first block holds the series' fastest run (ON, 552.8 tps).

Verdict: within noise, and a weak test. The interval is about +-7.6% in tps
(its half-width), so this design would resolve an effect of that size, not
smaller ones. The run-to-run spread of the OFF runs in tps is SD 13.6 (2.9% of
the mean), MAD 10.0 (2.1% of the median), IQR 23.7 (5.0%). The database is
commit-bound here (see Caveats), so the load leaves 3.5 cores idle and says
little about CPU contention; the `cpu` arm is for that. The precise number of
this arm is the Collector's own CPU, 2.0% of one core.

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
| data disk await ms | 4.14 (3.45-9.60) | 4.50 (3.65-5.87) | +0.35 |
| host CPU busy % | 99.88 (92.4-99.92) | 99.85 (99.6-99.94) | -0.03 |

Collector only (ON runs): CPU 2.96 s per 180 s run (2.69-3.53), memory.peak
about 69 MB (66.9-71.1), 3-4 otel_monitor sessions, 19-24 batches. That is
1.65% of one core and 0.57% of PostgreSQL's CPU.

Paired ABBA difference per run (descriptive only; the two ON runs of a block
share its OFF mean):

| pairs | n | d tps min / median / max | d p50 ms | d p95 ms | d p99 ms | d tps/(1-steal) |
|---|---|---|---|---|---|---|
| blocks 1-8 | 16 | -6008 / -732 / +3014 | -0.07 / -0.01 / +0.06 | -0.72 / +0.17 / +2.34 | -2.66 / +0.16 / +9.12 | -2489 / -636 / +2349 |
| blocks 2-8 | 14 | -6008 / -732 / +3014 | -0.07 / -0.00 / +0.06 | -0.55 / +0.17 / +2.34 | -1.18 / +0.16 / +9.12 | -2489 / -636 / +2349 |
| blocks 5-8 | 8 | -1256 / -43 / +1173 | -0.03 / -0.01 / +0.06 | -0.10 / +0.08 / +0.23 | -0.48 / -0.05 / +0.34 | -1041 / -31 / +1190 |

The last column is tps divided by (1 - steal share of the run), a post hoc
correction. It assumes throughput is linear in the CPU time not stolen and that
steal hits OFF and ON runs alike; neither was tested.

Block level (n = 8; `./block-stats.py results/runs-cpu.csv [first last]`).
Block difference, ON mean minus OFF mean, with the 95% t-interval of its mean:

| blocks | n | tps | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|---|
| 1-8 | 8 | -800 (-2.7%) [-1848, +248] ([-6.1%, +0.8%]) | +0.003 (+0.1%) [-0.022, +0.027] | +0.32 (+7.2%) [-0.02, +0.66] | +1.06 (+13.3%) [-0.37, +2.49] |
| 1-4 | 4 | -1500 (-5.2%) [-3678, +678] ([-12.8%, +2.4%]) | +0.011 (+0.6%) | +0.56 (+11.7%) [-0.18, +1.31] | +2.17 (+23.2%) [-0.82, +5.16] |
| 5-8 | 4 | -100 (-0.3%) [-1206, +1006] ([-3.8%, +3.2%]) | -0.005 (-0.3%) | +0.07 (+1.8%) [-0.06, +0.20] | -0.04 (-0.7%) [-0.26, +0.18] |

OFF run spread in tps (all 16 OFF runs): SD 2315 (7.7% of the mean), MAD 1234
(4.1% of the median), IQR 2391 (7.9%).

Verdict, 8 blocks: not distinguishable from zero, by a small margin. The
mean block difference in tps is -2.7% and its 95% interval [-6.1%, +0.8%]
contains zero; 5 of the 8 block differences are negative (the same fact as the
interval, stated at the block level). The design resolves about +-3.5% in tps
(the half-width), so it cannot rule out a loss of a few percent, and it cannot
show one either. p95 and p99 are higher on ON by +7% and +13% in the mean, with
intervals that also contain zero ([-0.6%, +15.0%] and [-4.6%, +31.1%]); tail
latency here is the least precise number in this report, because queueing
makes it follow steal.

Two regimes, two verdicts. Blocks 1-4 (steal in single runs up to 17%; the
low-tps runs OFF 12 and ON 10, 11, 13 all had 15-17%) give -5.2% in tps with an
interval of +-7.6% around it, [-12.8%, +2.4%]. Blocks 5-8 (steal 1.3-4.2%) give
-0.3%, [-3.8%, +3.2%]. The two halves overlap; the first has the larger
negative mean and the steal-corrected run-level median moves only from -732 to
-636 tps, so the correction does not remove it. Whether the Collector costs
about 0.3% or about 3-5% of throughput at saturation is not settled by 8
blocks on a VM with this steal. The precise number is the Collector's own CPU:
1.65% of one core, 0.4% of the 4-vCPU machine.

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
the TPC-B arm's, and the maxima reach 100 ms (snapshot query). Assumption, not
tested: that comes from 64 busy backends making `pg_stat_activity` larger and
from execution time including time waiting for a CPU. Against the CPU-wait
part, the heartbeat query (`SELECT 1`, unchanged between the arms) has the same
mean in both, about 0.006 ms; a query that short is rarely preempted, so it
does not exclude it either.

Per second, the whole measured pack executes for 0.03 ms (tpcb) and 0.52 ms
(cpu); the postgresql receiver's statements for 0.18 ms and 5.4 ms (its
per-table statistics query alone averages 36 ms in the saturated arm). Main's
pack is heavier than the measured one, so 0.52 ms understates it. The Collector
process itself used 20 ms (tpcb) and 16 ms (cpu) of CPU per second, so its
cost is mostly outside the database: the measured pack's execution inside
PostgreSQL is 0.2% (tpcb) to 3% (cpu) of what the Collector process burns on
the same host.

## Compared with the 2026-11-07 measurement

Three queries then, nine now, plus `postgresql.deadlocks`. Collector CPU per
second of TPC-B load rose from 12 ms to 20 ms (3.65 s to 5.89 s per 300 s run,
1.2% to 2.0% of one core); memory.peak from 56.6 MB to 68.9 MB. Which part of
that is the pack, which the deadlocks metric and which a different run
environment was not separated (assumption: mostly the pack, whose extra
queries add rows and attribute sets to convert). Throughput is not comparable
across the two series: the 2026-11-07 TPC-B arm ran at about 1060 tps with a
data disk await of 1.7 ms, this one at about 475 tps with 4.4 ms. A
`pg_test_fsync` after the series reported 4.9-5.4 ms per fdatasync on the data
disk (two runs, raw lines in `observations.txt`; nothing comparable was
recorded in 2026-11-07), so the data disk's
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
