#!/usr/bin/env bash
# Runs the OBI experiment on pg-lab (10.0.0.13) over ssh from the box. Run
# setup.sh first. Uses only pg-lab; at the end (and on failure) OBI, its
# Collector and PgBouncer are stopped and disabled, PostgreSQL keeps running.
#
# Matrix: {direct 5432, via PgBouncer 6432} x {simple, extended, prepared},
# OBI on, pgbench at a fixed rate; plus a direct/extended cell with OBI off
# (run first, for the indicative overhead pair), one direct/extended cell over
# TLS (PGSSLMODE=require) and a diagnostic direct/prepared cell whose clients
# sleep 12 s before their first statement (see measure-cell.sh).
# Usage: lab/obi/run.sh   (env: DURATION=80 RATE=250 CLIENTS=8 PAUSE=20)
# ONLY=<tag> runs just that cell and appends to the Collector output already
# on pg-lab (not used for the kept results).
# Output: results/cells/<tag>/, results/metrics.jsonl.gz,
# results/traces-logs-bytes.txt (bytes in the Collector trace and log files)
set -euo pipefail

HOST="${PGLAB_HOST:-pg-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${DURATION:-80}"
RATE="${RATE:-250}"
CLIENTS="${CLIENTS:-8}"
PAUSE="${PAUSE:-20}"
ONLY="${ONLY:-}"
OUT="$HERE/results"

SSH_OPTS=(-o ServerAliveInterval=30 -o ServerAliveCountMax=4)
stop_all() {
  ssh -n "${SSH_OPTS[@]}" "$HOST" 'sudo systemctl disable --now obi.service obenhub-otelcol-obi.service pgbouncer.service' \
    || echo "could not stop the units on $HOST" >&2
}
trap stop_all EXIT

mkdir -p "$OUT/cells"
T=$(ssh -n "${SSH_OPTS[@]}" "$HOST" mktemp -d)
scp -q "${SSH_OPTS[@]}" "$HERE/measure-cell.sh" "$HOST:$T/measure-cell.sh"
ssh -n "${SSH_OPTS[@]}" "$HOST" "sudo install -m 0755 $T/measure-cell.sh /usr/local/sbin/obi-measure-cell.sh && rm -rf $T"

# fresh Collector output, then the services the cells need
rmcmd=""; [ -n "$ONLY" ] || rmcmd="sudo rm -f /var/lib/obi-lab/*.jsonl;"
ssh -n "${SSH_OPTS[@]}" "$HOST" "sudo systemctl stop obi.service obenhub-otelcol-obi.service; $rmcmd sudo systemctl start obenhub-otelcol-obi.service pgbouncer.service; sleep 2"

fetch_metrics() {
  ssh -n "${SSH_OPTS[@]}" "$HOST" 'sudo cat /var/lib/obi-lab/metrics.jsonl' | gzip -9 >"$OUT/metrics.jsonl.gz"
}

cell() { # tag route proto obi [ssl [script]]
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || return 0
  echo "$(date -u +%H:%M:%S) cell $1" >&2
  # shellcheck disable=SC2029  # expanding on the client side is intended
  ssh -n "${SSH_OPTS[@]}" "$HOST" sudo /usr/local/sbin/obi-measure-cell.sh "$1" "$2" "$3" "$4" "$DURATION" "$RATE" "$CLIENTS" "${5:-off}" "${6:-builtin}" >/dev/null
  ssh -n "${SSH_OPTS[@]}" "$HOST" "sudo tar -C /var/lib/obi-cells -cf - $1" | tar -C "$OUT/cells" -xf -
  fetch_metrics
  sleep "$PAUSE"
}

cell direct-extended-obioff direct extended off
for route in direct bouncer; do
  for proto in simple extended prepared; do
    cell "$route-$proto" "$route" "$proto" on
  done
done
cell direct-extended-tls direct extended on on
cell direct-prepared-late direct prepared on off late

fetch_metrics
ssh -n "${SSH_OPTS[@]}" "$HOST" 'sudo cat /var/lib/obi-lab/traces.jsonl /var/lib/obi-lab/logs.jsonl | wc -c' >"$OUT/traces-logs-bytes.txt"
echo "done: $OUT" >&2
