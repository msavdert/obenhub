#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Block-level paired statistics of an ABBA series (results/runs*.csv).

The two ON runs of a block share the block's OFF mean, so they are not
independent; the unit here is the block: mean(ON runs) - mean(OFF runs) of
that block. Prints, per metric, the block differences, their mean, SD and the
95% t-interval of the mean (two-sided, n-1 degrees of freedom), as a percent
of the OFF mean, plus the spread of the OFF runs themselves (SD, MAD, IQR of
tps) and the smallest effect the design resolves (half-width of the interval).
Usage: lab/overhead/block-stats.py results/runs-cpu.csv [FIRST_BLOCK LAST_BLOCK]  (1-based)
"""

import csv
import statistics
import sys

# two-sided 95% Student t critical values by degrees of freedom (table values)
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365}
METRICS = ("tps", "lat_p50_ms", "lat_p95_ms", "lat_p99_ms")


def main():
    rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
    blocks = {}
    for r in rows:
        blocks.setdefault((int(r["seq"]) - 1) // 4, {"OFF": [], "ON": []})[r["mode"]].append(r)
    lo, hi = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (1, 10**6)
    keys = [k for k in sorted(blocks) if lo <= k + 1 <= hi]
    n = len(keys)
    print(f"{sys.argv[1]}: {n} blocks ({keys[0] + 1}-{keys[-1] + 1})")
    for m in METRICS:
        diffs, offs = [], []
        for k in keys:
            off = statistics.mean(float(r[m]) for r in blocks[k]["OFF"])
            on = statistics.mean(float(r[m]) for r in blocks[k]["ON"])
            diffs.append(on - off)
            offs.append(off)
        base = statistics.mean(offs)
        mean = statistics.mean(diffs)
        sd = statistics.stdev(diffs)
        half = T95[n - 1] * sd / n**0.5

        def pct(x, base=base):
            return 100 * x / base

        print(
            f"{m}: OFF block mean {base:.4g}; block diff mean {mean:+.4g} ({pct(mean):+.2f}%), "
            f"SD {sd:.4g}, 95% CI [{mean - half:+.4g}, {mean + half:+.4g}] "
            f"([{pct(mean - half):+.2f}%, {pct(mean + half):+.2f}%]), half-width {pct(half):.2f}%"
        )
        print("   block diffs: " + ", ".join(f"{d:+.4g}" for d in diffs))
    off_tps = sorted(float(r["tps"]) for k in keys for r in blocks[k]["OFF"])
    med = statistics.median(off_tps)
    mad = statistics.median(abs(x - med) for x in off_tps)
    q = statistics.quantiles(off_tps, n=4)
    print(
        f"OFF run tps: median {med:.4g}, SD {statistics.stdev(off_tps):.4g} "
        f"({100 * statistics.stdev(off_tps) / statistics.mean(off_tps):.1f}% of mean), "
        f"MAD {mad:.4g} ({100 * mad / med:.1f}%), IQR {q[2] - q[0]:.4g} ({100 * (q[2] - q[0]) / med:.1f}%)"
    )


if __name__ == "__main__":
    main()
