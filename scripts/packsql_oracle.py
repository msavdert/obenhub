# SPDX-License-Identifier: Apache-2.0
"""Shared helpers of test-pack-sql-oracle.py and pack-catalog-diff-oracle.py.

The Oracle half of roadmap item E1. There is no throwaway Oracle container, so
the scripts run read-only queries on the lab VM that holds the databases: the
host is PRIMARY_HOST of lab/oracle/pair.sh (untracked, so these scripts are not
part of `mise run check`), the Oracle home of a SID is read from the remote
/etc/oratab, and SQL*Plus runs as `sudo -u oracle ... sqlplus -s / as sysdba`
with the SQL on stdin (operating-system authentication, no password). Only
statements that start with SELECT or WITH are sent. The packs run as SYSDG or
the monitoring user in production; as SYSDBA a missing privilege is not seen.
"""

import re
import shlex
import subprocess

import packsql

REPO = packsql.REPO
PAIR = REPO / "lab/oracle/pair.sh"
PAIR_EXAMPLE = REPO / "lab/oracle/pair.example.sh"
PACK_FILES = [
    REPO / "packs/oracledb-dg/queries.yaml",
    REPO / "packs/oracledb-dg/queries-primary.yaml",
    REPO / "packs/oracledb-backup/queries.yaml",
]
DEFAULT_SIDS = ["CDB19", "CDB19B", "CDB26"]
SID_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,11}")
# ORA-00942 table or view does not exist, ORA-00904 invalid identifier: the object is not on this release.
MISSING_CODES = {"ORA-00942", "ORA-00904"}
# One SQL*Plus statement per query; blank lines and ampersands in the SQL must not end or change it.
SESSION_HEAD = """\
set echo off feedback off heading off pagesize 0 linesize 32767 trimout on trimspool on
set define off sqlblanklines on timing off verify off serveroutput off
whenever sqlerror continue
"""


def lab_host():
    """PRIMARY_HOST of lab/oracle/pair.sh, read the way the lab scripts do (sourced by bash)."""
    if not PAIR.is_file():
        raise SystemExit(
            f"{PAIR.relative_to(REPO)} is missing; copy {PAIR_EXAMPLE.relative_to(REPO)} to it and edit it"
        )
    p = subprocess.run(
        ["bash", "-c", '. "$1" && printf %s "$PRIMARY_HOST"', "_", str(PAIR)],
        capture_output=True,
        text=True,
        check=False,
    )
    host = p.stdout.strip()
    if p.returncode != 0 or not re.fullmatch(r"[A-Za-z0-9._-]+", host):
        raise SystemExit(f"{PAIR.relative_to(REPO)}: PRIMARY_HOST not readable: {p.stderr.strip()[-200:] or host!r}")
    return host


def check_sids(sids):
    for sid in sids:
        if not SID_RE.fullmatch(sid):
            raise SystemExit(f"not an Oracle SID: {sid!r}")


def load_queries():
    """Return the entries of every pack file, each with its `file` and a pack-wide number `n`.

    `ora_min` is the `# ora-min: <version>` comment as a tuple of ints, or None.
    Raises ValueError for a query that does not start with SELECT or WITH or
    holds a semicolon, so nothing but a read-only SELECT is ever sent.
    """
    out = []
    for path in PACK_FILES:
        for q in packsql.read_queries(path, tag="ora-min"):
            if not re.match(r"\s*(SELECT|WITH)\b", q["sql"], re.I) or ";" in q["sql"]:
                raise ValueError(f"{path.relative_to(REPO)} query {q['n']}: not a single SELECT/WITH statement")
            q["file"] = str(path.relative_to(REPO))
            q["n"] = len(out) + 1
            q["ora_min"] = version_tuple(q["min"]) if q["min"] else None
            out.append(q)
    return out


def version_tuple(text):
    return tuple(int(x) for x in text.split("."))


def at_least(version, minimum):
    """True when the version (a tuple) is not below the minimum (a tuple, possibly shorter)."""
    return version[: len(minimum)] >= minimum


def oracle_home(host, sid):
    """ORACLE_HOME of the SID from the remote /etc/oratab."""
    p = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "cat /etc/oratab"],
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0:
        raise RuntimeError(f"ssh {host}: cat /etc/oratab: exit {p.returncode}: {p.stderr.strip()[-300:]}")
    for line in p.stdout.splitlines():
        name, _, rest = line.partition(":")
        if name == sid:
            home = rest.split(":")[0]
            if re.fullmatch(r"/[A-Za-z0-9_./-]+", home):
                return home
            raise RuntimeError(f"/etc/oratab on {host}: unusable home for {sid}: {home!r}")
    raise RuntimeError(f"/etc/oratab on {host} has no entry for {sid}")


def sqlplus(host, sid, script):
    """Run the script in one SQL*Plus session as SYSDBA on the SID; returns stdout (SQL errors stay in it)."""
    home = oracle_home(host, sid)
    remote = (
        f"sudo -u oracle env ORACLE_SID={shlex.quote(sid)} ORACLE_HOME={shlex.quote(home)} "
        f"{shlex.quote(home + '/bin/sqlplus')} -s -L '/ as sysdba'"
    )
    p = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remote],
        input=SESSION_HEAD + script + "\nexit\n",
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0 and not p.stdout:
        raise RuntimeError(f"{sid} on {host}: exit {p.returncode}: {p.stderr.strip()[-300:]}")
    return p.stdout


INSTANCE_SQL = """\
SELECT '@@INSTANCE|' || i.version_full || '|' || d.database_role || '|' || d.open_mode
FROM v$instance i CROSS JOIN v$database d;
"""


def instance(out, sid):
    """Return (version_full, role, open_mode) from the @@INSTANCE line of a session's output."""
    for line in out.splitlines():
        if line.startswith("@@INSTANCE|"):
            return tuple(line.split("|")[1:4])
    raise RuntimeError(f"{sid}: no version line; output starts: {out.strip()[:300]!r}")


def error_code(text):
    """First ORA-/SP2- code in the text, or None."""
    m = re.search(r"\b(ORA|SP2)-\d{4,5}", text)
    return m.group(0) if m else None


def identifiers(queries):
    """Upper-case identifiers of the SQL outside string literals and quoted aliases, sorted."""
    text = "\n".join(q["sql"] for q in queries)
    bare = re.sub(r"'(?:[^']|'')*'", " ", text)
    bare = re.sub(r'"[^"]*"', " ", bare)
    return sorted({m.upper() for m in re.findall(r"[A-Za-z_][A-Za-z0-9_$#]*", bare)})


def in_list(names, width=100):
    """A SQL IN-list body ('A', 'B', ...) wrapped onto short lines (SQL*Plus caps a line)."""
    lines, cur = [], ""
    for n in names:
        item = f"'{n}', "
        if len(cur) + len(item) > width:
            lines.append(cur)
            cur = ""
        cur += item
    lines.append(cur)
    return "\n".join(lines).rstrip(", ")
