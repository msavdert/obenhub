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
owns the groups named in the target list, which must come first after
`groups:`; what follows must be hand-written parameter groups
(`*-parameters`, with their comment), kept as written. Anything else in the
file is refused in both modes, and so is an obenhub.expected_* record outside
the generated groups. The target list is also tied to the lab's own sources
(nodes.sh, Collector configs, kind.yaml) where they name the same things.

Exit status: 0 current, 1 an inventory differs (--check), 2 a file or target
list that cannot be used. JSON because nothing else in the repository reads
YAML with a library (scripts/packalerts.py reads a fixed shape by hand) and
the standard library reads JSON.
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
# Values go into PromQL strings unescaped.
SAFE = re.compile(r"[A-Za-z0-9_.-]+")
GROUP = re.compile(r"[a-z0-9-]+")
PARAMETERS = re.compile(r"[a-z0-9-]+-parameters")
EXPECTED = re.compile(r"record:\s*[\"']?obenhub\.expected_")


class Fail(Exception):
    pass


def read(path):
    """Text of a repository file, line endings untouched; CR is refused."""
    try:
        with open(path, newline="") as f:
            text = f.read()
    except OSError as e:
        raise Fail(f"cannot read {os.path.relpath(path, ROOT)}: {e.strerror}") from e
    if "\r" in text:
        raise Fail(f"{os.path.relpath(path, ROOT)} contains a carriage return; it must use LF line endings")
    return text


def safe(value, what):
    if not isinstance(value, str) or not SAFE.fullmatch(value):
        raise Fail(f"{what}: {value!r} is not a string of [A-Za-z0-9_.-]")
    return value


def only_keys(obj, allowed, what):
    if not isinstance(obj, dict):
        raise Fail(f"{what} must be an object")
    unknown = set(obj) - set(allowed)
    if unknown:
        raise Fail(f"{what}: unknown keys {sorted(unknown)}")


def validate(data, where):
    """Strict shape of a target list; returns it unchanged."""
    only_keys(data, {"namespace", "groups"}, where)
    safe(data.get("namespace"), f"{where} namespace")
    if not isinstance(data.get("groups"), list) or not data["groups"]:
        raise Fail(f"{where}: groups must be a non-empty list")
    seen_groups = set()
    seen_ids = {k: set() for k in RECORDS}
    for group in data["groups"]:
        only_keys(group, {"name", "records"}, f"{where} group")
        name = group.get("name")
        if not isinstance(name, str) or not GROUP.fullmatch(name) or PARAMETERS.fullmatch(name):
            raise Fail(f"{where}: group name {name!r} must match [a-z0-9-]+ and not end in -parameters")
        if name in seen_groups:
            raise Fail(f"{where}: duplicate group {name}")
        seen_groups.add(name)
        if not isinstance(group.get("records"), list) or not group["records"]:
            raise Fail(f"{where}: group {name} needs records")
        for rec in group["records"]:
            only_keys(rec, {"blank_before", "comment", *RECORDS}, f"{where} group {name} record")
            kinds = [k for k in RECORDS if k in rec]
            if len(kinds) != 1:
                raise Fail(f"{where}: group {name}: a record needs exactly one of {sorted(RECORDS)}")
            kind = kinds[0]
            if not isinstance(rec.get("blank_before", False), bool):
                raise Fail(f"{where}: group {name}: blank_before must be true or false")
            for line in rec.get("comment", []):
                if not isinstance(line, str) or not line or "\n" in line or "\r" in line:
                    raise Fail(f"{where}: group {name}: a comment line must be a non-empty single line")
            if not isinstance(rec[kind], list) or not rec[kind]:
                raise Fail(f"{where}: group {name}: empty {kind} list")
            allowed = {key for _, key, _ in LABELS[kind]}
            for item in rec[kind]:
                only_keys(item, allowed, f"{where} {kind} entry")
                for _label, key, optional in LABELS[kind]:
                    if key in item:
                        safe(item[key], f"{where} {kind} {key}")
                    elif not optional:
                        raise Fail(f"{where}: {kind} entry without {key}: {item}")
                ident = (item.get("service"), item["id"], item.get("cluster"))
                if ident in seen_ids[kind]:
                    raise Fail(f"{where}: duplicate {kind} entry {item}")
                seen_ids[kind].add(ident)
    return data


