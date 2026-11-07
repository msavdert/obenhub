# Collector overhead on pg-lab: results

Measured 2026-11-07 with `lab/overhead/setup.sh` and `lab/overhead/run.sh`
(tables: `./summarize.sh --from-block 2`; raw per-run data: `runs.csv`, warm-up in
`warmup.csv`).

## Method

- Host: pg-lab (10.0.0.13), Debian 13, 4 vCPU, 7.8 GB RAM, PostgreSQL 18.6
  (PGDG), otelcol-contrib 0.164.0 (tarball, sha256 verified against the
  release's `.sha256` file), started and stopped with systemd as
  `obenhub-otelcol.service` (own cgroup).
- PostgreSQL: shared_buffers 128MB and max_connections 100 (both unchanged
  Debian defaults). Changed (`conf.d/90-overhead.conf`): shared_preload_libraries
  pg_stat_statements, reserved_connections 8, logging_collector on,
  log_destination jsonlog in /var/log/postgresql, log_timezone UTC,
  log_lock_waits on, deadlock_timeout 1s, log_min_duration_statement 1000,
  track_io_timing on. Role `otel_monitor` as in the slice 1 lab (pg_monitor,
  pg_use_reserved_connections, statement_timeout 5s).
- Collector: `otelcol.yaml`, one server on localhost, same three-query pack,
  postgresql receiver on database postgres, file_log on the jsonlog files,
  15 s intervals, max_open_conn 3, `debug` exporter (verbosity basic) instead
  of the Victoria stack.
- Load: pgbench 18.6 in database postgres, scale 100 (pg_database_size 1503 MB after init, 1988 MB after
  the series as pgbench_history and bloat grew; larger than shared_buffers), built-in TPC-B-like script, simple protocol, 8 clients,
  4 threads (one thread per vCPU; clients are 2 per thread), 300 s per run,
  per-transaction log (`--log`); percentiles are nearest-rank over every
  transaction of the run.
- Order: one discarded warm-up run (OFF, 918 tps), then 16 runs in four ABBA
  blocks with alternating orientation:
  OFF ON ON OFF, ON OFF OFF ON, OFF ON ON OFF, ON OFF OFF ON (8 OFF, 8 ON).
  Each run: Collector stopped (OFF) or freshly started (ON), CHECKPOINT,
  60 s wait, pgbench, Collector stopped, 30 s pause.
- Per run: PostgreSQL cgroup CPU (`cpu.stat` usage_usec delta of
  `postgresql@18-main.service` over the pgbench window), Collector cgroup CPU
  (same, ON only), Collector `memory.peak` (includes the 60 s before pgbench),
  otel_monitor sessions sampled every 5 s, CPU steal (delta of the steal column
  in /proc/stat as a percentage of all CPU time over the run) and mean I/O
  latency of the data disk /dev/sdb (delta of ms spent on reads and writes
  divided by completed I/Os, /proc/diskstats).

## Result (8 OFF, 8 ON, medians and min-max)

| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |
|---|---|---|---|
| tps | 1059 (722.7-1076) | 1060 (969.3-1074) | +0.7 |
| latency mean ms | 7.55 (7.43-11.06) | 7.54 (7.45-8.25) | -0.004 |
| latency p50 ms | 7.27 (7.21-9.87) | 7.29 (7.21-7.47) | +0.02 |
| latency p95 ms | 13.00 (12.84-19.00) | 13.03 (12.59-14.27) | +0.03 |
| latency p99 ms | 19.04 (18.56-29.72) | 19.15 (18.52-21.76) | +0.11 |
| failed transactions | 0 | 0 | 0 |
| PostgreSQL CPU s per run | 178.6 (130.5-184.8) | 177.0 (175.4-179.2) | -1.6 |
| CPU steal % | 0.277 (0.261-0.370) | 0.327 (0.308-0.552) | +0.05 |
| data disk await ms | 1.69 (1.62-2.63) | 1.67 (1.65-1.82) | -0.02 |

Collector only (ON runs): CPU 3.65 s per run (3.60-4.10), memory.peak 56.6 MB
(55.9-57.0), 3 otel_monitor sessions, 21-23 metric batches per run. That is
1.2% of one core and 2.1% of PostgreSQL's CPU (median of per-run ratios).

Paired ABBA difference: each ON run minus the mean of the two OFF runs in its
block of four.

| pairs | n | d tps min / median / max | d p50 ms | d p95 ms | d p99 ms |
|---|---|---|---|---|---|
| blocks 1-4 | 8 | -8.10 / -1.10 / +181.65 | -1.34 / +0.03 / +0.06 | -3.40 / +0.02 / +0.15 | -5.78 / -0.14 / +0.46 |
| blocks 2-4 | 6 | -8.10 / -2.38 / +11.20 | -0.05 / +0.04 / +0.06 | -0.34 / +0.05 / +0.15 | -0.40 / +0.13 / +0.46 |

Block 1 is skewed by OFF run 1, the first run after the warm-up: 722.7 tps,
p99 29.7 ms, disk await 2.63 ms against 1.6-1.8 ms elsewhere; ON run 2 (969
tps) was also below the rest. Cause unknown; it looks like a warm-up transient
longer than the one discarded warm-up (the first series also had a lower first
run, 998 tps against about 1063 for runs 2-3). Excluding block 1 is a post-hoc
choice, so both rows are shown.

Verdict: within noise. Apart from runs 1 and 2, all 14 runs lie within
1053-1076 tps, ON and OFF interleaved. In blocks 2-4 the paired tps
differences range from -8.1 to +11.2 (about 1%), p95 from -0.34 to +0.15 ms
and p99 from -0.40 to +0.46 ms. ON p50 and p95 were higher in 5 of 6 pairs
(p50 by 0.02-0.06 ms, median +0.04 ms, about 0.5% of 7.3 ms): a slightly
higher ON latency, under about 1% at the median, which six pairs cannot
distinguish from noise or exclude. The measured cost is the Collector's own
CPU (1.2% of one core) and about 57 MB.

## Host noise

CPU steal was 0.26-0.55% of CPU time in every run: median 0.33% ON
(0.31-0.55%) against 0.28% OFF (0.26-0.37%); the ranges overlap. The higher
ON median may be the Collector's own CPU demand rather than host noise; the
data does not separate the two. Data disk await was 1.62-1.82 ms in all
runs except OFF run 1 (2.63 ms), which coincides with its slow throughput.
Steal and await only see what reaches this VM.

## Evidence that ON runs collected

Every ON run: Collector unit active with one process, checked after the 60 s
wait just before pgbench started (the end-of-window check was added to
`measure-run.sh` afterwards and applies to future runs; this series did not
have it); 3 otel_monitor sessions in pg_stat_activity at mid-run; 21-23
debug-exporter metric batches (46 metrics, 93 data points each) in the 300 s
window. Every OFF run: Collector inactive and no otelcol process before
pgbench, 0 otel_monitor sessions. A one-off check with verbosity detailed
(first series) showed the sql_query pack metrics (e.g.
`postgresql.collection.heartbeat`, `postgresql.replay.backlog`,
`postgresql.connection.client_capacity`), postgresql receiver metrics and 14
log records from the jsonlog file.

## Set-aside series

`contaminated-2026-11-06/` holds the first series (6 OFF, 6 ON, no steal or
await columns). It is not used: another VM on the same Proxmox host ran load
at 23:25:30-23:35:59Z (a pgbench control) and 23:43:52-23:46:46Z (a
connection-exhaustion scenario, plus container rule tests). Runs 5, 6 and 8
overlap those windows; runs 7 and 10 were also in the slow throughput cluster
(650-790 tps against 950-1080 tps) but no concurrent load times were
recorded for them.

## Caveats

- In this series the PostgreSQL and Collector CPU counters, steal and await
  were read after the sampler loop had ended, up to about 5 s after pgbench
  exited. PostgreSQL had no client load in that tail (assumed idle, not measured) and
  the Collector used about 0.06 s
  (1.2% of 5 s), negligible next to 300 s. `measure-run.sh` now reads the
  counters as soon as pgbench exits.
- The Victoria stack export is replaced by the `debug` exporter (basic).
  Assumption: export cost is small next to the queries; not measured, so the
  Collector CPU here is a lower bound for the slice 1 setup.
- File logging cost is barely exercised: log_min_duration_statement 1000
  produces almost no log lines under this load.
- One server, one workload, 128MB shared_buffers (the database fits in the page cache; where the
  time goes was not measured); no standby.
  PostgreSQL used about 0.6 of the 4 cores; pgbench's own CPU was not
  measured.
