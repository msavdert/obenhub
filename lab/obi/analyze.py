#!/usr/bin/env python3
"""Summarise the OBI experiment: pgbench numbers and OBI metrics per cell.

Reads results/cells/*/ (summary.env, txlog.gz, pgbench.out, written by
measure-cell.sh) and results/metrics.jsonl[.gz] (Collector file exporter).

Window: OBI needs several seconds to attach to the new pgbench and backend
processes, so every cell is measured from the last OBI export tick at or
before t0 + 20 s (t0 = pgbench start) to the end of pgbench (t1). OBI is
restarted for every cell and exports cumulative histograms, so the OBI count
for the window is last data point (up to t1 + 14 s) minus the data point of
that tick, per series (resource + attributes + start time). Cells with OBI off
use t0 + 17.5 s. OBI percentiles are linear interpolation inside the bucket of
the OBI histogram (approximate; the bounds are in obi.yaml). pgbench
percentiles are nearest rank over the transactions that completed in the
window; their latency includes the schedule lag (rate mode).

Usage: lab/obi/analyze.py [RESULTS_DIR]   (prints Markdown on stdout)
"""

import glob
import gzip
import json
import math
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
RES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results")
WARM, POST = 20.0, 14.0
METRICS = ("db.client.operation.duration", "db.server.operation.duration")


def kv(attrs):
    return {a["key"]: next(iter(a["value"].values())) for a in attrs or []}


def load_cells():
    cells = {}
    for f in sorted(glob.glob(os.path.join(RES, "cells", "*", "summary.env"))):
        d = dict(line.rstrip("\n").split("=", 1) for line in open(f) if "=" in line)
        for k in d:
            if k not in ("tag", "route", "proto", "obi", "ssl", "script"):
                d[k] = float(d[k])
        d["dir"] = os.path.dirname(f)
        cells[d["tag"]] = d
    return cells


def load_points():
    path = os.path.join(RES, "metrics.jsonl.gz")
    op = gzip.open
    if not os.path.exists(path):
        path, op = os.path.join(RES, "metrics.jsonl"), open
    with op(path, "rt") as fh:
        for line in fh:
            for rm in json.loads(line).get("resourceMetrics", []):
                res = kv(rm.get("resource", {}).get("attributes"))
                for sm in rm.get("scopeMetrics", []):
                    for m in sm.get("metrics", []):
                        if m["name"] not in METRICS:
                            continue
                        for p in m["histogram"]["dataPoints"]:
                            t = int(p["timeUnixNano"]) / 1e9
                            yield (
                                t,
                                m["name"],
                                res,
                                kv(p.get("attributes")),
                                p["startTimeUnixNano"],
                                int(p["count"]),
                                p["sum"],
                                p["explicitBounds"],
                                [int(x) for x in p["bucketCounts"]],
                            )


def quantile(q, bounds, buckets):
    n = sum(buckets)
    if n == 0:
        return float("nan")
    target, acc = q * n, 0
    for i, c in enumerate(buckets):
        if c and acc + c >= target:
            lo = bounds[i - 1] if i > 0 else 0.0
            hi = bounds[i] if i < len(bounds) else bounds[-1]
            return lo + (hi - lo) * (target - acc) / c
        acc += c
    return bounds[-1]


def nearest(sorted_v, q):
    return sorted_v[max(1, math.ceil(q * len(sorted_v))) - 1]


def load_txlog(c):
    out = []
    with gzip.open(os.path.join(c["dir"], "txlog.gz"), "rt") as fh:
        for line in fh:
            ts, lat_us, lag_us = line.split()
            out.append((float(ts), int(lat_us), int(lag_us)))
    return out


def count_txns(c, ta):
    return sum(1 for ts, _, _ in c["txlog"] if ta < ts <= c["t1"])


