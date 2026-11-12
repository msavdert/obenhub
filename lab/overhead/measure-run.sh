#!/usr/bin/env bash
# One measurement run of the Collector overhead test. Runs ON pg-lab as root
# (the driver run.sh copies it there and calls it over ssh). Assumption:
# cgroup v2, postgresql@18-main.service and obenhub-otelcol.service as
# created by setup.sh.
#
# Usage: measure-run.sh ON|OFF SEQ DURATION_S [PRE_S]   (env: ARM=tpcb|cpu)
# Prints one CSV line (field order: see HEADER in run.sh) on stdout; all
# other output goes to stderr. ARM selects the load:
#   tpcb  pgbench built-in TPC-B-like script, 8 clients (the original arm; the
#         database is I/O and commit bound, about 0.6 of 4 cores);
#   cpu   pgbench select-only (-S), prepared protocol, 64 clients, 4 threads:
#         reads from the page cache, so PostgreSQL and pgbench together use the
#         4 vCPUs (CPU-saturated arm).
# ON runs also write the otel_monitor rows of pg_stat_statements for the
# window to $RUNDIR/pgss.csv (the driver run.sh fetches it).
set -euo pipefail

MODE="$1"
SEQ="$2"
DUR="$3"
PRE="${4:-60}"
ARM="${ARM:-tpcb}"
case "$ARM" in
  tpcb) PGBENCH_ARGS=(-n -c 8 -j 4) ;;
  cpu) PGBENCH_ARGS=(-n -S -M prepared -c 64 -j 4) ;;
  *) echo "unknown ARM $ARM" >&2; exit 2 ;;
esac
DB=postgres

PGCG=/sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@18-main.service
COLCG=/sys/fs/cgroup/system.slice/obenhub-otelcol.service
RUNDIR="/var/tmp/overhead/run-$SEQ"

usage_usec() { awk '$1 == "usage_usec" {print $2}' "$1/cpu.stat"; }
psql_q() { sudo -u postgres psql -Atq -d "$DB" -c "$1" </dev/null; }

# host-noise indicators readable from inside the VM: CPU steal from
# /proc/stat and mean I/O latency of the data disk from /proc/diskstats
DATADEV=$(basename "$(findmnt -no SOURCE /var/lib/postgresql)")
# prints: steal, total, busy (total minus idle and iowait), all in jiffies
cpu_stat() { awk '/^cpu / {t = 0; for (i = 2; i <= 9; i++) t += $i; print $9, t, t - $5 - $6}' /proc/stat; }
disk_stat() { awk -v d="$DATADEV" '$3 == d {print $4 + $8, $7 + $11}' /proc/diskstats; }

sampler=""
cleanup() {
  [ -n "$sampler" ] && kill "$sampler" 2>/dev/null
  systemctl stop obenhub-otelcol.service 2>/dev/null
  return 0
}
trap cleanup EXIT

rm -rf "$RUNDIR"
install -d -o postgres -g postgres -m 0755 /var/tmp/overhead "$RUNDIR"

# Collector state: stopped for OFF, freshly started for ON (own cgroup, so
# memory.peak starts at zero).
systemctl stop obenhub-otelcol.service
if [ "$MODE" = ON ]; then
  systemctl start obenhub-otelcol.service
fi
psql_q "CHECKPOINT" >/dev/null
sleep "$PRE"

col_active=0
systemctl is-active --quiet obenhub-otelcol.service && col_active=1
col_procs=$(pgrep -c -x otelcol-contrib || true)
if [ "$MODE" = ON ] && [ "$col_active" != 1 ]; then
  echo "ON run but Collector not active" >&2
  exit 1
fi
if [ "$MODE" = OFF ] && { [ "$col_active" != 0 ] || [ "$col_procs" != 0 ]; }; then
  echo "OFF run but a Collector is present" >&2
  exit 1
fi

# the pg_stat_statements window starts here, so it holds only scrapes of the
# measured window (reset in both arms, so the arms stay alike)
psql_q "SELECT pg_stat_statements_reset()" >/dev/null
pg0=$(usage_usec "$PGCG")
read -r st0 tot0 busy0 < <(cpu_stat)
read -r io0 iot0 < <(disk_stat)
col0=0
[ "$MODE" = ON ] && col0=$(usage_usec "$COLCG")
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
t0_s=$(date +%s)

# sample Collector memory.current and the otel_monitor session count while
# pgbench runs; the samples file is rewritten every round, so it exists even
# when the sampler is killed, and a failed query is recorded as empty
(
  max_cur=0
  max_sess=0
  mid_sess=""
  start=$(date +%s)
  while true; do
    if [ "$MODE" = ON ]; then
      cur=$(cat "$COLCG/memory.current" 2>/dev/null || echo 0)
      [ "$cur" -gt "$max_cur" ] && max_cur=$cur
    fi
    s=$(psql_q "SELECT count(*) FROM pg_stat_activity WHERE usename = 'otel_monitor'" 2>/dev/null || true)
    if [[ "$s" =~ ^[0-9]+$ ]]; then
      [ "$s" -gt "$max_sess" ] && max_sess=$s
      [ -z "$mid_sess" ] && [ $(( $(date +%s) - start )) -ge $(( DUR / 2 )) ] && mid_sess=$s
    fi
    echo "$max_cur $max_sess ${mid_sess:--1}" >"$RUNDIR/samples"
    sleep 5
  done
) &
sampler=$!

