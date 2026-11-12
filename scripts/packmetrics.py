# SPDX-License-Identifier: Apache-2.0
"""Read the metric definitions of a Collector sql_query list.

The query files write one metric per line as a YAML flow mapping,
`- {metric_name: ..., value_column: ..., ...}`. This reads exactly that shape
with the standard library, so the checks need no PyYAML. A metric written any
other way is not seen; check-pack-names.py fails if a file has `metric_name`
more often than it has parsed metrics.
"""

import re

LINE = re.compile(r"^\s*-\s*\{(metric_name:.*)\}\s*$")


def _split(body):
    """Split a flow mapping body on top-level commas."""
    parts, depth, quote, cur = [], 0, None, []
    for ch in body:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            cur.append(ch)
        elif ch in "[{":
            depth += 1
            cur.append(ch)
        elif ch in "]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def _scalar(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def parse_metrics(path):
    """Return (metrics, mentions): parsed metric dicts and the count of lines naming metric_name."""
    metrics, mentions = [], 0
    for line in open(path, encoding="utf-8"):
        if "metric_name:" in line and not line.lstrip().startswith("#"):
            mentions += 1
        m = LINE.match(line)
        if not m:
            continue
        d = {}
        for part in _split(m.group(1)):
            key, _, value = part.partition(":")
            value = value.strip()
            if value.startswith("["):
                d[key.strip()] = [_scalar(v) for v in value.strip("[]").split(",") if v.strip()]
            else:
                d[key.strip()] = _scalar(value)
        metrics.append(d)
    return metrics, mentions
