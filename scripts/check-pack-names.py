#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the names project metrics use against ADR 0006. No network.

For the pack query files (lab/packs/postgresql, lab/packs/oracledb-dg) and
the pgbouncer queries of lab/slice1/otelcol/config.yaml:
    - every metric has a unit;
    - no metric name ends in a unit word (_seconds, _bytes, _ms, _us, _total);
    - names are lowercase, dot-separated.
For the packs only:
    - attribute columns are dotted (never a bare column name);
    - no metric name equals a metric name of the engine's receiver (list in
    upstream-receiver-metrics.txt next to the pack's queries.yaml).
"""

import re
import sys
from pathlib import Path

from packmetrics import parse_metrics

ROOT = Path(__file__).resolve().parent.parent
# (pack directory, metric prefix, receiver whose names a pack name must not take)
PACKS = (
    (ROOT / "lab/packs/postgresql", "postgresql.", "postgresqlreceiver"),
    (ROOT / "lab/packs/oracledb-dg", "oracledb.", "oracledbreceiver"),
)
PGBOUNCER = ROOT / "lab/slice1/otelcol/config.yaml"
UNIT_WORDS = ("_seconds", "_bytes", "_ms", "_us", "_total")
NAME = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def read_upstream(path):
    names = {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }
    if not names:
        sys.exit(f"{path.relative_to(ROOT)}: no metric names")
    return names


def main():
    targets = [
        (d / "queries.yaml", read_upstream(d / "upstream-receiver-metrics.txt"), prefix, receiver)
        for d, prefix, receiver in PACKS
    ]
    targets.append((PGBOUNCER, None, "pgbouncer.", None))
    errors = []
    for path, upstream, prefix, receiver in targets:
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
            if upstream is not None:
                if name in upstream:
                    errors.append(f"{rel}: {name}: equals a {receiver} metric")
                for col in m.get("attribute_columns", []):
                    if not NAME.match(col):
                        errors.append(f"{rel}: {name}: attribute {col!r} is not dotted")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
