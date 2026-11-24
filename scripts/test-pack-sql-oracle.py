# SPDX-License-Identifier: Apache-2.0
"""Run every query of the Oracle packs on the lab databases, one SQL*Plus session per SID.

usage: test-pack-sql-oracle.py [SID ...]     (default: CDB19 CDB19B CDB26)

The queries of packs/oracledb-dg/queries.yaml, queries-primary.yaml and
packs/oracledb-backup/queries.yaml, each wrapped as
`SELECT COUNT(*), COUNT("<column>"), ... FROM (<query>)` so that no row is
printed, and every value_column and attribute_column of its metrics must be a
column of the result. A query may carry `# ora-min: <version>` (for example
`23`) in its comment block: it is expected to fail with ORA-00942 or ORA-00904
below that release and to succeed from it up. Without the comment it must
succeed on every SID. Prints the version_full of each SID and a matrix; exit 1
on any mismatch.

Needs ssh to PRIMARY_HOST of lab/oracle/pair.sh and sudo to the oracle user
there, so it is not part of `mise run check`. Only queries run, as SYSDBA by
operating-system authentication (packsql_oracle.py); the packs' own users
(SYSDG, the monitoring user) are not exercised. Run it when a release update
or a new release is installed on the lab.
"""

import re
import sys

import packsql_oracle as po


def wrapper(q):
    cols = "".join(f', COUNT("{c}")' for c in q["columns"] if c)
    return f"PROMPT @@Q {q['n']}\nSELECT COUNT(*){cols} FROM (\n{q['sql']}\n);\n"


def run_sid(host, sid, queries):
    """Return ((version_full, role, open_mode), {n: "ok" | "ORA-nnnnn" | "FAIL:<text>"})."""
    script = po.INSTANCE_SQL + "".join(wrapper(q) for q in queries)
    out = po.sqlplus(host, sid, script)
    info = po.instance(out, sid)
    blocks = re.split(r"^@@Q (\d+)$", out, flags=re.M)[1:]  # [n, text, n, text, ...]
    res = {}
    for n, text in zip(blocks[0::2], blocks[1::2], strict=True):
        code = po.error_code(text)
        if code:
            res[int(n)] = code
        elif re.search(r"^\s*\d+(\s+\d+)*\s*$", text, re.M):
            res[int(n)] = "ok"
        else:
            res[int(n)] = "FAIL:no result: " + (text.strip()[:80] or "empty")
    return info, res


def main(argv):
    sids = argv[1:] or po.DEFAULT_SIDS
    po.check_sids(sids)
    queries = po.load_queries()
    host = po.lab_host()

    infos, results = {}, {}
    for sid in sids:
        infos[sid], results[sid] = run_sid(host, sid, queries)
        missing = [q["n"] for q in queries if q["n"] not in results[sid]]
        if missing:
            raise RuntimeError(f"{sid}: no result for queries {missing}")

    for sid in sids:
        print(f"{sid:<8} version_full {infos[sid][0]}  {infos[sid][1]} {infos[sid][2]}")
    width = max(len(s) for s in sids + ["ok!"]) + 1
    print("\nquery  metric" + " " * 44 + "ora-min  " + " ".join(f"{s:>{width}}" for s in sids))
    mismatches = 0
    for q in queries:
        cells = []
        for sid in sids:
            res = results[sid][q["n"]]
            version = po.version_tuple(infos[sid][0])
            want_ok = q["ora_min"] is None or po.at_least(version, q["ora_min"])
            if res == "ok":
                good, cell = want_ok, "ok"
            elif res in po.MISSING_CODES:
                good, cell = not want_ok, res.lower()
            elif res.startswith("ORA-") or res.startswith("SP2-"):
                good, cell = False, res.lower()
            else:
                good, cell = False, "FAIL"
            if not good:
                mismatches += 1
                cell += "!"
                print(f"mismatch: query {q['n']} ({q['file']}) on {sid}: {res}", file=sys.stderr)
            cells.append(f"{cell:>{width}}")
        print(f"{q['n']:>5}  {q['metric']:<50}{q['min'] or '-':>7}  " + " ".join(cells))
    print(f"{len(queries)} queries from {', '.join(str(p.relative_to(po.REPO)) for p in po.PACK_FILES)} on {host}")
    if mismatches:
        print(f"FAILED: {mismatches} mismatches", file=sys.stderr)
        return 1
    print("pack SQL matches ora-min on every SID")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
