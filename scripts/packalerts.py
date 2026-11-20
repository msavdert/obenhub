# SPDX-License-Identifier: Apache-2.0
"""Read the alert rules of the packs and the alerts the lab scenarios expect.

The rule files write one alert as `- alert: Name`, an `expr` (one line or a
block scalar), `for`, `labels.severity` and `annotations` with one-line
values. This reads exactly that shape with the standard library (PyYAML is not
a dependency of the repo scripts, so a regex reader it is). Comments inside a
rule are ignored. Anything else fails closed instead of being skipped: a
separate, looser guard finds every YAML key `alert:` in the file (any
indentation, with or without the list dash, also in flow style), and each one
must be exactly `- alert: Name` (a bare name, no quotes, no trailing comment,
the first key of its list item); annotation values must be one line (a block
scalar or a continuation line is an error).

Two tiers of one alert (one name, two severities) are two entries here.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALERT = re.compile(r"^(\s*)- alert:\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")
# the independent guard: any `alert:` key, whatever the shape around it
LOOSE_ALERT = re.compile(r"^\s*(-\s+)?alert\s*:|[{,]\s*alert\s*:")
BLOCK_SCALAR = re.compile(r"^[|>][+-]?\d*[+-]?$")
SHAPE = "write the alert as `- alert: Name` (bare name, no quotes, no trailing comment, first key of the list item)"


def loose_alert_lines(lines):
    """Line numbers (1-based) of every `alert:` key in the text, comments excluded."""
    return [n for n, line in enumerate(lines, 1) if not line.lstrip().startswith("#") and LOOSE_ALERT.search(line)]


KEY = re.compile(r"^(\s*)([A-Za-z_][\w.]*):\s?(.*)$")


def scalar(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == text[-1] == '"':
        return text[1:-1]
    return text


def parse_rules(path):
    """Return the alerts of one rules file: dicts with name, severity, for, expr, annotations, line."""
    lines = Path(path).read_text(encoding="utf-8").split("\n")
    alerts = []
    for n in loose_alert_lines(lines):
        if not ALERT.match(lines[n - 1]):
            sys.exit(f"{path}:{n}: unsupported alert shape `{lines[n - 1].strip()}`: {SHAPE}")
    i = 0
    while i < len(lines):
        m = ALERT.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        alert = {"name": m.group(2), "line": i + 1, "for": "", "severity": "", "expr": "", "annotations": {}}
        j = i + 1
        section = None
        while j < len(lines):
            raw = lines[j]
            if raw.strip() == "" or raw.lstrip().startswith("#"):
                j += 1
                continue
            lead = len(raw) - len(raw.lstrip())
            # the next rule or group ends this one
            if lead <= indent:
                break
            k = KEY.match(raw)
            if k and lead == indent + 2:
                key, value = k.group(2), k.group(3)
                section = key
                if key == "expr":
                    if BLOCK_SCALAR.match(value.strip()):
                        body = []
                        j += 1
                        while j < len(lines) and (
                            lines[j].strip() == "" or len(lines[j]) - len(lines[j].lstrip()) > indent + 2
                        ):
                            body.append(lines[j])
                            j += 1
                        dedent = min((len(b) - len(b.lstrip()) for b in body if b.strip()), default=0)
                        alert["expr"] = "\n".join(b[dedent:] for b in body).strip("\n")
                        section = None
                        continue
                    alert["expr"] = scalar(value)
                elif key == "for":
                    alert["for"] = scalar(value)
            elif k and lead == indent + 4 and section == "labels" and k.group(2) == "severity":
                alert["severity"] = scalar(k.group(3))
            elif k and lead == indent + 4 and section == "annotations":
                if BLOCK_SCALAR.match(k.group(3).strip()):
                    sys.exit(
                        f"{path}:{j + 1}: annotation {k.group(2)} is a block scalar ({k.group(3).strip()}); write a one-line value"
                    )
                alert["annotations"][k.group(2)] = scalar(k.group(3))
            elif section == "annotations" and lead > indent + 4:
                sys.exit(f"{path}:{j + 1}: annotation value continues on a second line; write a one-line value")
            j += 1
        alerts.append(alert)
        i = j
    found = len(loose_alert_lines(lines))
    if found != len(alerts):
        sys.exit(f"{path}: {found} `alert:` keys, {len(alerts)} parsed; {SHAPE}")
    return alerts


LIMIT_NAME = re.compile(r"obenhub\.[a-z0-9_.]*\.limit(?![\w.])")
# The one form of a threshold (C4): <expr> <op> on() group_left() (<series>{<selector>} or on() vector(<default>))
LIMIT_FORM = re.compile(
    r"(?P<op>>=|<=|>|<) on\(\) group_left\(\) \("
    r"(?P<series>obenhub\.[a-z0-9_.]*\.limit)(?P<sel>\{[^{}]*\})? or on\(\) vector\((?P<default>[0-9]+(?:\.[0-9]+)?)\)\)"
)
UNIT_LINE = re.compile(r"^# unit (obenhub\.[a-z0-9_.]*\.limit) (\S+)$")
OPS = {">": "above", ">=": "at or above", "<": "below", "<=": "at or below"}


def alert_limits(path, alert):
    """The limit series an alert's expression reads, as dicts (series, selector, default, op), in expression order.

    Every `obenhub.*.limit` name in an expression must sit in the one form
    `<op> on() group_left() (<series>{<selector>} or on() vector(<default>))`
    (whitespace is free, tokens are not); anything else exits with the alert named.
    """
    expr = " ".join(alert["expr"].split())
    names = LIMIT_NAME.findall(expr)
    found = list(LIMIT_FORM.finditer(expr))
    if len(found) != len(names):
        sys.exit(
            f"{path}:{alert['line']}: {alert['name']}: {len(names)} obenhub.*.limit names but {len(found)} in the form "
            "`<op> on() group_left() (obenhub.<component>.<thing>.limit{...} or on() vector(<default>))`"
        )
    return [
        {"series": m["series"], "selector": (m["sel"] or "")[1:-1], "default": m["default"], "op": m["op"]}
        for m in found
    ]


def units(path):
    """{series: unit} from the `# unit obenhub.<...>.limit <unit>` lines of a rules file."""
    found = {}
    for line in Path(path).read_text(encoding="utf-8").split("\n"):
        m = UNIT_LINE.match(line)
        if m:
            if m.group(1) in found:
                sys.exit(f"{path}: unit of {m.group(1)} given twice")
            found[m.group(1)] = m.group(2)
    return found


def packs_with_rules():
    return sorted(p.parent.name for p in (ROOT / "packs").glob("*/rules.yml"))


def pack_alerts():
    """{pack: [alert, ...]} for every pack with a rules.yml, in file order."""
    return {p: parse_rules(ROOT / "packs" / p / "rules.yml") for p in packs_with_rules()}


def lab_alert_files():
    """Rule files outside the packs that define an alert (none today; the lint fails on one)."""
    found = []
    for base in ("lab", "mon"):
        for path in sorted((ROOT / base).rglob("*")) if (ROOT / base).exists() else []:
            if path.suffix in (".yml", ".yaml") and "tests" not in path.parts and path.is_file():
                if loose_alert_lines(path.read_text(encoding="utf-8").split("\n")):
                    found.append(path)
    return found


EXPECT = re.compile(r"\bEXPECT\+?=\((.*?)\)", re.S)
ENTRY = re.compile(r'"([A-Z][A-Za-z0-9]+):')


def scenario_alerts():
    """{alert name: [scenario script, ...]} from the EXPECT arrays of every lab scenario.

    ALLOW entries (alerts a scenario tolerates) are not read: only what a
    scenario waits for counts as fired by it.
    """
    fired = {}
    scripts = [s for s in sorted((ROOT / "lab").glob("**/scenarios/**/*.sh")) if not s.name.startswith("test-")]
    for path in dict.fromkeys(scripts):
        text = path.read_text(encoding="utf-8")
        for block in EXPECT.findall(text):
            for name in ENTRY.findall(block):
                rel = str(path.relative_to(ROOT))
                if rel not in fired.setdefault(name, []):
                    fired[name].append(rel)
    return fired


def site_url():
    for line in (ROOT / "zensical.toml").read_text(encoding="utf-8").split("\n"):
        m = re.match(r'site_url\s*=\s*"([^"]+)"', line)
        if m:
            return m.group(1).rstrip("/") + "/"
    sys.exit("zensical.toml: no site_url")


def anchor(name):
    """The id the toc extension gives the heading `## <name>`: an alert name is letters and digits only, so the lowercased name."""
    return name.lower()


def runbook_url(pack, name, fired):
    """The runbook_url an alert must carry: the runbook page when a scenario fires it, else its reference entry."""
    page = f"runbooks/{pack}/" if name in fired else f"reference/{pack}-pack-alerts/"
    return f"{site_url()}{page}#{anchor(name)}"


def main():
    """Print the alerts a scenario fires, per pack."""
    fired = scenario_alerts()
    known = {}
    for pack, alerts in pack_alerts().items():
        for a in alerts:
            known[a["name"]] = pack
    by_pack = {}
    for name in sorted(fired):
        by_pack.setdefault(known.get(name, "(no rule)"), []).append(name)
    for pack in sorted(by_pack):
        print(f"{pack}: {' '.join(by_pack[pack])}")


if __name__ == "__main__":
    main()