def series(namespace, kind, item):
    pairs = [("service.namespace", namespace)]
    pairs += [(label, item[key]) for label, key, _ in LABELS[kind] if key in item]
    return "label_set(vector(1), " + ", ".join(f'"{k}", "{v}"' for k, v in pairs) + ")"


def record(namespace, rec):
    kind = next(k for k in RECORDS if k in rec)
    items = [series(namespace, kind, i) for i in rec[kind]]
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
    blocks = []
    for group in data["groups"]:
        out = [f"  - name: {group['name']}", "    interval: 15s", "    rules:"]
        for rec in group["records"]:
            out += record(data["namespace"], rec)
        blocks.append("\n".join(out) + "\n")
    return "\n".join(blocks)


def split_file(rel, text, generated):
    """(head, tail): the text up to and including `groups:`, and the hand-written groups after the generated ones."""
    lines = text.split("\n")
    if lines[-1] != "":
        raise Fail(f"{rel}: the file must end with a newline")
    lines.pop()
    if "groups:" not in lines:
        raise Fail(f"{rel}: no `groups:` line")
    first = lines.index("groups:") + 1
    units = []  # (name, line index of the unit's prelude, line index of `- name:`)
    prelude = None
    for i in range(first, len(lines)):
        line = lines[i]
        m = re.fullmatch(r"  - name: (\S+)", line)
        if m:
            units.append((m.group(1), i if prelude is None else prelude, i))
            prelude = None
        elif line == "" or line.startswith("  #"):
            prelude = i if prelude is None else prelude
        elif line.startswith("    ") and units:
            if prelude is not None and any(x.startswith("  #") for x in lines[prelude:i]):
                raise Fail(f"{rel}:{prelude + 1}: a comment between groups is followed by a rule, not a group")
            prelude = None  # blank lines inside the previous group's body
        else:
            raise Fail(f"{rel}:{i + 1}: unrecognised line {line!r} (expected a group `  - name: ...`)")
    if prelude is not None:
        raise Fail(f"{rel}:{prelude + 1}: a comment or blank line after the last group belongs to no group")
    own = [u for u in units if u[0] in generated]
    rest = [u for u in units if u[0] not in generated]
    for name, _, at in rest:
        if not PARAMETERS.fullmatch(name):
            raise Fail(
                f"{rel}:{at + 1}: group {name!r} is neither generated (lab target list) nor a *-parameters group"
            )
    if units[: len(own)] != own:
        raise Fail(f"{rel}: the generated groups {sorted(generated)} must come first after `groups:`")
    if own and own[0][1] != first:
        raise Fail(f"{rel}:{first + 1}: unexpected lines before the first generated group")
    for _, start, at in own:
        if any(x.startswith("  #") for x in lines[start:at]):
            raise Fail(
                f"{rel}:{start + 1}: a comment before a generated group would be lost; put it in the target list"
            )
    tail = rest[0][1] if rest else len(lines)
    head_text = "\n".join(lines[:first]) + "\n"
    tail_text = "".join(f"{x}\n" for x in lines[tail:])
    for n, x in enumerate(lines[tail:], tail + 1):
        if EXPECTED.search(x):
            raise Fail(f"{rel}:{n}: an obenhub.expected_* record outside the generated groups")
    for n, x in enumerate(lines[:first], 1):
        if EXPECTED.search(x):
            raise Fail(f"{rel}:{n}: an obenhub.expected_* record outside the generated groups")
    return head_text, tail_text


def has(texts, pattern):
    """True when a non-comment line of a source matches; a commented-out setting does not count."""
    live = ("\n".join(ln for ln in t.splitlines() if not ln.lstrip().startswith("#")) + "\n" for t in texts)
    return any(re.search(pattern, t, re.M) for t in live)


