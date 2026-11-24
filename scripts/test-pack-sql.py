# SPDX-License-Identifier: Apache-2.0
"""Run every query of packs/postgresql/queries.yaml and queries-slow.yaml on every supported major.

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


def data_rows(p):
    """Number of result rows of a psql run with header (-A, footer off)."""
    return max(len([ln for ln in p.stdout.split("\n") if ln]) - 1, 0)


def check_extension_paths(fleet, queries, majors):
    """The guard of the pg_stat_statements queries (ADR 0009, decision 2), both ways.

    The containers load the library (shared_preload_libraries) but the first
    pass runs before CREATE EXTENSION: each such query must then succeed with
    no rows. After CREATE EXTENSION in database postgres each must succeed with
    at least one row. Returns the list of mismatch lines.
    """
    ext = [q for q in queries if "pg_stat_statements" in q["sql"]]
    errors = []
    for phase, want_rows in (("without the extension", False), ("with the extension", True)):
        for major in majors:
            if want_rows:
                p = fleet.psql(major, "CREATE EXTENSION pg_stat_statements", role="postgres")
                if p.returncode != 0:
                    errors.append(f"CREATE EXTENSION on {major}: {p.stderr.strip()[-200:]}")
                    continue
                fleet.psql(major, "SELECT 1")  # at least one tracked statement of database postgres
            for q in ext:
                p = fleet.psql(major, q["sql"], header=True)
                if p.returncode != 0:
                    errors.append(f"query {q['n']} on {major} {phase}: exit {p.returncode}: {p.stderr.strip()[:120]}")
                elif (data_rows(p) > 0) != want_rows:
                    errors.append(f"query {q['n']} on {major} {phase}: {data_rows(p)} rows")
    print(f"extension guard: {len(ext)} queries, {len(majors)} majors, with and without the extension")
    return errors


SLOW_SETUP = """
ALTER SYSTEM SET autovacuum = off;
SELECT pg_reload_conf();
CREATE TABLE sv_a (i int) WITH (autovacuum_vacuum_threshold = 5, autovacuum_vacuum_scale_factor = 0);
CREATE TABLE sv_b (i int) WITH (autovacuum_vacuum_threshold = 100000, autovacuum_vacuum_scale_factor = 0);
CREATE TABLE sv_c (i int) WITH (autovacuum_enabled = off, autovacuum_vacuum_threshold = 5, autovacuum_vacuum_scale_factor = 0);
CREATE TABLE sv_e (i int) WITH (autovacuum_enabled = false);
CREATE TABLE sv_d (i int);
CREATE TABLE sv_f (i int) WITH (autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0.5);
CREATE TABLE sv_g (i int) WITH (autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0.5);
INSERT INTO sv_f SELECT generate_series(1, 1000);
INSERT INTO sv_g SELECT generate_series(1, 1000);
ANALYZE sv_f;
ANALYZE sv_g;
INSERT INTO sv_a SELECT generate_series(1, 100);
INSERT INTO sv_b SELECT generate_series(1, 100);
INSERT INTO sv_c SELECT generate_series(1, 100);
INSERT INTO sv_d SELECT generate_series(1, 10);
DELETE FROM sv_a;
DELETE FROM sv_b;
DELETE FROM sv_c;
DELETE FROM sv_d;
DELETE FROM sv_f WHERE i <= 400;
DELETE FROM sv_g WHERE i <= 600;
"""
# 18 and later cap the threshold (autovacuum_vacuum_max_threshold); 500 would not be reached by 150 dead tuples, the cap of 100 is
SLOW_SETUP_18 = """
CREATE TABLE sv_h (i int) WITH (autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0.5, autovacuum_vacuum_max_threshold = 100);
INSERT INTO sv_h SELECT generate_series(1, 1000);
ANALYZE sv_h;
DELETE FROM sv_h WHERE i <= 150;
ALTER SYSTEM SET autovacuum_vacuum_max_threshold = 100;
SELECT pg_reload_conf();
CREATE TABLE sv_i (i int) WITH (autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0.5, autovacuum_vacuum_max_threshold = -1);
INSERT INTO sv_i SELECT generate_series(1, 1000);
ANALYZE sv_i;
DELETE FROM sv_i WHERE i <= 300;
"""


def check_slow_values(fleet, queries, majors):
    """The slow-tier queries return the values the setup implies (README, "Slow tier").

    Autovacuum is switched off in the container so that nothing races the
    counts. Expected in database postgres: pending tables sv_a (storage
    parameters, 100 > 5), sv_g (600 > 0.5 * 1000) and, from 18, sv_h (150 over
    its cap of 100) and sv_f (400 over the global cap of 100); not sv_b (100 <
    100000, and not over the cap of 100 from 18), sv_d (10 < 50), sv_f below 18
    (400 < 500), sv_i (300 < 500: its per-table -1 lifts the global cap);
    disabled sv_c and sv_e (`off` and `false`), which are not pending although
    sv_c is far past its threshold. The settings read 0 for autovacuum and 1
    for track_counts. The no-row case on a standby is not tested here.
    """
    by_metric = {q["metric"]: q for q in queries}
    errors = []

    def one(major):
        out = []
        p = fleet.psql(major, SLOW_SETUP + (SLOW_SETUP_18 if major >= 18 else ""), role="postgres")
        if p.returncode != 0:
            return [f"slow setup on {major}: {p.stderr.strip()[-200:]}"]
        want_pending = 4 if major >= 18 else 2
        for metric, want in (
            ("postgresql.collection.slow_heartbeat", "1\tpostgres"),
            ("postgresql.autovacuum.pending_table.count", f"postgres\t{want_pending}\t2"),
            ("postgresql.autovacuum.enabled", "postgres\t0\t1"),
        ):
            for _ in range(10):  # the reload of autovacuum = off and the statistics flush are asynchronous
                p = fleet.psql(major, by_metric[metric]["sql"], tuples=True)
                got = p.stdout.strip()
                if p.returncode == 0 and got == want:
                    break
                time.sleep(1)
            else:
                out.append(f"{metric} on {major}: want {want!r}, got {got!r} {p.stderr.strip()[-120:]}")
        return out

    with ThreadPoolExecutor(len(majors)) as ex:
        for res in ex.map(one, majors):
            errors += res
    print(f"slow tier values: {len(majors)} majors, storage parameters, scale factor, disabled tables and settings")
    return errors


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
        ext_errors = check_extension_paths(fleet, queries, majors) + check_slow_values(fleet, queries, majors)

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
    for line in ext_errors:
        print(f"mismatch: {line}", file=sys.stderr)
    mismatches += len(ext_errors)
    if mismatches or bad:
        print(f"FAILED: {mismatches} mismatches, {len(bad)} queries without pg-min", file=sys.stderr)
        return 1
    print("pack SQL matches pg-min on every supported major")
    return 0


if __name__ == "__main__":
    sys.exit(main())
