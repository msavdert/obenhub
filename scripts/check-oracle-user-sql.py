#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail when deploy/oracle/monitoring-user.sql and the lab's copy of the same
statements (lab/oracle/scripts/mon-lib.sh, run by provision.sh) differ.

The standalone script is what the guide (docs/guides/monitor/oracle.md) tells a
DBA to run; provision.sh builds the same SQL from mon-lib.sh and has run on the
lab VMs, so it is not rewritten to call the script (that would need a rerun of
the lab). This check keeps the two from drifting: every DDL statement the two
pass to EXECUTE IMMEDIATE (x('...')) is normalised (shell variables replaced by
the names of lab/oracle/pair.example.sh, string concatenation joined, the user
and password parameters of ensure_user named) and the two sets must be equal,
so a changed profile limit on CREATE or ALTER, an account option, a grantee or
a view fails. The ensure_user calls (which user gets which password) are compared too. Plain text
matching, standard library only, no network.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "deploy/oracle/monitoring-user.sql"
LIB = ROOT / "lab/oracle/scripts/mon-lib.sh"
PAIR = ROOT / "lab/oracle/pair.example.sh"


def pair_value(pair, var):
    m = re.search(rf"^{var}='([^']*)'", pair, re.M)
    if not m:
        sys.exit(f"{var} not found in {PAIR.relative_to(ROOT)}")
    return m.group(1)


def statements(text):
    """Normalised arguments of every x(...); call, as a sorted list."""
    out = []
    for m in re.finditer(r"\bx\(('.*?')\);", text, re.S):
        a = re.sub(r"'\s*\|\|\s*'", "", m.group(1))  # join 'a' || 'b'
        a = a.replace("' || u || '", "<u>").replace("' || pw || '", "<pw>")
        a = re.sub(r"\s+", " ", a.strip())
        if a.startswith("'") and a.endswith("'"):
            a = a[1:-1]
        if a == "s":  # the helper's own definition: PROCEDURE x(s VARCHAR2) ... EXECUTE IMMEDIATE s
            continue
        out.append(a)
    return sorted(out)


def main():
    sql, lib, pair = SQL.read_text(), LIB.read_text(), PAIR.read_text()
    names = {
        "$MON_USER": pair_value(pair, "MON_USER"),
        "$DG_USER": pair_value(pair, "DG_USER"),
        "$MON_PROFILE": pair_value(pair, "MON_PROFILE"),
    }
    m = re.search(r'^MON_VIEWS="([^"]*)"', lib, re.M)
    if not m:
        sys.exit(f"MON_VIEWS not found in {LIB.relative_to(ROOT)}")
    views = m.group(1).replace("\\$", "$").split()

    # the library's statements: the grants loop is expanded by hand, the rest is text in the heredoc and strings
    lab = lib.replace('\\"', '"')
    grant = re.search(r"x\('GRANT SELECT ON SYS\.\$v [^\n]*\n", lab)
    if not grant:
        sys.exit("grant loop not found in mon-lib.sh")
    lab = lab.replace(grant.group(0), "".join(grant.group(0).replace("$v", v) for v in views))
    for k, v in names.items():
        lab = lab.replace(k, v)
    lab = lab.replace("\\$", "$")

    got, want = statements(sql), statements(lab)
    errors = []
    for s in sorted(set(want) - set(got)):
        errors.append(f"only in mon-lib.sh: {s}")
    for s in sorted(set(got) - set(want)):
        errors.append(f"only in monitoring-user.sql: {s}")
    if len(got) != len(want) and not errors:
        errors.append(f"statement counts differ: {len(got)} against {len(want)}")

    # (user, password) pairs: each user must get its own password parameter
    users_sql = re.findall(r"ensure_user\('([^']+)',\s*([a-z_]+)\)", sql)
    pw_lab = {"$MON_PW": "mon_pw", "$DG_PW": "dg_pw"}
    users_lab = [
        (names.get(u, u), pw_lab.get(p, p))
        for u, p in re.findall(r"ensure_user\('(\$?[A-Z_]+)',\s*'(\$?[A-Z_]+)'\)", lib)
    ]
    if sorted(users_sql) != sorted(users_lab) or sorted(users_sql) != sorted(
        [(names["$MON_USER"], "mon_pw"), (names["$DG_USER"], "dg_pw")]
    ):
        errors.append(f"ensure_user calls differ: {users_sql} against {users_lab}")

    if errors:
        print("monitoring-user.sql and mon-lib.sh differ:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print(f"oracle user script: {len(got)} statements equal in both (grants, profile, users, SYSDG), users {users_sql}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
