#!/usr/bin/env bash
# Summarises results/runs.csv (written by run.sh) as Markdown tables, in the
# form used by results/results.md. Local only; reads the CSV, nothing else.
#   1. OFF and ON median and min-max for the metrics both arms have, with the
#      ON - OFF difference of the medians;
#   2. Collector-only metrics (ON runs);
#   3. paired ABBA difference: each ON run minus the mean of the two OFF runs
#      in its block of four, per pair and as min / median / max over all
#      blocks and, with --from-block N, over blocks N and later.
# Usage: lab/overhead/summarize.sh [--from-block N] [runs.csv]
set -euo pipefail

FROM=""
CSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/runs.csv"
while [ $# -gt 0 ]; do
  case "$1" in
    --from-block) FROM="${2:?--from-block needs a number}"; shift 2 ;;
    *) CSV="$1"; shift ;;
  esac
done

awk -F, -v from="$FROM" '
  function sortarr(a, n,   i, j, t) {
    for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
  }
  function med(a, n,   b, i) {
    if (n == 0) return 0
    for (i = 1; i <= n; i++) b[i] = a[i]
    sortarr(b, n)
    return (n % 2) ? b[(n + 1) / 2] : (b[n / 2] + b[n / 2 + 1]) / 2
  }
  function summ(pairs_from,   c, i, k, line, w, cnt, t, val) {
    # rows over pairs with block >= pairs_from (1-based)
    cnt = 0
    for (k = 1; k <= np; k++) if (pblock[k] >= pairs_from) cnt++
    if (cnt == 0) return ""
    line = sprintf("| blocks %d-%d | %d |", pairs_from, mb + 1, cnt)
    for (c = 1; c <= 4; c++) {
      t = 0
      for (k = 1; k <= np; k++) if (pblock[k] >= pairs_from) { t++; tmp[t] = pd[k, c] }
      sortarr(tmp, t)
      val = sprintf(" %+.2f / %+.2f / %+.2f |", tmp[1], med(tmp, t), tmp[t])
      line = line val
    }
    return line
  }
  NR == 1 { for (i = 1; i <= NF; i++) name[i] = $i; nf = NF; next }
  {
    m = $2; cnt[m]++
    for (i = 5; i <= nf; i++) {
      v[m, i, cnt[m]] = $i
      if (!((m, i) in mn) || $i < mn[m, i]) mn[m, i] = $i
      if (!((m, i) in mx) || $i > mx[m, i]) mx[m, i] = $i
    }
    if (m == "ON") { k = cnt[m]; cpu_core[k] = $14 / $4 * 100; cpu_pg[k] = ($13 > 0) ? $14 / $13 * 100 : 0 }
    b = int(($1 - 1) / 4) + 1
    if (b > mb + 1) mb = b - 1
    split("6 8 9 10", col, " ")
    if (m == "OFF") { no[b]++; for (c = 1; c <= 4; c++) off[b, c] += $(col[c]) }
    else { non[b]++; ons[b, non[b]] = $1; for (c = 1; c <= 4; c++) onv[b, non[b], c] = $(col[c]) }
  }
  END {
    printf "runs: OFF %d, ON %d\n\n", cnt["OFF"], cnt["ON"]
    print "| metric | OFF median (min-max) | ON median (min-max) | ON - OFF |"
    print "|---|---|---|---|"
    split("6 7 8 9 10 12 13 21 22", both, " ")
    for (x = 1; x <= 9; x++) {
      i = both[x]
      if (name[i] == "col_cpu_s") continue
      for (k = 1; k <= cnt["OFF"]; k++) a[k] = v["OFF", i, k]
      for (k = 1; k <= cnt["ON"]; k++) bb[k] = v["ON", i, k]
      mo = med(a, cnt["OFF"]); mnn = med(bb, cnt["ON"])
      printf "| %s | %.4g (%.4g-%.4g) | %.4g (%.4g-%.4g) | %+.4g |\n", name[i], mo, mn["OFF", i], mx["OFF", i], mnn, mn["ON", i], mx["ON", i], mnn - mo
    }
    print "\n| Collector-only metric (ON runs) | median (min-max) |"
    print "|---|---|"
    split("14 15 16 17 18 19", only, " ")
    for (x = 1; x <= 6; x++) {
      i = only[x]
      for (k = 1; k <= cnt["ON"]; k++) bb[k] = v["ON", i, k]
      printf "| %s | %.4g (%.4g-%.4g) |\n", name[i], med(bb, cnt["ON"]), mn["ON", i], mx["ON", i]
    }
    printf "\nCollector CPU, median over ON runs: %.2f%% of one core, %.2f%% of PostgreSQL CPU\n", med(cpu_core, cnt["ON"]), med(cpu_pg, cnt["ON"])

    print "\nPaired ABBA difference (ON minus mean of the two OFF runs in its block)\n"
    print "| ON run | block | d tps | d p50 ms | d p95 ms | d p99 ms |"
    print "|---|---|---|---|---|---|"
    for (bl = 1; bl <= mb + 1; bl++) {
      if (no[bl] == 0 || non[bl] == 0) { printf "| - | %d | block lacks OFF or ON runs, skipped | | | |\n", bl; continue }
      for (k = 1; k <= non[bl]; k++) {
        np++; pblock[np] = bl
        line = sprintf("| %d | %d |", ons[bl, k], bl)
        for (c = 1; c <= 4; c++) { d = onv[bl, k, c] - off[bl, c] / no[bl]; pd[np, c] = d; line = line sprintf(" %+.2f |", d) }
        print line
      }
    }
    print "\n| pairs | n | d tps min / median / max | d p50 ms | d p95 ms | d p99 ms |"
    print "|---|---|---|---|---|---|"
    print summ(1)
    if (from != "") print summ(from + 0)
  }' "$CSV"