def tie(lab, data):
    """Check the target list against the lab's own sources; raises Fail on a mismatch."""
    cols, rows = {}, []
    for g in data["groups"]:
        for r in g["records"]:
            for k in RECORDS:
                if k in r:
                    cols.setdefault(k, []).extend(r[k])
    collectors = {c["id"] for c in cols.get("collectors", [])}
    rows = cols.get("targets", []) + cols.get("scrapes", [])
    for c in cols.get("collectors", []):
        if "upstream" in c and c["upstream"] not in collectors:
            raise Fail(f"{lab}: upstream {c['upstream']} is not in the collectors list")
    for t in rows:
        if t["collector"] not in collectors:
            raise Fail(f"{lab}: {t['service']} {t['id']}: collector {t['collector']} is not in the collectors list")

    def src(*paths):
        return [read(os.path.join(ROOT, p)) for p in paths]

    def literal_ids(texts, ids, what):
        for v in sorted(ids):
            if not has(texts, rf"service\.instance\.id,\s*value:\s*\"?{re.escape(v)}\"?\s*[,}}\n]"):
                raise Fail(f"{lab}: {what} {v} is not a service.instance.id value in the Collector config")

    def literal_clusters(texts):
        for v in sorted({t["cluster"] for t in rows}):
            if not has(texts, rf"obenhub\.cluster\.name,\s*value:\s*{re.escape(v)}\s*[,}}\n]"):
                raise Fail(f"{lab}: cluster {v} is not an obenhub.cluster.name value in the Collector config")

    gateway = src("lab/mon/otelcol-gateway-mtls.yaml")
    if lab in ("slice1", "stage3"):
        texts = src(f"lab/{lab}/otelcol/config.yaml")
        literal_ids(texts, {t["id"] for t in rows}, "instance")
        literal_clusters(texts)
        literal_ids(texts, collectors, "Collector")
    elif lab == "oracle":
        texts = src("lab/oracle/files/otelcol-db.yaml", "lab/oracle/files/otelcol-obs.yaml")
        literal_ids(texts, {t["id"] for t in rows}, "database")
        literal_clusters(texts)
        pair = read(os.path.join(ROOT, "lab/oracle/pair.sh"))
        hosts = re.findall(r"^(?:PRIMARY|STANDBY|OBSERVER)_HOST=(\S+)$", pair, re.M)
        if not has(src("lab/oracle/files/otelcol-host.yaml"), r"value:\s*\"otelcol-\$\{env:OBENHUB_NODE\}\""):
            raise Fail("oracle: otelcol-host.yaml no longer names its Collector otelcol-${env:OBENHUB_NODE}")
        expect = {"otelcol-gateway"} | {f"otelcol-{h}" for h in hosts}
        if len(hosts) != 3 or collectors != expect or not has(gateway, r"value: otelcol-gateway\b"):
            raise Fail(
                f"oracle: collectors {sorted(collectors)} differ from the gateway and pair.sh hosts {sorted(expect)}"
            )
    elif lab == "pgha":
        m = re.search(r'^NODES="([^"]*)"', read(os.path.join(ROOT, "lab/pgha/nodes.sh")), re.M)
        if not m:
            raise Fail("pgha: no NODES= in lab/pgha/nodes.sh")
        nodes = {w.split("=")[0] for w in m.group(1).split()}
        texts = src("lab/pgha/files/otelcol.yaml.tmpl")
        if not has(texts, r"value: otelcol-@NODE@") or not has(texts, r"service\.instance\.id,\s*value:\s*@NODE@"):
            raise Fail("pgha: otelcol.yaml.tmpl no longer names Collector and instance ids from @NODE@")
        literal_clusters(texts)
        expect = {"otelcol-gateway"} | {f"otelcol-{n}" for n in nodes}
        if collectors != expect or not has(gateway, r"value: otelcol-gateway\b"):
            raise Fail(f"pgha: collectors {sorted(collectors)} differ from the gateway and NODES {sorted(expect)}")
        for t in rows:
            if t["id"] not in nodes or t["collector"] != f"otelcol-{t['id']}":
                raise Fail(
                    f"pgha: {t['service']} {t['id']} (collector {t['collector']}) does not match NODES {sorted(nodes)}"
                )
        for svc in {t["service"] for t in rows}:
            if {t["id"] for t in rows if t["service"] == svc} != nodes:
                raise Fail(f"pgha: {svc} ids differ from NODES {sorted(nodes)}")
    elif lab == "k8s":
        kind, versions = src("lab/k8s/kind.yaml", "lab/k8s/versions.sh")
        cluster = re.search(r"^KIND_CLUSTER=(\S+)$", versions, re.M)
        workers = len(re.findall(r"^\s*-\s*role:\s*worker\s*$", kind, re.M))
        if not cluster or not workers:
            raise Fail("k8s: no KIND_CLUSTER in versions.sh or no worker in kind.yaml")
        # kind names its nodes <cluster>-worker, <cluster>-worker2, ... (assumption: kind's naming, not read from its source).
        names = [cluster.group(1) + "-worker" + ("" if i == 1 else str(i)) for i in range(1, workers + 1)]
        expect = {"otelcol-gateway", "otelcol-cluster"} | {f"otelcol-agent-{n}" for n in names}
        if collectors != expect:
            raise Fail(
                f"k8s: collectors {sorted(collectors)} differ from the gateway, cluster and kind.yaml workers {sorted(expect)}"
            )
        if not has(
            src("lab/k8s/otel/agent-values.yaml"), r"service\.instance\.id: otelcol-agent-\$\{env:OTEL_K8S_NODE_NAME\}"
        ):
            raise Fail("k8s: agent-values.yaml no longer names agents otelcol-agent-<node>")
        if not has(src("lab/k8s/otel/cluster-values.yaml"), r"service\.instance\.id: otelcol-cluster\s*$"):
            raise Fail("k8s: cluster-values.yaml no longer names the cluster Collector otelcol-cluster")
        if not has(src("lab/k8s/mon/otelcol-gateway.yaml"), r"value: otelcol-gateway\b"):
            raise Fail("k8s: the gateway config no longer names itself otelcol-gateway")


