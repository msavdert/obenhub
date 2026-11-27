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


def check_extension_paths(fleet, fleet_np, queries, majors):
    """The guard of the pg_stat_statements query (ADR 0009, decision 2), in every case.

    fleet loads the library (shared_preload_libraries), fleet_np does not. Each
    case must succeed (exit 0, no error) and give:

    - extension missing (library preloaded, before CREATE EXTENSION): no rows;
    - extension created: one 'instance' row and a 'database' row of database
    postgres (the happy path);
    - extension created at SQL version 1.8, before pg_stat_statements_info
    (1.9): the database rows still come out, no instance row, no error;
    - a database that had statements and was dropped: no row with an empty
    name (the totals of a dropped database are left out), the filter of the
    query's WHERE clause;
    - role without pg_read_all_settings, with the extension created and the
    library preloaded: no rows. Two roles: one with no grants and one with
    pg_read_all_stats only. Each is first shown to be refused
    current_setting('shared_preload_libraries') with SQLSTATE 42501, so the
    case exercises what it claims, and the second to read the view directly;
    - extension created, library not preloaded (fleet_np): no rows, for the
    monitoring role and for a superuser; reading the view directly is shown
    to fail there.

    Returns the list of mismatch lines.
    """
    ext = [q for q in queries if "pg_stat_statements" in q["sql"]]
    errors = []
    setting = "SELECT current_setting('shared_preload_libraries')"
    pw = ["-c", r"\getenv pw PGPASSWORD"]
    make_roles = (
        "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', r, :'pw') FROM unnest(ARRAY['guard_plain', 'guard_stats']) r \\gexec\n"
        "GRANT pg_read_all_stats TO guard_stats;"
    )

    def run_guard(f, major, role, want, label):
        for q in ext:
            p = f.psql(major, q["sql"], role=role, header=True)
            if p.returncode != 0:
                errors.append(f"{label} on {major} as {role}: exit {p.returncode}: {p.stderr.strip()[:160]}")
                continue
            lines = [ln for ln in p.stdout.split("\n") if ln][1:]
            if want == "none" and lines:
                errors.append(f"{label} on {major} as {role}: {len(lines)} rows, want none")
            if want in ("rows", "totals"):
                kinds = [ln.split("\t")[0] for ln in lines]
                names = [ln.split("\t")[1] for ln in lines if ln.startswith("database\t")]
                instances = 1 if want == "rows" else 0
                if kinds.count("instance") != instances or "postgres" not in names or "" in names:
                    errors.append(
                        f"{label} on {major} as {role}: rows {kinds} {names}, "
                        f"want {instances} instance, database postgres, no empty name"
                    )

    for major in majors:
        run_guard(fleet, major, "otel_monitor", "none", "extension missing")
        p = fleet.psql(major, "CREATE EXTENSION pg_stat_statements VERSION '1.8'", role="postgres")
        if p.returncode != 0:
            errors.append(f"CREATE EXTENSION VERSION '1.8' on {major}: {p.stderr.strip()[-200:]}")
            continue
        fleet.psql(major, "SELECT 1")  # at least one tracked statement of database postgres
        p = fleet.psql(major, "SELECT to_regclass('pg_stat_statements_info') IS NULL", role="postgres", tuples=True)
        if p.stdout.strip() != "t":
            errors.append(f"precondition on {major}: version 1.8 has pg_stat_statements_info ({p.stdout.strip()})")
        run_guard(fleet, major, "otel_monitor", "totals", "extension at version 1.8")
        p = fleet.psql(major, "ALTER EXTENSION pg_stat_statements UPDATE", role="postgres")
        if p.returncode != 0:
            errors.append(f"ALTER EXTENSION UPDATE on {major}: {p.stderr.strip()[-200:]}")
            continue
        fleet.psql(major, "SELECT 1")
        run_guard(fleet, major, "otel_monitor", "rows", "extension created")
        p = fleet.psql(major, "CREATE DATABASE guard_gone", role="postgres")
        p2 = fleet.psql(major, "SELECT 1 AS in_gone", role="postgres", extra=["-d", "guard_gone"])
        p3 = fleet.psql(major, "DROP DATABASE guard_gone", role="postgres")
        if p.returncode or p2.returncode or p3.returncode:
            errors.append(f"dropped database setup on {major}: {(p.stderr + p2.stderr + p3.stderr).strip()[-200:]}")
        else:
            p = fleet.psql(
                major,
                "SELECT count(*) FROM pg_stat_statements WHERE dbid NOT IN (SELECT oid FROM pg_database)",
                role="postgres",
                tuples=True,
            )
            if p.stdout.strip() in ("", "0"):
                errors.append(f"precondition on {major}: no statement of a dropped database in the view")
            run_guard(fleet, major, "otel_monitor", "rows", "dropped database")
        p = fleet.psql(major, make_roles, role="postgres", extra=pw)
        if p.returncode != 0:
            errors.append(f"guard roles on {major}: {p.stderr.strip()[-200:]}")
            continue
        for role in ("guard_plain", "guard_stats"):
            p = fleet.psql(major, setting, role=role)
            if p.returncode == 0 or "42501" not in p.stderr:
                errors.append(
                    f"precondition on {major}: {role} reads shared_preload_libraries ({p.stderr.strip()[:100]})"
                )
            run_guard(fleet, major, role, "none", "no pg_read_all_settings")
        p = fleet.psql(major, "SELECT count(*) FROM pg_stat_statements", role="guard_stats")
        if p.returncode != 0:
            errors.append(f"precondition on {major}: guard_stats cannot read the view: {p.stderr.strip()[:100]}")

        p = fleet_np.psql(major, "CREATE EXTENSION pg_stat_statements", role="postgres")
        if p.returncode != 0:
            errors.append(f"CREATE EXTENSION (not preloaded) on {major}: {p.stderr.strip()[-200:]}")
            continue
        p = fleet_np.psql(major, "SELECT count(*) FROM pg_stat_statements", role="postgres")
        if p.returncode == 0 or "shared_preload_libraries" not in p.stderr:
            errors.append(f"precondition on {major}: the view reads without the library ({p.stderr.strip()[:100]})")
        run_guard(fleet_np, major, "otel_monitor", "none", "not preloaded")
        run_guard(fleet_np, major, "postgres", "none", "not preloaded")
    print(
        f"extension guard: {len(ext)} queries, {len(majors)} majors: extension missing, created, "
        "version 1.8, dropped database, no pg_read_all_settings (no grants, pg_read_all_stats only), not preloaded"
    )
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
CREATE TABLE sv_j (i int) WITH (autovacuum_vacuum_threshold = 5, autovacuum_vacuum_scale_factor = 0);
INSERT INTO sv_j SELECT generate_series(1, 100);
VACUUM sv_j;
DELETE FROM sv_j;
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
    sv_c is far past its threshold; not sv_j (100 > 5, but a VACUUM finished on
    it within three autovacuum_naptime intervals, the recency condition that
    keeps small hot tables autovacuum keeps up with out). The settings read 0 for autovacuum and 1
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
    print(
        f"slow tier values: {len(majors)} majors, storage parameters, scale factor, disabled and recently vacuumed tables, settings"
    )
    return errors


