#!/usr/bin/env bash
# One matrix cell of the OBI experiment. Runs ON pg-lab as root (run.sh copies
# it to /usr/local/sbin/obi-measure-cell.sh and calls it over ssh). Assumes
# cgroup v2 and the units created by setup.sh; pgbouncer.service must already
# be running (run.sh starts it).
#
# Usage: measure-cell.sh TAG ROUTE PROTO OBI DURATION_S RATE CLIENTS [off|on [builtin|late]]
#   ROUTE direct|bouncer, PROTO simple|extended|prepared, OBI on|off
# Per cell (use DURATION_S 80: OBI needs several seconds to attach to the new
# pgbench and backend processes, so analyze.py measures from second ~15 on):
# CHECKPOINT; OBI (on) is restarted so it starts from zero and
# before pgbench opens its connections; 10 s settle; pgbench; 12 s wait so the
# last 5 s export reaches the Collector; OBI stopped. Writes
# /var/lib/obi-cells/TAG/ (summary.env, pgbench.out, obi.log, ...).
set -euo pipefail

TAG="$1"; ROUTE="$2"; PROTO="$3"; OBI="$4"; DUR="$5"; RATE="$6"; CLIENTS="$7"
case "$ROUTE" in direct) PORT=5432 ;; bouncer) PORT=6432 ;; *) echo "bad route" >&2; exit 2 ;; esac
THREADS=4
SCRIPT="${9:-builtin}"   # builtin: the TPC-B-like built-in script; late: same script, first transaction of each client sleeps 12 s
SSL="${8:-off}"   # off: PGSSLMODE=disable (plain protocol); on: PGSSLMODE=require
OUT=/var/lib/obi-cells/$TAG
install -d -m 0755 /var/lib/obi-cells; rm -rf "$OUT"; install -d -m 0755 -o postgres -g postgres "$OUT"

usage_usec() { awk '$1 == "usage_usec" {print $2}' "/sys/fs/cgroup/system.slice/$1/cpu.stat"; }
bouncer_stats() { # total_xact_count total_query_count total_query_time(us) for database postgres
  PGSSLMODE=disable PGPASSFILE=/etc/obi-lab/pgpass psql -Atq -h 127.0.0.1 -p 6432 -U obi_bench pgbouncer -c 'SHOW STATS' </dev/null \
    | awk -F'|' '$1 == "postgres" {print $3, $4, $8}'
}

cpu_stat() { awk '/^cpu / {t = 0; for (i = 2; i <= 9; i++) t += $i; print $9, t, $6}' /proc/stat; }   # steal, total, iowait

systemctl is-active --quiet obenhub-otelcol-obi.service || { echo "Collector unit not running" >&2; exit 1; }
systemctl is-active --quiet pgbouncer.service || { echo "pgbouncer not running" >&2; exit 1; }
systemctl stop obi.service 2>/dev/null || true
sudo -u postgres psql -qc CHECKPOINT postgres </dev/null

obi_since=$(date '+%Y-%m-%d %H:%M:%S')
if [ "$OBI" = on ]; then
  systemctl start obi.service
  sleep 10
fi
journalctl -u obi.service --since "$obi_since" --no-pager -o cat >"$OUT/obi.log" 2>&1 || true

read -r bx0 bq0 bt0 < <(bouncer_stats) || true
pg0=$(usage_usec system-postgresql.slice/postgresql@18-main.service)
obi0=0; [ "$OBI" = on ] && obi0=$(usage_usec obi.service)
col0=$(usage_usec obenhub-otelcol-obi.service)
SCRIPT_ARGS=()
[ "$SCRIPT" = late ] && SCRIPT_ARGS=(-D started=0 -f /etc/obi-lab/tpcb-late.sql)
cpu0=$(cpu_stat)
t0=$(date +%s.%N)

# shellcheck disable=SC2024  # this script runs as root; the redirects are root's
sudo -u postgres env PGPASSFILE=/etc/obi-lab/pgpass PGSSLMODE="$([ "$SSL" = on ] && echo require || echo disable)" pgbench -n -h 127.0.0.1 -p "$PORT" -U obi_bench \
  "${SCRIPT_ARGS[@]}" -M "$PROTO" -c "$CLIENTS" -j "$THREADS" -R "$RATE" -T "$DUR" -r -P 10 \
  --log --log-prefix="$OUT/pgb" postgres >"$OUT/pgbench.out" 2>"$OUT/pgbench.err" </dev/null

