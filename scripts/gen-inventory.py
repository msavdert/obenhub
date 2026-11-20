#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Render each lab's vmalert inventory records from its target list.

gen-inventory.py                    write the inventory groups of every lab
gen-inventory.py --check            fail when an inventory differs from what its target list renders
gen-inventory.py [--check] LAB...   only these labs
gen-inventory.py --check --targets PATH LAB   read the target list from PATH (one lab)

Each lab keeps its target list in lab/<lab>/targets.json: the Collectors it
expects (collectors), the databases they collect (targets) and the services
scraped from them (scrapes), as the record rules obenhub.expected_collector,
obenhub.expected_target and obenhub.expected_scrape carry them. The generator
owns the inventory groups of the lab's inventory file, from the line after
`groups:` to the lab parameter groups (`*-parameters`, hand-written, with their
comment) or the end of the file; the file header and the parameter groups stay
as written. JSON because nothing else in the repository reads YAML with a
library (scripts/packalerts.py reads a fixed shape by hand) and the standard
library reads JSON.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INVENTORIES = {
    "slice1": "lab/slice1/vmalert/rules/postgresql.yml",
    "stage3": "lab/stage3/vmalert/inventory.yml",
    "pgha": "lab/pgha/mon/vmalert/inventory.yml",
    "k8s": "lab/k8s/mon/vmalert/inventory.yml",
    "oracle": "lab/oracle/mon/vmalert/inventory.yml",
}
RECORDS = {
    "collectors": "obenhub.expected_collector",
    "targets": "obenhub.expected_target",
    "scrapes": "obenhub.expected_scrape",
}
# Label order of a series, per list: (label, key in the target list, optional).
LABELS = {
    "collectors": [("service.instance.id", "id", False), ("obenhub.upstream", "upstream", True)],
    "targets": [
        ("service.name", "service", False),
        ("obenhub.cluster.name", "cluster", False),
        ("service.instance.id", "id", False),
        ("obenhub.collector", "collector", False),
    ],
}
LABELS["scrapes"] = LABELS["targets"]
# The parameter groups of a lab (hand-written) start at the blank line before
# their comment.
TAIL = re.compile(r"\n\n(?:  #[^\n]*\n)*  - name: [a-z0-9-]*-parameters\n")


def series(namespace, kind, item):
    pairs = [("service.namespace", namespace)]
    for label, key, optional in LABELS[kind]:
        if key in item:
            pairs.append((label, item[key]))
        elif not optional:
            sys.exit(f"gen-inventory: {kind} entry without {key}: {item}")
    unknown = set(item) - {key for _, key, _ in LABELS[kind]}
    if unknown:
        sys.exit(f"gen-inventory: {kind} entry with unknown keys {sorted(unknown)}: {item}")
    args = ", ".join(f'"{k}", "{v}"' for k, v in pairs)
    return f"label_set(vector(1), {args})"


def record(namespace, rec):
    kinds = [k for k in RECORDS if k in rec]
    if len(kinds) != 1:
        sys.exit(f"gen-inventory: a record needs exactly one of {sorted(RECORDS)}: {rec}")
    kind = kinds[0]
    items = [series(namespace, kind, i) for i in rec[kind]]
    if not items:
        sys.exit(f"gen-inventory: empty {kind} list")
    out = [""] if rec.get("blank_before") else []
    out += [f"      # {c}" for c in rec.get("comment", [])]
    out.append(f"      - record: {RECORDS[kind]}")
    if len(items) == 1:
        out.append(f"        expr: {items[0]}")
    else:
        out += ["        expr: |", "          union("]
        out += [f"            {s}," for s in items[:-1]] + [f"            {items[-1]}"]
        out.append("          )")
    return out


def render_groups(data):
    namespace = data["namespace"]
    blocks = []
    for group in data["groups"]:
        out = [f"  - name: {group['name']}", "    interval: 15s", "    rules:"]
        for rec in group["records"]:
            out += record(namespace, rec)
        blocks.append("\n".join(out) + "\n")
    return "\n".join(blocks)


def check_nodes(lab, data):
    """lab/<lab>/nodes.sh names the lab's hosts: the PostgreSQL targets must be exactly those."""
    path = os.path.join(ROOT, "lab", lab, "nodes.sh")
    if not os.path.exists(path):
        return
    m = re.search(r'^NODES="([^"]*)"', open(path).read(), re.M)
    if not m:
        sys.exit(f"gen-inventory: no NODES= in {path}")
    nodes = {w.split("=")[0] for w in m.group(1).split()}
    ids = {
        t["id"]
        for g in data["groups"]
        for r in g["records"]
        for t in r.get("targets", [])
        if t["service"] == "postgresql"
    }
    if ids != nodes:
        sys.exit(f"gen-inventory: {lab}: targets.json PostgreSQL ids {sorted(ids)} differ from NODES in nodes.sh {sorted(nodes)}")


def render(lab, targets):
    with open(targets) as f:
        data = json.load(f)
    check_nodes(lab, data)
    with open(os.path.join(ROOT, INVENTORIES[lab])) as f:
        text = f.read()
    head_end = text.index("\ngroups:\n") + len("\ngroups:\n")
    m = TAIL.search(text, head_end)
    tail_start = m.start() + 1 if m else len(text)
    return text[:head_end] + render_groups(data) + text[tail_start:]


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    override = None
    if "--targets" in args:
        i = args.index("--targets")
        override = args[i + 1]
        del args[i : i + 2]
    labs = args or list(INVENTORIES)
    bad = [a for a in labs if a not in INVENTORIES]
    if bad or (override and len(labs) != 1):
        sys.exit(f"usage: gen-inventory.py [--check] [--targets PATH] [{'|'.join(INVENTORIES)}]...")
    failed = False
    for lab in labs:
        path = os.path.join(ROOT, INVENTORIES[lab])
        out = render(lab, override or os.path.join(ROOT, "lab", lab, "targets.json"))
        with open(path) as f:
            current = f.read()
        if check:
            if out != current:
                failed = True
                print(f"gen-inventory: {INVENTORIES[lab]} differs from its target list (lab/{lab}/targets.json); run scripts/gen-inventory.py {lab}", file=sys.stderr)
        elif out != current:
            with open(path, "w") as f:
                f.write(out)
            print(f"gen-inventory: wrote {INVENTORIES[lab]}")
    if check and not failed:
        print("gen-inventory: inventories are current")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