def check_slot_safe_wal(fleet, queries, majors):
    """safe_wal_size and the WAL counter (F5), on every major, as the monitoring role.

    By metric: the query of postgresql.replication_slot.safe_wal_size has no row for
    a slot while max_slot_wal_keep_size is -1 (the NULL case, filtered), one row with a
    value in (0, keep + one segment] once it is set to 64MB (the finite case), and no row for a slot
    that is lost (about 200 MB written and a CHECKPOINT with the slot unconsumed); a slot
    created without reserving WAL (no restart_lsn) has no row either.
    postgresql.wal.written returns one row on the primary whose value grows after a
    WAL record. Returns the list of mismatch lines.
    """
    by_metric = {q["metric"]: q for q in queries}
    safe_sql = by_metric["postgresql.replication_slot.safe_wal_size"]["sql"]
    wal_sql = by_metric["postgresql.wal.written"]["sql"]

    def rows(major, sql):
        p = fleet.psql(major, sql, tuples=True)
        if p.returncode != 0:
            return None, p.stderr.strip()[-160:]
        return [ln for ln in p.stdout.split("\n") if ln], ""

    def one(major):
        out = []

        def adm(sql):
            p = fleet.psql(major, sql, role="postgres")
            if p.returncode != 0:
                out.append(f"slot setup on {major}: {p.stderr.strip()[-160:]}")
            return p.returncode == 0

        if not adm(
            "SELECT pg_create_physical_replication_slot('sw_reserved', true);"
            "SELECT pg_create_physical_replication_slot('sw_noreserve', false)"
        ):
            return out
        got, err = rows(major, safe_sql)
        if got != []:
            out.append(f"safe_wal_size on {major} with max_slot_wal_keep_size -1: want no row, got {got} {err}")
        if not adm("ALTER SYSTEM SET max_slot_wal_keep_size = '64MB'; SELECT pg_reload_conf()"):
            return out
        for _ in range(10):
            got, err = rows(major, safe_sql)
            if got:
                break
            time.sleep(1)
        ok = got is not None and len(got) == 1 and got[0].split("\t")[0] == "sw_reserved"
        if ok:
            val = float(got[0].split("\t")[2])
            ok = (
                0 < val <= 80 * 1024 * 1024
            )  # the limit plus up to one 16 MB segment of slack (restart_lsn is mid-segment)
        if not ok:
            out.append(
                f"safe_wal_size on {major} with 64MB: want one row for sw_reserved in (0, 80 MiB], got {got} {err}"
            )
        got1, _ = rows(major, wal_sql)
        adm("SELECT pg_logical_emit_message(false, 'obenhub', 'x')")
        got2, err = rows(major, wal_sql)
        if not (got1 and got2 and len(got1) == 1 and len(got2) == 1 and int(got2[0]) > int(got1[0]) > 0):
            out.append(f"wal.written on {major}: want one growing row, got {got1} then {got2} {err}")
        # 200 MB past the limit, before any CHECKPOINT: the slot is unreserved and the raw
        # safe_wal_size is negative; the query must give a row of 0, not a negative number
        adm(
            "CREATE TABLE sw_fill AS SELECT g, repeat('x', 100) AS pad FROM generate_series(1, 1500000) g;"
            "SELECT pg_switch_wal()"
        )
        p = fleet.psql(
            major,
            "SELECT wal_status, safe_wal_size FROM pg_replication_slots WHERE slot_name = 'sw_reserved'",
            tuples=True,
        )
        raw = p.stdout.strip()
        got, err = rows(major, safe_sql)
        if raw.startswith("unreserved"):
            if not (
                int(raw.split("\t")[1]) < 0
                and got
                and got[0].split("\t")[0] == "sw_reserved"
                and float(got[0].split("\t")[2]) == 0
            ):
                out.append(
                    f"safe_wal_size on {major} for an unreserved slot: want one row of 0 (raw {raw!r}), got {got} {err}"
                )
            else:
                print(f"  unreserved case reached on {major}: raw {raw.split(chr(9))[1]} -> 0")
        else:
            out.append(f"unreserved case not reached on {major} (status {raw!r}); the clamp is untested there")
        # then CHECKPOINT: the slot is lost, safe_wal_size is NULL
        adm("CHECKPOINT; CHECKPOINT")
        for _ in range(10):
            got, err = rows(major, safe_sql)
            if got == []:
                break
            time.sleep(1)
        else:
            p = fleet.psql(
                major, "SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'sw_reserved'", tuples=True
            )
            out.append(
                f"safe_wal_size on {major} for a lost slot: want no row, got {got} (wal_status {p.stdout.strip()!r})"
            )
        return out

    errors = []
    with ThreadPoolExecutor(len(majors)) as ex:
        for res in ex.map(one, majors):
            errors += res
    print(f"slot safe_wal_size and WAL counter: {len(majors)} majors, NULL for -1, finite, lost and no-reserve slots")
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
    with packsql.Fleet(majors, images) as fleet, packsql.Fleet(majors, images, preload=False) as fleet_np:
        fleet.start()
        fleet_np.start()
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
        ext_errors = (
            check_extension_paths(fleet, fleet_np, queries, majors)
            + check_slow_values(fleet, queries, majors)
            + check_slot_safe_wal(fleet, queries, majors)
        )

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
