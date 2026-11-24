# SPDX-License-Identifier: Apache-2.0
"""List what changed between two PostgreSQL majors in the catalog objects the pack reads.

usage: pack-catalog-diff.py <old-major> <new-major>   (old lower than new)

Taken from the SQL of packs/postgresql/queries.yaml, outside string literals:
identifiers are matched against pg_catalog relations (tables, views) of either
major and, for a relation present on both, only the columns whose name appears
in the SQL are compared (name, type), including names that appear only as
an identifier-shaped string literal (a jsonb key of to_jsonb(row)); a name followed by `(` is matched
against pg_catalog functions (compared by argument types and result type); a
string literal shaped like a setting name is matched against pg_settings
(existence). Everything is read from both majors and printed as a Markdown
list of what was added, removed or changed. Common words that are also
function names (max, count) can show up when an overload changes. Uses the
images of packs/postgresql/tests/images.sh. Run it when Renovate or the EOL
check brings a new version, with the old and the new major.
"""

import re
import sys

import packsql

# One row per relation column, relation, function and setting; fields are tab separated.
PROBE = """
WITH ids(name) AS (SELECT unnest(string_to_array('{names}', ','))),
    fns(name) AS (SELECT unnest(string_to_array('{funcs}', ','))),
    sets(name) AS (SELECT unnest(string_to_array('{settings}', ',')))
SELECT 'col', c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'pg_catalog'
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.relname IN (SELECT name FROM ids) AND a.attname IN (SELECT name FROM ids)
    AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
UNION ALL
SELECT 'rel', c.relname, '', ''
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'pg_catalog'
WHERE c.relname IN (SELECT name FROM ids) AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
UNION ALL
SELECT 'fn', p.proname, oidvectortypes(p.proargtypes), pg_get_function_result(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'pg_catalog'
WHERE p.proname IN (SELECT name FROM fns)
UNION ALL
SELECT 'set', name, '', '' FROM pg_settings WHERE name IN (SELECT name FROM sets)
ORDER BY 1, 2, 3;
"""


def lookups(queries):
    """Return (identifiers, function names, setting-shaped literals) of the SQL."""
    text = "\n".join(q["sql"] for q in queries)
    literals = re.findall(r"'((?:[^']|'')*)'", text)
    bare = re.sub(r"'(?:[^']|'')*'", " ", text)
    idents = sorted(set(re.findall(r"\b[a-z_][a-z0-9_]*\b", bare)))
    funcs = sorted(set(re.findall(r"\b([a-z_][a-z0-9_]*)\s*\(", bare)))
    settings = sorted({lit for lit in literals if re.fullmatch(r"[a-z_][a-z0-9_.]*", lit)})
    # Column names read as jsonb keys (to_jsonb(t)->>'col') live in literals.
    idents = sorted(set(idents) | {lit for lit in settings if "." not in lit})
    return idents, funcs, settings


def probe(fleet, major, look):
    names, funcs, settings = look
    p = fleet.psql(
        major, PROBE.format(names=",".join(names), funcs=",".join(funcs), settings=",".join(settings)), tuples=True
    )
    if p.returncode != 0:
        raise RuntimeError(f"catalog probe on {major}: {p.stderr.strip()[:300]}")
    rels, cols, fns, sets = set(), {}, {}, set()
    for line in p.stdout.splitlines():
        kind, a, b, c = (line.split("\t") + ["", "", ""])[:4]
        if kind == "rel":
            rels.add(a)
        elif kind == "col":
            cols.setdefault(a, {})[b] = c
        elif kind == "fn":
            fns.setdefault(a, set()).add((b, c))
        elif kind == "set":
            sets.add(a)
    return rels, cols, fns, sets


def main(argv):
    if len(argv) != 3 or not all(a.isdigit() for a in argv[1:]):
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    old, new = int(argv[1]), int(argv[2])
    if old >= new:
        print(f"old major {old} must be lower than new major {new}", file=sys.stderr)
        return 2
    images = packsql.read_images()
    for m in (old, new):
        if m not in images:
            print(f"no image for major {m} in {packsql.IMAGES}; have {sorted(images)}", file=sys.stderr)
            return 2
    look = lookups(packsql.read_queries())
    with packsql.Fleet([old, new], images) as fleet:
        fleet.start()
        (r_old, c_old, f_old, s_old), (r_new, c_new, f_new, s_new) = probe(fleet, old, look), probe(fleet, new, look)

    out = []
    for rel in sorted(r_old | r_new):
        if rel not in r_new:
            out.append(f"- relation `{rel}` removed in {new}")
        elif rel not in r_old:
            out.append(f"- relation `{rel}` added in {new}: " + ", ".join(f"`{c}`" for c in c_new.get(rel, {})))
        else:
            for col in c_new.get(rel, {}):
                if col not in c_old.get(rel, {}):
                    out.append(f"- `{rel}.{col}` ({c_new[rel][col]}) added in {new}")
                elif c_old[rel][col] != c_new[rel][col]:
                    out.append(f"- `{rel}.{col}` type {c_old[rel][col]} -> {c_new[rel][col]}")
            for col in c_old.get(rel, {}):
                if col not in c_new.get(rel, {}):
                    out.append(f"- `{rel}.{col}` ({c_old[rel][col]}) removed in {new}")
    for fn in sorted(set(f_old) | set(f_new)):
        a, b = f_old.get(fn, set()), f_new.get(fn, set())
        for args, ret in sorted(b - a):
            out.append(f"- function `{fn}({args})` returns {ret}: added or changed in {new}")
        for args, ret in sorted(a - b):
            out.append(f"- function `{fn}({args})` returns {ret}: removed or changed in {new}")

    for name in sorted(s_old | s_new):
        if name not in s_new:
            out.append(f"- setting `{name}` removed in {new}")
        elif name not in s_old:
            out.append(f"- setting `{name}` added in {new}")

    print(f"# Catalog objects the PostgreSQL pack reads: {old} -> {new}\n")
    print(
        f"Images: `{images[old]}`, `{images[new]}`. Looked up {len(look[0])} identifiers, {len(look[1])} function names and {len(look[2])} setting-shaped literals from queries.yaml.\n"
    )
    print("\n".join(out) if out else "No difference in the relations, columns and functions the pack reads.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