def render(lab, targets):
    where = f"lab/{lab}/targets.json" if targets is None else targets
    path = os.path.join(ROOT, "lab", lab, "targets.json") if targets is None else targets
    try:
        data = validate(json.loads(read(path)), where)
    except json.JSONDecodeError as e:
        raise Fail(f"{where}: not valid JSON: {e}") from e
    tie(lab, data)
    rel = INVENTORIES[lab]
    head, tail = split_file(rel, read(os.path.join(ROOT, rel)), {g["name"] for g in data["groups"]})
    return head + render_groups(data) + tail


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    override = None
    if "--targets" in args:
        i = args.index("--targets")
        if i + 1 >= len(args):
            raise Fail("--targets needs a path")
        override = args[i + 1]
        del args[i : i + 2]
    labs = args or list(INVENTORIES)
    if [a for a in labs if a not in INVENTORIES] or (override and len(labs) != 1):
        raise Fail(f"usage: gen-inventory.py [--check] [--targets PATH] [{'|'.join(INVENTORIES)}]...")
    failed = False
    for lab in labs:
        out = render(lab, override)
        path = os.path.join(ROOT, INVENTORIES[lab])
        current = read(path)
        if check:
            if out != current:
                failed = True
                print(
                    f"gen-inventory: {INVENTORIES[lab]} differs from its target list; run scripts/gen-inventory.py {lab}",
                    file=sys.stderr,
                )
        elif out != current:
            with open(path, "w", newline="") as f:
                f.write(out)
            print(f"gen-inventory: wrote {INVENTORIES[lab]}")
    if check and not failed:
        print("gen-inventory: inventories are current")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        print(f"gen-inventory: {e}", file=sys.stderr)
        sys.exit(2)