# shellcheck disable=SC2024  # this script runs as root; the redirects are root's
sudo -u postgres pgbench "${PGBENCH_ARGS[@]}" -T "$DUR" \
  --log --log-prefix="$RUNDIR/pgb" "$DB" >"$RUNDIR/pgbench.out" 2>"$RUNDIR/pgbench.err" </dev/null

# close the measurement window right away: counters first, then everything else
pg1=$(usage_usec "$PGCG")
read -r st1 tot1 busy1 < <(cpu_stat)
read -r io1 iot1 < <(disk_stat)
col1=0
col_peak=0
if [ "$MODE" = ON ]; then
  col1=$(usage_usec "$COLCG")
  col_peak=$(cat "$COLCG/memory.peak")
fi
t1_s=$(date +%s)
if [ "$MODE" = ON ]; then
  # one row per statement text of role otel_monitor; times in ms
  # shellcheck disable=SC2024  # this script runs as root; the redirect is root's
  sudo -u postgres psql -q -d "$DB" --csv -c "
    SELECT $SEQ AS seq, '$ARM' AS arm, calls, round(total_exec_time::numeric, 3) AS total_exec_ms,
           round(mean_exec_time::numeric, 4) AS mean_exec_ms, round(stddev_exec_time::numeric, 4) AS stddev_exec_ms,
           round(min_exec_time::numeric, 4) AS min_exec_ms, round(max_exec_time::numeric, 4) AS max_exec_ms,
           rows, shared_blks_hit, shared_blks_read,
           regexp_replace(query, '\s+', ' ', 'g') AS query
      FROM pg_stat_statements
     WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = 'otel_monitor') AND dbid = (SELECT oid FROM pg_database WHERE datname = '$DB')
     ORDER BY query" </dev/null >"$RUNDIR/pgss.csv" || true
fi
kill "$sampler" 2>/dev/null || true
wait "$sampler" 2>/dev/null || true
sampler=""

# the Collector must still be there at the end of an ON window
if [ "$MODE" = ON ]; then
  col_procs_end=$(pgrep -c -x otelcol-contrib || true)
  if ! systemctl is-active --quiet obenhub-otelcol.service || [ "$col_procs_end" != 1 ]; then
    echo "ON run but the Collector is not active with one process at the end" >&2
    exit 1
  fi
fi
scrapes=0
if [ "$MODE" = ON ]; then
  scrapes=$(journalctl -u obenhub-otelcol.service --since "@$t0_s" --until "@$t1_s" --no-pager -o cat \
    | grep -c '"otelcol.signal": "metrics"' || true)
fi
read -r max_cur max_sess mid_sess <"$RUNDIR/samples"

tps=$(awk '/^tps = / {print $3}' "$RUNDIR/pgbench.out")
failed=$(awk '/^number of failed transactions:/ {print $5}' "$RUNDIR/pgbench.out")

# latency in microseconds is column 3 of the per-transaction log
cat "$RUNDIR"/pgb.* | awk '{print $3}' | sort -n >"$RUNDIR/lat.sorted"
if [ ! -s "$RUNDIR/lat.sorted" ] || [ -z "$tps" ] || [ -z "$failed" ]; then
  echo "no transactions logged or pgbench summary missing: see $RUNDIR/pgbench.err" >&2
  exit 1
fi
awk -v tps="$tps" -v failed="$failed" -v mode="$MODE" -v seq="$SEQ" -v t0="$t0" \
    -v pg="$(( pg1 - pg0 ))" -v col="$(( col1 - col0 ))" -v peak="$col_peak" \
    -v curmax="$max_cur" -v sess_max="$max_sess" -v sess_mid="$mid_sess" \
    -v scrapes="$scrapes" -v colproc="$col_procs" -v dur="$DUR" \
    -v busy="$(( busy1 - busy0 ))" -v steal="$(( st1 - st0 ))" -v tot="$(( tot1 - tot0 ))" -v ios="$(( io1 - io0 ))" -v iot="$(( iot1 - iot0 ))" '
  function nr(p,   i) { i = int(p * n); if (i < p * n) i++; if (i < 1) i = 1; return i }
  { v[NR] = $1; sum += $1 }
  END {
    n = NR
    printf "%s,%s,%s,%s,%d,%.1f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.3f,%.3f,%.1f,%.1f,%d,%d,%d,%d,%.3f,%.3f,%.2f\n",
      seq, mode, t0, dur, n, tps, sum / n / 1000, v[nr(0.50)] / 1000, v[nr(0.95)] / 1000, v[nr(0.99)] / 1000, v[n] / 1000,
      failed, pg / 1e6, col / 1e6, peak / 1048576, curmax / 1048576, sess_mid, sess_max, scrapes, colproc,
      (tot > 0) ? steal / tot * 100 : 0, (ios > 0) ? iot / ios : 0,
      (tot > 0) ? busy / tot * 100 : 0
  }' "$RUNDIR/lat.sorted"

# keep the pgbench summary, drop the large files
rm -f "$RUNDIR"/pgb.* "$RUNDIR/lat.sorted"
systemctl stop obenhub-otelcol.service
