#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tie the lab threshold overrides to their tests (C4). No network, no docker.

check-lab-parameters.py           fail on a mismatch
check-lab-parameters.py --blocks LAB   print the assertions a lab's limits.yml must hold

Two things must agree with the `*-parameters` groups of the lab inventories
(the recording rules that set a lab's thresholds):

- The fixtures packs/<pack>/tests/lab-values/<pack>.yaml, which the older pack
tests load to run at lab values, hold exactly the records of the group
`<component>-parameters` of every lab inventory that mounts the pack.
- The lab's limits.yml test asserts every record of every `*-parameters` group
of its inventory, one metricsql_expr_test entry per record, in the form
--blocks prints (exact series name, labels and value).

The record rules are read as the inventories write them: `- record: NAME`
followed by `expr: vector(N)` or `expr: label_set(vector(N), "k", "v", ...)`.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# lab: (rule files with *-parameters groups, compose file that mounts the packs, limits test)
LABS = {
    "slice1": (
        ("lab/slice1/vmalert/rules/postgresql.yml", "lab/slice1/vmalert/rules/pgbackrest.yml"),
        "lab/slice1/compose.yaml",
        "lab/slice1/vmalert/tests/limits.yml",
    ),
    "stage3": (("lab/stage3/vmalert/inventory.yml",), "lab/stage3/compose.yaml", "lab/stage3/vmalert/tests/limits.yml"),
    "pgha": (
        ("lab/pgha/mon/vmalert/inventory.yml",),
        "lab/pgha/mon/compose.yaml",
        "lab/pgha/mon/vmalert/tests/limits.yml",
    ),
    "k8s": (("lab/k8s/mon/vmalert/inventory.yml",), "lab/k8s/mon/compose.yaml", "lab/k8s/mon/vmalert/tests/limits.yml"),
    "oracle": (
        ("lab/oracle/mon/vmalert/inventory.yml",),
        "lab/oracle/mon/compose.yaml",
        "lab/oracle/mon/vmalert/tests/limits.yml",
    ),
}
# fixture pack -> group of the inventory that records its lab values
FIXTURES = {
    "postgresql": "postgresql-parameters",
    "pgbouncer": "pgbouncer-parameters",
    "oracledb-dg": "oracledb-dg-parameters",
}
GROUP = re.compile(r"^  - name: (\S+)\s*$")
RECORD = re.compile(r"^      - record: (\S+)\s*$")
EXPR = re.compile(
    r'^        expr: (?:vector\(([0-9.]+)\)|label_set\(vector\(([0-9.]+)\)((?:, "[^"]*", "[^"]*")+)\))\s*$'
)
PAIR = re.compile(r'"([^"]*)", "([^"]*)"')


def records(path):
    """{group: [(name, value, ((label, value), ...)), ...]} of the recording rules of a rule file."""
    out = {}
    group = None
    name = None
    for n, line in enumerate(Path(path).read_text(encoding="utf-8").split("\n"), 1):
        m = GROUP.match(line)
        if m:
            group, name = m.group(1), None
            out.setdefault(group, [])
            continue
        m = RECORD.match(line)
        if m:
            name = m.group(1)
            continue
        if name and line.startswith("        expr:") and group and group.endswith(("-parameters", "-lab-values")):
            e = EXPR.match(line)
            if not e:
                sys.exit(f'{path}:{n}: record {name}: expr must be vector(N) or label_set(vector(N), "k", "v", ...)')
            value = e.group(1) or e.group(2)
            labels = tuple(PAIR.findall(e.group(3) or ""))
            out[group].append((name, value, labels))
            name = None
    return out


def block(name, value, labels):
    sel = name + ("{" + ", ".join(f'{k}="{v}"' for k, v in labels) + "}" if labels else "")
    return (
        f"      - expr: {sel}\n"
        "        eval_time: 1m\n"
        "        exp_samples:\n"
        f"          - labels: '{sel}'\n"
        f"            value: {value}\n"
    )


def lab_records(lab, only_group=None):
    """Records of the *-parameters groups (or one group) over all parameter files of a lab."""
    out = []
    for f in LABS[lab][0]:
        for g, rs in sorted(records(ROOT / f).items()):
            if (g == only_group) if only_group else g.endswith("-parameters"):
                out += rs
    return out


def lab_blocks(lab):
    return [block(*r) for r in lab_records(lab)]


ENTRY = re.compile(
    r"^      - expr: (?P<expr>.+)\n        eval_time: \S+\n        exp_samples:\n"
    r"          - labels: '(?P<labels>.*)'\n            value: (?P<value>\S+)$",
    re.M,
)


def assertions(path):
    """{(expr, labels, value)} of the metricsql_expr_test entries of a test file; comment lines are dropped first."""
    lines = Path(path).read_text(encoding="utf-8").split("\n")
    text = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
    return {(m["expr"], m["labels"], float(m["value"])) for m in ENTRY.finditer(text)}


def unlisted_groups():
    """*-parameters groups in vmalert rule or inventory files under lab/ that LABS does not list."""
    listed = {f for files, _, _ in LABS.values() for f in files}
    found = []
    for path in sorted((ROOT / "lab").rglob("*.yml")):
        rel = str(path.relative_to(ROOT))
        if "vmalert" not in rel or "/tests/" in rel or rel in listed:
            continue
        for line in path.read_text(encoding="utf-8").split("\n"):
            m = GROUP.match(line)
            if m and m.group(1).endswith("-parameters"):
                found.append(f"{rel}: group {m.group(1)} is not listed in LABS (scripts/check-lab-parameters.py)")
    return found


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--blocks":
        print("".join(lab_blocks(sys.argv[2])), end="")
        return 0
    errors = unlisted_groups()
    for pack, group in FIXTURES.items():
        fixture = ROOT / "packs" / pack / "tests" / "lab-values" / f"{pack}.yaml"
        have = sorted(r for rs in records(fixture).values() for r in rs)
        loaders = 0
        for lab, (files, compose, _) in LABS.items():
            if f"packs/{pack}/rules.yml" not in (ROOT / compose).read_text(encoding="utf-8"):
                continue
            loaders += 1
            if sorted(lab_records(lab, group)) != have:
                errors.append(f"{fixture.relative_to(ROOT)} differs from group {group} of {', '.join(files)}")
        if not loaders:
            errors.append(f"{fixture.relative_to(ROOT)}: no lab mounts packs/{pack}/rules.yml")
    for lab, (_, _, limits) in LABS.items():
        have = assertions(ROOT / limits)
        for name, value, labels in lab_records(lab):
            sel = name + ("{" + ", ".join(f'{k}="{v}"' for k, v in labels) + "}" if labels else "")
            if (sel, sel, float(value)) not in have:
                errors.append(f"{limits}: no metricsql_expr_test entry for the lab record {sel} = {value}")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
