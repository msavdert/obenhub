# SPDX-License-Identifier: Apache-2.0
"""List what changed between two Oracle databases in the dictionary objects the packs read.

usage: pack-catalog-diff-oracle.py <old-SID> <new-SID>     (for example CDB19B CDB19, or CDB19 CDB26)

Taken from the SQL of packs/oracledb-dg/queries.yaml, queries-primary.yaml and
packs/oracledb-backup/queries.yaml, outside string literals and quoted
aliases: every identifier is looked up as a public synonym of a SYS object (V$
and GV$ names resolve to SYS.V_$ and SYS.GV_$ views, DBA_ names to SYS views) in
DBA_SYNONYMS of the CDB root of each database; DBA_VIEWS tells a view from a
table. Relations present on either side are listed when added or removed; for
a relation present on both, only the columns whose name appears in the SQL are
compared (DBA_TAB_COLUMNS: name, data_type, data_length). Functions, packages
and parameters are not compared. Common words that are also column names
(NAME, VALUE, TYPE) are looked up like any other identifier. Printed as a
Markdown list like pack-catalog-diff.py.

Needs ssh to PRIMARY_HOST of lab/oracle/pair.sh (see packsql_oracle.py), so it
is not part of `mise run check`. Run it when a release update or a new release
is installed on the lab, with the SID of the old and the new one.
"""

import sys

import packsql_oracle as po

# One pipe-separated line per public synonym of a SYS object and per column of its target
# (a SQL keyword such as CROSS is also a public synonym of MDSYS.OGC_CROSS).
PROBE = """\
SELECT '@@REL|' || s.synonym_name || '|' || s.table_owner || '.' || s.table_name || '|'
    || CASE WHEN v.view_name IS NULL THEN 'table' ELSE 'view' END
FROM dba_synonyms s
LEFT JOIN dba_views v ON v.owner = s.table_owner AND v.view_name = s.table_name
WHERE s.owner = 'PUBLIC' AND s.table_owner = 'SYS' AND s.synonym_name IN (
{names}
)
ORDER BY 1;
SELECT '@@COL|' || s.synonym_name || '|' || c.column_name || '|' || c.data_type || '|' || c.data_length
FROM dba_synonyms s
JOIN dba_tab_columns c ON c.owner = s.table_owner AND c.table_name = s.table_name
WHERE s.owner = 'PUBLIC' AND s.table_owner = 'SYS' AND s.synonym_name IN (
{names}
) AND c.column_name IN (
{names}
)
ORDER BY 1;
"""


def probe(host, sid, names):
    """Return ((version_full, role, open_mode), {relation: kind}, {relation: {column: type}})."""
    out = po.sqlplus(host, sid, po.INSTANCE_SQL + PROBE.format(names=po.in_list(names)))
    info = po.instance(out, sid)
    code = po.error_code(out)
    if code:
        raise RuntimeError(f"{sid}: dictionary probe failed with {code}: {out.strip()[:300]}")
    rels, cols = {}, {}
    for line in out.splitlines():
        parts = line.split("|")
        if parts[0] == "@@REL":
            rels[parts[1]] = f"{parts[3]} {parts[2]}"
        elif parts[0] == "@@COL":
            cols.setdefault(parts[1], {})[parts[2]] = f"{parts[3]}({parts[4]})"
    return info, rels, cols


def main(argv):
    if len(argv) != 3 or argv[1] == argv[2]:
        print("usage: pack-catalog-diff-oracle.py <old-SID> <new-SID>   (for example CDB19B CDB19)", file=sys.stderr)
        return 2
    old, new = argv[1], argv[2]
    po.check_sids([old, new])
    queries = po.load_queries()
    names = po.identifiers(queries)
    host = po.lab_host()
    (v_old, _, _), r_old, c_old = probe(host, old, names)
    (v_new, _, _), r_new, c_new = probe(host, new, names)

    out = []
    for rel in sorted(set(r_old) | set(r_new)):
        if rel not in r_new:
            out.append(f"- relation `{rel}` ({r_old[rel]}) removed in {new}")
        elif rel not in r_old:
            out.append(
                f"- relation `{rel}` ({r_new[rel]}) added in {new}: " + ", ".join(f"`{c}`" for c in c_new.get(rel, {}))
            )
        else:
            for col, typ in c_new.get(rel, {}).items():
                if col not in c_old.get(rel, {}):
                    out.append(f"- `{rel}.{col}` ({typ}) added in {new}")
                elif c_old[rel][col] != typ:
                    out.append(f"- `{rel}.{col}` type {c_old[rel][col]} -> {typ}")
            for col, typ in c_old.get(rel, {}).items():
                if col not in c_new.get(rel, {}):
                    out.append(f"- `{rel}.{col}` ({typ}) removed in {new}")

    print(f"# Dictionary objects the Oracle packs read: {old} {v_old} -> {new} {v_new}\n")
    print(
        f"Looked up {len(names)} identifiers from the pack SQL; {len(r_old)} resolve to a public synonym on {old}, "
        f"{len(r_new)} on {new}.\n"
    )
    print("\n".join(out) if out else "No difference in the relations and columns the packs read.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