def pgbench_window(c, ta):
    sel = [(lat, lag) for ts, lat, lag in c["txlog"] if ta < ts <= c["t1"]]
    lat = sorted(x[0] for x in sel)
    span = c["t1"] - ta
    return {
        "n": len(lat),
        "tps": len(lat) / span,
        "span": span,
        "mean": sum(lat) / len(lat) / 1000,
        "p50": nearest(lat, 0.5) / 1000,
        "p95": nearest(lat, 0.95) / 1000,
        "p99": nearest(lat, 0.99) / 1000,
        "lag": sum(x[1] for x in sel) / len(sel),
    }


def pgbench_statements(c):
    """Statement -> mean latency (ms) from pgbench -r, keyed like OBI (op, collection)."""
    out = {}
    for line in open(os.path.join(c["dir"], "pgbench.out")):
        m = re.match(r"\s+([0-9.]+)\s+\d+\s+(.*)$", line)
        if not m or m.group(2).startswith("\\"):
            continue
        sql = m.group(2)
        op = sql.split()[0].rstrip(";").upper()
        tab = re.search(r"(?:UPDATE|INTO|FROM)\s+(pgbench_\w+)", sql)
        out[(op, tab.group(1) if tab else "")] = float(m.group(1))
    return out


def window_series(pts, c):
    """Return ({service: window start}, {series key: delta}) for the OBI exports of cell c.

    Each service exports on its own 5 s phase, so the baseline tick is chosen
    per service: its last export at or before t0 + 20 s.
    """
    lo, hi = c["t0"] - 12, c["t1"] + POST
    inwin = [p for p in pts if lo <= p[0] <= hi]
    ticks = defaultdict(set)
    for p in inwin:
        ticks[p[2].get("service.name")].add(round(p[0], 1))
    ta = {}
    for svc, ts in ticks.items():
        early = [t for t in ts if t <= c["t0"] + WARM + 0.05]
        if early:
            ta[svc] = max(early)
    base, last = {}, {}
    for t, name, res, attrs, start, n, s, bounds, bk in inwin:
        key = (name, json.dumps(res, sort_keys=True), json.dumps(attrs, sort_keys=True), start)
        rec = (t, n, s, bounds, bk, res, attrs)
        if t <= ta.get(res.get("service.name"), -1) + 0.05 and (key not in base or t > base[key][0]):
            base[key] = rec
        if key not in last or t > last[key][0]:
            last[key] = rec
    delta = {}
    for key, (_t, n, s, bounds, bk, res, attrs) in last.items():
        if key in base:
            _, n0, s0, _, bk0, _, _ = base[key]
        else:
            n0, s0, bk0 = 0, 0.0, [0] * len(bk)
        if n - n0 > 0:
            delta[key] = (n - n0, s - s0, bounds, [a - b for a, b in zip(bk, bk0, strict=True)], res, attrs)
    return ta, delta


def merge(items, keyfn):
    agg = {}
    for n, s, bounds, bk, res, attrs in items:
        k = keyfn(res, attrs)
        a = agg.setdefault(k, [0, 0.0, bounds, [0] * len(bk), set()])
        a[0] += n
        a[1] += s
        a[3] = [x + y for x, y in zip(a[3], bk, strict=True)]
        a[4].add(res.get("service.instance.id"))
    return agg


