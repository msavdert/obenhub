# SPDX-License-Identifier: Apache-2.0
"""Read the alert rules of the packs and the alerts the lab scenarios expect.

The rule files write one alert as `- alert: Name`, an `expr` (one line or a
block scalar), `for`, `labels.severity` and `annotations` with one-line
values. This reads exactly that shape with the standard library, so the checks
need no PyYAML. Comments inside a rule are ignored. A rule file that has more
`- alert:` lines than the parser found alerts is an error.

Two tiers of one alert (one name, two severities) are two entries here.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALERT = re.compile(r"^(\s*)- alert:\s*(\S+)\s*$")
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
    alerts, mentions = [], 0
    i = 0
    while i < len(lines):
        m = ALERT.match(lines[i])
        if not m:
            i += 1
            continue
        mentions += 1
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
                    if value.strip() in ("|", ">", "|-", ">-"):
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
                alert["annotations"][k.group(2)] = scalar(k.group(3))
            j += 1
        alerts.append(alert)
        i = j
    if mentions != len(alerts):
        sys.exit(f"{path}: {mentions} alert lines, {len(alerts)} parsed")
    return alerts


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
                if any(ALERT.match(line) for line in path.read_text(encoding="utf-8").split("\n")):
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
