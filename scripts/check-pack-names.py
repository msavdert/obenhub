#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the names project metrics use against ADR 0006. No network.

For lab/packs/postgresql/queries.yaml and the pgbouncer queries of
lab/slice1/otelcol/config.yaml:
    - every metric has a unit;
    - no metric name ends in a unit word (_seconds, _bytes, _ms, _us, _total);
    - names are lowercase, dot-separated.
For the PostgreSQL pack only:
    - attribute columns are dotted (postgresql.*, never a bare column name);
    - no metric name equals a postgresqlreceiver metric name (list in
    lab/packs/postgresql/upstream-receiver-metrics.txt).
"""

import re
import sys
from pathlib import Path

from packmetrics import parse_metrics

ROOT = Path(__file__).resolve().parent.parent
PACK = ROOT / "lab/packs/postgresql/queries.yaml"
UPSTREAM = ROOT / "lab/packs/postgresql/upstream-receiver-metrics.txt"
PGBOUNCER = ROOT / "lab/slice1/otelcol/config.yaml"
UNIT_WORDS = ("_seconds", "_bytes", "_ms", "_us", "_total")
NAME = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def main():
    upstream = {
        line.strip()
        for line in UPSTREAM.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }
    if not upstream:
        sys.exit(f"{UPSTREAM.relative_to(ROOT)}: no metric names")
    errors = []
    for path, is_pack, prefix in ((PACK, True, "postgresql."), (PGBOUNCER, False, "pgbouncer.")):
        metrics, mentions = parse_metrics(path)
        rel = path.relative_to(ROOT)
        if mentions != len(metrics):
            errors.append(
                f"{rel}: {mentions} metric_name lines, {len(metrics)} parsed (one metric per line, flow mapping)"
            )
        # No filtering by prefix: the slice1 config defines metric names only
        # for PgBouncer (the PostgreSQL queries come from the pack), so every
        # metric_name there must start with the prefix. A mistyped name fails.
        if not metrics:
            errors.append(f"{rel}: no {prefix}* metrics found")
        seen = set()
        for m in metrics:
            name = m["metric_name"]
            if name in seen:
                errors.append(f"{rel}: {name}: defined twice")
            seen.add(name)
            if not name.startswith(prefix):
                errors.append(f"{rel}: {name}: does not start with {prefix}")
            if not NAME.match(name):
                errors.append(f"{rel}: {name}: not lowercase dot-separated")
            if name.endswith(UNIT_WORDS):
                errors.append(f"{rel}: {name}: ends in a unit word")
            if not m.get("unit"):
                errors.append(f"{rel}: {name}: no unit")
            if is_pack:
                if name in upstream:
                    errors.append(f"{rel}: {name}: equals a postgresqlreceiver metric")
                for col in m.get("attribute_columns", []):
                    if not NAME.match(col):
                        errors.append(f"{rel}: {name}: attribute {col!r} is not dotted")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