def main():
    cells = load_cells()
    pts = list(load_points())
    wins = {}
    failed = {}
    for tag, c in list(cells.items()):
        try:
            c["txlog"] = load_txlog(c)
            ta_by_svc, delta = window_series(pts, c)
            ta = ta_by_svc.get("pgbench") or ta_by_svc.get("postgres") or c["t0"] + WARM - 2.5
            if c["obi"] != "on":
                ta = c["t0"] + WARM - 2.5
            wins[tag] = (ta_by_svc, delta, pgbench_window(c, ta))
        except (ZeroDivisionError, FileNotFoundError, ValueError, IndexError, KeyError) as exc:
            failed[tag] = f"{type(exc).__name__}: {exc}"
            del cells[tag]
    if failed:
        print("### Failed cells (no transactions in the window, missing or malformed files)\n")
        for tag, why in failed.items():
            print(f"- {tag}: {why}")
        print()

    print("### A. pgbench in the window (latency includes schedule lag)\n")
    print(
        "| cell | route | protocol | OBI | window s | txns | tps | avg ms | p50 ms | p95 ms | p99 ms | lag us | steal % | iowait % | OBI CPU s (whole run) | PostgreSQL CPU s |"
    )
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for tag, c in cells.items():
        w = wins[tag][2]
        line = f"| {tag} | {c['route']} | {c['proto']}{' tls' if c['ssl'] == 'on' else ''} | {c['obi']} | {w['span']:.0f} | {w['n']} | {w['tps']:.1f} | "
        line += f"{w['mean']:.2f} | {w['p50']:.2f} | {w['p95']:.2f} | {w['p99']:.2f} | {w['lag']:.0f} | "
        line += f"{c['steal_pct']:.2f} | {c['iowait_pct']:.2f} | {c['obi_cpu_s']:.1f} | {c['postgres_cpu_s']:.1f} |"
        print(line)

    print("\n### B. Coverage: OBI statement counts vs what pgbench issued\n")
    exp_note = (
        "Expected = pgbench transactions that completed after the service's window start x statements per transaction "
    )
    exp_note += "(UPDATE 3, SELECT 1, INSERT 1, BEGIN 1, END 1). Each cell shows OBI count / expected.\n"
    print(exp_note)
    print(
        "| cell | service | metric | window start s | UPDATE | SELECT | INSERT | BEGIN | END | other operations (count, mean ms) |"
    )
    print("|---|---|---|---|---|---|---|---|---|---|")
    for tag, c in cells.items():
        if c["obi"] != "on":
            continue
        tas, delta, w = wins[tag]
        for svc in ("pgbench", "pgbouncer", "postgres"):
            for mi, mname in ((0, "client"), (1, "server")):
                agg = merge(
                    [v for k, v in delta.items() if k[0] == METRICS[mi] and v[4].get("service.name") == svc],
                    lambda res, attrs: attrs.get("db.operation.name", "-"),
                )
                if not agg:
                    continue
                ntx = count_txns(c, tas.get(svc, c["t0"] + WARM))
                line = f"| {tag} | {svc} | {mname} | {tas.get(svc, c['t0'] + WARM) - c['t0']:.1f} | "
                for op_, per in (("UPDATE", 3), ("SELECT", 1), ("INSERT", 1), ("BEGIN", 1), ("END", 1)):
                    n = agg.pop(op_, [0])[0]
                    line += f"{n} / {per * ntx} ({n / max(per * ntx, 1):.3f}) | "
                other = "; ".join(f"{o} {a[0]}, {1000 * a[1] / a[0]:.2f}" for o, a in agg.items())
                print(line + (other or "-") + " |")

    print("\n### C. Per statement: pgbench -r (whole run) vs OBI mean (window), ms\n")
    line = "OBI columns: client = db.client.operation.duration of service pgbench; server = db.server.operation.duration of service postgres; "
    line += "bouncer-in = db.server.operation.duration of service pgbouncer (client-facing side); bouncer-out = db.client.operation.duration of service pgbouncer.\n"
    print(line)
    print("| cell | statement | pgbench -r | OBI client | bouncer-in | bouncer-out | postgres server |")
    print("|---|---|---|---|---|---|---|")
    for tag, c in cells.items():
        if c["obi"] != "on":
            continue
        tas, delta, w = wins[tag]
        stm = pgbench_statements(c)
        cols = {}
        for label, svc, metric in (
            ("client", "pgbench", 0),
            ("bin", "pgbouncer", 1),
            ("bout", "pgbouncer", 0),
            ("srv", "postgres", 1),
        ):
            cols[label] = merge(
                [v for k, v in delta.items() if k[0] == METRICS[metric] and v[4].get("service.name") == svc],
                lambda res, attrs: (attrs.get("db.operation.name", "-"), attrs.get("db.collection.name", "")),
            )

        def cell_v(label, key, cols=cols):
            a = cols[label].get(key)
            if a is None and key[0] in ("BEGIN", "END"):
                a = cols[label].get((key[0], ""))
            return f"{1000 * a[1] / a[0]:.3f} ({a[0]})" if a else "-"

        for key, ms in stm.items():
            print(
                f"| {tag} | {key[0]} {key[1]} | {ms:.3f} | {cell_v('client', key)} | {cell_v('bin', key)} | {cell_v('bout', key)} | {cell_v('srv', key)} |"
            )

    print("\n### D. Everything OBI reported in the window, by service, metric and operation (counts in window)\n")
    print(
        "| cell | service | metric | operation | count | mean ms | p50 ms | p95 ms | instances | peers (server.address:server.port, db.namespace) |"
    )
    print("|---|---|---|---|---|---|---|---|---|---|")
    for tag, c in cells.items():
        if c["obi"] != "on":
            continue
        tas, delta, w = wins[tag]
        peers = defaultdict(lambda: defaultdict(int))
        for k, (n, _s, _bounds, _bk, res, attrs) in delta.items():
            pk = (res.get("service.name"), k[0], attrs.get("db.operation.name", "-"))
            peers[pk][
                f"{attrs.get('server.address', '')}:{attrs.get('server.port', '')},{attrs.get('db.namespace', '')}"
            ] += n
        agg = {}
        for k, (n, s, bounds, bk, res, attrs) in delta.items():
            kk = (res.get("service.name"), k[0], attrs.get("db.operation.name", "-"))
            a = agg.setdefault(kk, [0, 0.0, bounds, [0] * len(bk), set()])
            a[0] += n
            a[1] += s
            a[3] = [x + y for x, y in zip(a[3], bk, strict=True)]
            a[4].add(res.get("service.instance.id"))
        for kk, (n, s, bounds, bk, inst) in sorted(agg.items(), key=lambda i: (str(i[0][0]), i[0][1], -i[1][0])):
            pr = "; ".join(f"{p} x{cnt}" for p, cnt in sorted(peers[kk].items(), key=lambda i: -i[1])[:3])
            line = f"| {tag} | {kk[0]} | {kk[1].split('.')[1]} | {kk[2]} | {n} | {1000 * s / n:.3f} | "
            line += f"{1000 * quantile(0.5, bounds, bk):.3f} | {1000 * quantile(0.95, bounds, bk):.3f} | {len(inst)} | {pr} |"
            print(line)

    print("\n### E. Indicative overhead pair: same cell with OBI off and on (pgbench -r, whole run, ms)\n")
    off = [c for c in cells.values() if c["obi"] == "off"]
    for o in off:
        on = [
            c
            for c in cells.values()
            if c["obi"] == "on"
            and (c["route"], c["proto"], c["ssl"], c["script"]) == (o["route"], o["proto"], o["ssl"], o["script"])
        ]
        for n in on:
            so, sn = pgbench_statements(o), pgbench_statements(n)
            pct = 100 * n["obi_cpu_s"] / n["duration"]
            print(
                f"{o['tag']} (OBI off) vs {n['tag']} (OBI on); OBI CPU {n['obi_cpu_s']:.1f} s over {n['duration']:.0f} s = {pct:.1f}% of one core\n"
            )
            print("| statement | off | on | on - off |")
            print("|---|---|---|---|")
            for key in so:
                print(
                    f"| {key[0]} {key[1]} | {so[key]:.3f} | {sn.get(key, float('nan')):.3f} | {sn.get(key, float('nan')) - so[key]:+.3f} |"
                )

    print("\n### F. PgBouncer's own counters over the whole run (SHOW STATS deltas)\n")
    print("| cell | xacts | queries | mean query time us |")
    print("|---|---|---|---|")
    for tag, c in cells.items():
        if c["route"] == "bouncer":
            line = f"| {tag} | {c['pgbouncer_xacts']:.0f} | {c['pgbouncer_queries']:.0f} | "
            line += f"{c['pgbouncer_query_time_us'] / max(c['pgbouncer_queries'], 1):.0f} |"
            print(line)


if __name__ == "__main__":
    main()