t1=$(date +%s.%N)
cpu1=$(cpu_stat)
obi1=0; [ "$OBI" = on ] && obi1=$(usage_usec obi.service)
col1=$(usage_usec obenhub-otelcol-obi.service)
pg1=$(usage_usec system-postgresql.slice/postgresql@18-main.service)
read -r bx1 bq1 bt1 < <(bouncer_stats) || true
sleep 12
if [ "$OBI" = on ]; then
  journalctl -u obi.service --since "$obi_since" --no-pager -o cat >"$OUT/obi.log" 2>&1 || true
  systemctl stop obi.service
  # OBI must have attached to exactly the three expected executables
  want=$(printf '%s\n' /usr/lib/postgresql/18/bin/pgbench /usr/sbin/pgbouncer /usr/lib/postgresql/18/bin/postgres | sort)
  got=$(grep 'msg="instrumenting process"' "$OUT/obi.log" | sed 's/.* cmd=\([^ ]*\) .*/\1/' | sort -u)
  if [ "$got" != "$want" ]; then
    echo "cell $TAG: OBI attached to an unexpected set of executables:" >&2
    echo "$got" >&2
    exit 1
  fi
fi

# keep only epoch seconds, latency (us) and schedule lag (us) of every
# transaction; analyze.py computes the windowed percentiles from it. In rate
# mode the logged latency is measured from the scheduled start, so it includes
# the schedule lag.
cat "$OUT"/pgb.* | awk '{printf "%d.%06d %d %d\n", $5, $6, $3, $7}' | sort -n | gzip -9 >"$OUT/txlog.gz"
awk -v ssl="$SSL" -v tag="$TAG" -v route="$ROUTE" -v proto="$PROTO" -v obi="$OBI" -v rate="$RATE" -v clients="$CLIENTS" \
    -v dur="$DUR" -v script="$SCRIPT" -v cpu0="$cpu0" -v cpu1="$cpu1" -v t0="$t0" -v t1="$t1" \
    -v tps="$(awk '/^tps = / {print $3}' "$OUT/pgbench.out")" \
    -v txns="$(awk '/^number of transactions actually processed:/ {print $6}' "$OUT/pgbench.out")" \
    -v failed="$(awk '/^number of failed transactions:/ {print $5}' "$OUT/pgbench.out")" \
    -v obicpu="$(( obi1 - obi0 ))" -v colcpu="$(( col1 - col0 ))" -v pgcpu="$(( pg1 - pg0 ))" \
    -v bx="$(( ${bx1:-0} - ${bx0:-0} ))" -v bq="$(( ${bq1:-0} - ${bq0:-0} ))" -v bt="$(( ${bt1:-0} - ${bt0:-0} ))" 'BEGIN {
    printf "ssl=%s\ntag=%s\nroute=%s\nproto=%s\nobi=%s\nrate=%s\nclients=%s\nduration=%s\nscript=%s\nt0=%s\nt1=%s\n", ssl, tag, route, proto, obi, rate, clients, dur, script, t0, t1
    split(cpu0, a, " "); split(cpu1, b, " ")
    printf "steal_pct=%.2f\niowait_pct=%.2f\n", 100 * (b[1] - a[1]) / (b[2] - a[2]), 100 * (b[3] - a[3]) / (b[2] - a[2])
    printf "txns=%s\ntps=%s\nfailed=%s\n", txns, tps, failed
    printf "obi_cpu_s=%.2f\ncollector_cpu_s=%.2f\npostgres_cpu_s=%.2f\n", obicpu / 1e6, colcpu / 1e6, pgcpu / 1e6
    printf "pgbouncer_xacts=%d\npgbouncer_queries=%d\npgbouncer_query_time_us=%d\n", bx, bq, bt
  }' >"$OUT/summary.env"
rm -f "$OUT"/pgb.*
cat "$OUT/summary.env" >&2
