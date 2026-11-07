#!/usr/bin/env bash
# Runs the Collector overhead measurement on pg-lab (10.0.0.13) over ssh from
# the box. Run setup.sh first. Uses only pg-lab; leaves the Collector stopped
# and disabled when it ends.
#
# Order: one discarded warm-up run (OFF), then ABBA blocks, alternating the
# block orientation (OFF ON ON OFF, ON OFF OFF ON, ...), BLOCKS blocks of four
# runs. Each run: Collector stopped (OFF) or freshly started (ON), CHECKPOINT,
# 60 s wait, pgbench for DURATION seconds with per-transaction logging, then
# Collector stopped and a PAUSE-second pause (see measure-run.sh).
#
# Usage: lab/overhead/run.sh   (env: BLOCKS=4 DURATION=300 PAUSE=30)
# Output: results/runs.csv (appended), results/warmup.csv
set -euo pipefail

HOST="${PGLAB_HOST:-pg-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCKS="${BLOCKS:-4}"
DURATION="${DURATION:-300}"
PAUSE="${PAUSE:-30}"
OUT="$HERE/results"
HEADER="seq,mode,start_utc,duration_s,txns,tps,lat_mean_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_max_ms,failed,pg_cpu_s,col_cpu_s,col_mem_peak_mb,col_mem_cur_max_mb,otel_sessions_mid,otel_sessions_max,collector_metric_batches,collector_procs,steal_pct,disk_await_ms"

SSH_OPTS=(-o ServerAliveInterval=30 -o ServerAliveCountMax=4)
# on failure or interrupt make sure no Collector keeps running on pg-lab
stop_collector() { ssh -n "${SSH_OPTS[@]}" "$HOST" sudo systemctl stop obenhub-otelcol.service || echo "could not stop the Collector on $HOST" >&2; }
finished=0
trap '[ "$finished" = 1 ] || stop_collector' EXIT

mkdir -p "$OUT"
scp -q "${SSH_OPTS[@]}" "$HERE/measure-run.sh" "$HOST:/tmp/measure-run.sh"
ssh -n "${SSH_OPTS[@]}" "$HOST" sudo install -m 0755 /tmp/measure-run.sh /usr/local/sbin/overhead-measure-run.sh

one() { # mode seq file
  echo "$(date -u +%H:%M:%S) run $2 $1" >&2
  # shellcheck disable=SC2029  # expanding on the client side is intended
  ssh -n "${SSH_OPTS[@]}" "$HOST" sudo /usr/local/sbin/overhead-measure-run.sh "$1" "$2" "$DURATION" >>"$3"
  sleep "$PAUSE"
}

[ -f "$OUT/warmup.csv" ] || echo "$HEADER" >"$OUT/warmup.csv"
[ -f "$OUT/runs.csv" ] || echo "$HEADER" >"$OUT/runs.csv"

if [ "$(wc -l <"$OUT/warmup.csv")" -lt 2 ]; then
  one OFF 0 "$OUT/warmup.csv"
fi

seq=$(( $(wc -l <"$OUT/runs.csv") ))   # header counts as 1, so next seq = lines
total=$(( BLOCKS * 4 ))
while [ "$seq" -le "$total" ]; do
  block=$(( (seq - 1) / 4 ))
  pos=$(( (seq - 1) % 4 ))
  if [ $(( block % 2 )) -eq 0 ]; then order=(OFF ON ON OFF); else order=(ON OFF OFF ON); fi
  one "${order[$pos]}" "$seq" "$OUT/runs.csv"
  seq=$(( seq + 1 ))
done

ssh -n "${SSH_OPTS[@]}" "$HOST" 'sudo systemctl stop obenhub-otelcol.service && sudo systemctl disable obenhub-otelcol.service'
finished=1
echo "done: $OUT/runs.csv" >&2
