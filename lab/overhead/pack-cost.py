#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Per-query cost of the Collector's PostgreSQL pack, from pg_stat_statements.

Reads results/pgss.csv and results/pgss-cpu.csv (written by run.sh: the
otel_monitor rows of pg_stat_statements for the window of every ON run) and
the pack copy (see Usage), and writes results/pack-cost.csv,
one row per statement and arm. A statement is labelled with the first metric
of the pack query it matches (literals normalised on both sides, first 80 characters); anything
else is a query of the postgresql receiver and is labelled "receiver: ...".

Times are pg_stat_statements total_exec_time / mean_exec_time: execution only,
not parse, plan (track_planning is off) or network. Usage:
    lab/overhead/pack-cost.py [results-dir [pack-yaml]]
The pack defaults to results/pack-measured/queries.yaml, the copy the series
was measured with, not the current shared pack.
"""

import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
# the pack the series was measured with (a copy of lab/packs/postgresql/
# queries.yaml at commit 5266555); the shared pack has changed since
PACK = HERE / "results/pack-measured/queries.yaml"
ARMS = (("tpcb", "pgss.csv", "runs.csv"), ("cpu", "pgss-cpu.csv", "runs-cpu.csv"))


def norm(text):
    """Collapse whitespace and replace literals, $n and `epoch` by ?."""
    text = re.sub(r"'[^']*'", "?", text)
    text = re.sub(r"\$\d+|\bepoch\b", "?", text)
    text = re.sub(r"\b\d+\b", "?", text)
    return re.sub(r"\s+", " ", text).strip().lower()


# pg_stat_statements text and the pack text agree on the start of a statement;
# longer statements differ later (a CASE list or a trailing comment, seen in
# the lab with PostgreSQL 18.6), so statements are matched on this many
# characters.
PREFIX = 80


def short(text, limit=60):
    """Cut a statement to a label at a word boundary."""
    return text if len(text) <= limit else text[:limit].rsplit(" ", 1)[0]


def pack_queries(path):
    """Return [(first metric name, normalised sql)] from the pack file."""
    out, sql, metric, block = [], None, None, False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("- sql:"):
            if sql is not None:
                out.append((metric, sql))
            rest = line[len("- sql:") :].strip()
            sql, metric, block = ("" if rest == "|" else rest), None, rest == "|"
        elif block and line.startswith("    ") and not line.lstrip().startswith("- {"):
            sql += " " + line.strip()
        elif "metric_name:" in line and metric is None and not line.lstrip().startswith("#"):
            block = False
            metric = re.search(r"metric_name:\s*([\w.]+)", line).group(1)
    if sql is not None:
        out.append((metric, sql))
    return [(m, norm(s)[:PREFIX]) for m, s in out]


def summarise(arm, pgss_path, runs_path, pack):
    dur = {}
    with open(runs_path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["mode"] == "ON":
                dur[r["seq"]] = float(r["duration_s"])
    per = defaultdict(list)
    with open(pgss_path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            n = norm(r["query"])
            label = next((m for m, s in pack if s == n[:PREFIX]), None)
            per[("pack", label) if label else ("receiver", "receiver: " + short(n))].append(r)
    group = []
    for (source, label), rs in per.items():
        calls = sum(int(r["calls"]) for r in rs)
        per_run = defaultdict(float)
        for r in rs:
            per_run[r["seq"]] += float(r["total_exec_ms"])
        ms_per_s = statistics.median(per_run[s] / dur[s] for s in per_run)
        group.append((source, label, rs, calls, ms_per_s))
    pack_ms = sum(g[4] for g in group if g[0] == "pack")
    out = []
    for source, label, rs, calls, ms_per_s in sorted(group, key=lambda g: (g[0] != "pack", -g[4])):
        total = sum(float(r["total_exec_ms"]) for r in rs)
        out.append(
            {
                "arm": arm,
                "source": source,
                "query": label,
                "on_runs": len({r["seq"] for r in rs}),
                "calls_per_run": round(calls / len(dur), 1),
                "mean_exec_ms": round(total / calls, 4),
                "max_exec_ms": max(float(r["max_exec_ms"]) for r in rs),
                "exec_ms_per_s": round(ms_per_s, 4),
                "pct_of_pack_exec": round(100 * ms_per_s / pack_ms, 1) if source == "pack" else "",
                "rows_per_call": round(sum(int(r["rows"]) for r in rs) / calls, 2),
                "blks_hit_per_call": round(sum(int(r["shared_blks_hit"]) for r in rs) / calls, 1),
                "blks_read_per_call": round(sum(int(r["shared_blks_read"]) for r in rs) / calls, 3),
            }
        )
    return out


def main():
    res = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "results"
    pack = pack_queries(Path(sys.argv[2]) if len(sys.argv) > 2 else PACK)
    rows = []
    for arm, pgss_name, runs_name in ARMS:
        if (res / pgss_name).exists():
            rows += summarise(arm, res / pgss_name, res / runs_name, pack)
    if not rows:
        sys.exit("no pgss csv found in " + str(res))
    for arm, _, _ in ARMS:
        for source in ("pack", "receiver"):
            ms = sum(r["exec_ms_per_s"] for r in rows if r["arm"] == arm and r["source"] == source)
            print(f"{arm} {source}: {ms:.4f} ms of execution time per second", file=sys.stderr)
    out = res / "pack-cost.csv"
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
