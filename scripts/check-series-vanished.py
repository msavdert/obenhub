#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail when the PostgresSeriesVanished metric list drifts from the PostgreSQL pack.

The rule (packs/postgresql/rules.yml) names the metrics it watches in two
`__name__` regexes. Both must expand to the same set, and that set must equal
the metrics of packs/postgresql/queries.yaml, less EXCLUDED, plus metrics
of postgresqlreceiver (listed in upstream-receiver-metrics.txt). The metrics of
queries-slow.yaml (5 m tier) must NOT be in it: its 2 m presence window is
shorter than their interval, so they would read as vanished between samples;
the slow tier has its own heartbeat rule. No network.
"""

import re
import sys
from pathlib import Path

from packmetrics import parse_metrics

ROOT = Path(__file__).resolve().parent.parent
RULES = ROOT / "packs/postgresql/rules.yml"
QUERIES = ROOT / "packs/postgresql/queries.yaml"
SLOW = ROOT / "packs/postgresql/queries-slow.yaml"
UPSTREAM = ROOT / "packs/postgresql/upstream-receiver-metrics.txt"

# Pack metrics the rule deliberately does not watch, with the reason.
EXCLUDED = {
    # The rule's own gate: it fires only while the heartbeat lives, and a
    # vanished heartbeat is PostgresTargetAbsent or CollectorAbsent.
    "postgresql.collection.heartbeat",
    # One series for each combination of state and wait event present at the
    # scrape; a combination that is gone is no series, and an instance with no
    # client session has none at all, which is no fault.
    "postgresql.client_session.count",
}


def expand(rx):
    """Expand the regex subset the rule uses: literals, `[.]`, groups and `|`."""
    pos = 0

    def alt():
        nonlocal pos
        out = seq()
        while pos < len(rx) and rx[pos] == "|":
            pos += 1
            out |= seq()
        return out

    def seq():
        nonlocal pos
        out = {""}
        while pos < len(rx) and rx[pos] not in "|)":
            if rx.startswith("[.]", pos):
                part, pos = {"."}, pos + 3
            elif rx[pos] == "(":
                pos += 1
                part = alt()
                if pos >= len(rx) or rx[pos] != ")":
                    sys.exit(f"unbalanced group in {rx!r}")
                pos += 1
            elif rx[pos] in "[]*+?.\\^$":
                sys.exit(f"unsupported regex syntax {rx[pos]!r} in {rx!r}")
            else:
                part, pos = {rx[pos]}, pos + 1
            out = {a + b for a in out for b in part}
        return out

    names = alt()
    if pos != len(rx):
        sys.exit(f"unbalanced group in {rx!r}")
    return names


def main():
    text = RULES.read_text(encoding="utf-8")
    block = re.search(r"- alert: PostgresSeriesVanished\n(.*?)(?=\n      - alert: |\Z)", text, re.S)
    if not block:
        sys.exit(f"{RULES}: PostgresSeriesVanished not found")
    lists = re.findall(r'__name__=~"([^"]+)"', block.group(1))
    if len(lists) != 2:
        sys.exit(f"{RULES}: expected 2 __name__ regexes in PostgresSeriesVanished, found {len(lists)}")
    first, second = (expand(r) for r in lists)
    errors = []
    if first != second:
        errors.append(f"the two regexes differ: {sorted(first ^ second)}")
    metrics, mentions = parse_metrics(QUERIES)
    if mentions != len(metrics):
        sys.exit(f"{QUERIES}: {mentions} metric_name lines, {len(metrics)} parsed")
    pack = {m["metric_name"] for m in metrics}
    upstream = {
        line.strip()
        for line in UPSTREAM.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }
    missing = pack - EXCLUDED - first
    if missing:
        errors.append(
            f"pack metrics missing from PostgresSeriesVanished (add them or list them in EXCLUDED): {sorted(missing)}"
        )
    extra = first - pack - upstream
    if extra:
        errors.append(
            f"PostgresSeriesVanished names metrics that are neither pack nor receiver metrics: {sorted(extra)}"
        )
    slow, slow_mentions = parse_metrics(SLOW)
    if slow_mentions != len(slow):
        sys.exit(f"{SLOW}: {slow_mentions} metric_name lines, {len(slow)} parsed")
    in_rule = {m["metric_name"] for m in slow} & first
    if in_rule:
        errors.append(
            f"slow-tier metrics in PostgresSeriesVanished (its windows are shorter than 5 m): {sorted(in_rule)}"
        )
    stale = EXCLUDED - pack
    if stale:
        errors.append(f"EXCLUDED names metrics the pack does not define: {sorted(stale)}")
    both = EXCLUDED & first
    if both:
        errors.append(f"EXCLUDED metrics are in the rule: {sorted(both)}")
    for e in errors:
        print(f"check-series-vanished: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
