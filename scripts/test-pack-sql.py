# SPDX-License-Identifier: Apache-2.0
"""Run every query of packs/postgresql/queries.yaml on every supported major.

One throwaway container per major (packs/postgresql/tests/images.sh), the
monitoring role applied as postgres, each query run as otel_monitor. A query
carries `# pg-min: <N>` in its comment block. Expected: it succeeds on majors
>= N and fails with an object-missing SQL error (SQLSTATE 42703, 42883, 42P01 or
42704) on majors < N; a connection error or any other failure
is a mismatch, and so is a query without pg-min. On success every
value_column and attribute_column of the query's metrics must be a column of
the result. Leftover containers with the test's label are removed at start. Prints a matrix; exit 1 on
any mismatch. Containers are removed by label on exit, also on a signal.
"""

import re
import signal
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import packsql

# SQLSTATEs of "the object does not exist on this major": undefined column,
# function, table, object. Anything else (42501 privilege, 42601 syntax, ...) is a failure.
MISSING_STATES = {"42703", "42883", "42P01", "42704"}


def main():
    queries = packsql.read_queries()
    images = packsql.read_images()
    majors = sorted(images)
    if not queries or not majors:
        print("no queries or no images found", file=sys.stderr)
        return 1
    bad = [q for q in queries if q["pg_min"] is None]
    for q in bad:
        print(f"query {q['n']} ({q['metric']}) has no '# pg-min: <N>' comment", file=sys.stderr)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    t0 = time.monotonic()
    results = {}  # (n, major) -> "ok" | "err:<sqlstate>" | "fail:<text>"
    with packsql.Fleet(majors, images) as fleet:
        fleet.start()
        t1 = time.monotonic()

        def work(job):
            q, major = job
            p = fleet.psql(major, q["sql"], header=True)
            if p.returncode == 0:
                got = set(p.stdout.split("\n", 1)[0].split("\t"))
                missing = [c for c in q["columns"] if c not in got]
                return job, ("cols:" + ",".join(missing)) if missing else "ok"
            m = re.search(r"ERROR:\s+(\w{5}):", p.stderr)
            if m and p.returncode == 3:
                return job, f"err:{m.group(1)}"
            lines = p.stderr.strip().splitlines()
            return job, "fail:" + (lines[0][:120] if lines else f"exit {p.returncode}")

        jobs = [(q, m) for q in queries for m in majors]
        with ThreadPoolExecutor(8) as ex:
            for (q, major), res in ex.map(work, jobs):
                results[(q["n"], major)] = res

    mismatches = 0
    print("query  metric" + " " * 44 + "pg-min  " + "  ".join(f"{m:>5}" for m in majors))
    for q in queries:
        cells = []
        for m in majors:
            res = results[(q["n"], m)]
            want_ok = q["pg_min"] is not None and m >= q["pg_min"]
            if res == "ok":
                good = want_ok
                cell = "ok"
            elif res.startswith("err:") and res[4:] in MISSING_STATES:
                good = q["pg_min"] is not None and not want_ok
                cell = "sqlerr"
            elif res.startswith("cols:"):
                good = False
                cell = "COLS"
            else:
                good = False
                cell = "FAIL"
            if not good:
                mismatches += 1
                cell += "!"
                print(f"mismatch: query {q['n']} on {m}: {res}", file=sys.stderr)
            cells.append(f"{cell:>5}")
        print(
            f"{q['n']:>5}  {q['metric']:<50}{q['pg_min'] if q['pg_min'] is not None else '-':>6}  " + "  ".join(cells)
        )
    print(f"setup {t1 - t0:.0f}s, queries {time.monotonic() - t1:.0f}s, majors {majors}")
    if mismatches or bad:
        print(f"FAILED: {mismatches} mismatches, {len(bad)} queries without pg-min", file=sys.stderr)
        return 1
    print("pack SQL matches pg-min on every supported major")
    return 0


if __name__ == "__main__":
    sys.exit(main())
