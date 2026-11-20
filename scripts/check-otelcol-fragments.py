#!/usr/bin/env python3
"""Pack Collector fragments (packs/<pack>/otelcol.yaml): consistency and drift.

ADR 0005 decision 3: a pack holds one complete Collector fragment; lab
Collector configurations stay hand-written, and this check fails when a lab's
block for a pack component differs from the fragment's component in anything
but what the fragment parametrises.

Checks (exit 1 on any finding):
1. every fragment is well formed: component names end in `obenhub` or
`obenhub-<pack>`, pipelines are named `<signal>/obenhub-<pack>*`, export to
otlp/obenhub, and each ${file:/etc/otelcol-contrib/packs/<pack>/<f>} names
a file that exists; the shared processors are identical in every fragment;
2. the ${env:...} variables of a fragment are exactly the ones its pack
README lists in the "Collector fragment" section;
3. drift: each component of each lab configuration that belongs to a pack is
compared with the fragment's component, after normalisation.

What may differ (the only allowances; each is a rule below, not a skip):
- Any value the fragment writes as ${env:...}: the lab may hold any value
there, and a key whose whole value is ${env:...} may be absent. A string
that contains ${env:...} among other text is matched as a pattern.
- Keys in IGNORE_KEYS (TLS settings, the storage extension name, the
observer a receiver_creator watches), the ssl* keys of sql_query
additional_params, and the directory part of ${file:.../packs/<pack>/...}.
- The value (or from_attribute) of the identity keys in IDENTITY, in resource
attribute lists, in service.telemetry.resource and in `set(attributes[
"<identity key>"], ...)` statements.
- Per-lab entries in ALLOW, each with a reason; an entry that matches nothing
is an error.
Components with no pack are listed in UNMAPPED_OK with a reason; any other
component that cannot be mapped is an error. Pipelines (which components are
wired together, in which order) are not compared.

Usage: check-otelcol-fragments.py [--lab LABEL=PATH]... [--only]
check-otelcol-fragments.py --env      # NAME=value dummies for validation
check-otelcol-fragments.py --fragments   # fragment paths
--lab adds a lab configuration (the label picks the ALLOW entries and, for
*-values.yaml, the `config:` section); --only drops the default list.
Needs yq (mise.toml).
"""

import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Lab Collector configurations compared with the fragments. A tracked Collector
# configuration under lab/ that is in neither this list nor EXCLUDED is an error.
LABS = [
    "lab/slice1/otelcol/config.yaml",
    "lab/stage3/otelcol/config.yaml",
    "lab/overhead/otelcol.yaml",
    "lab/k8s/otel/agent-values.yaml",
    "lab/k8s/otel/cluster-values.yaml",
    "lab/oracle/files/otelcol-host.yaml",
    "lab/oracle/files/otelcol-db.yaml",
    "lab/oracle/files/otelcol-obs.yaml",
]
# lab/pgha/files/otelcol.yaml.tmpl is rendered by scripts/lint-otelcol.sh and
# passed with --lab; lab/stage3/otelcol/config.yaml.tmpl is the source of the
# generated config.yaml above.
EXCLUDED = {
    "lab/obi/otelcol.yaml": "OBI measurement: no pack component",
    "lab/mon/otelcol-gateway-mtls.yaml": "the gateway: receives OTLP, no pack component",
    "lab/k8s/mon/otelcol-gateway.yaml": "the gateway: receives OTLP, no pack component",
}

IGNORE_KEYS = {
    "tls",
    "tls_config",
    "certificate",
    "client_certificate",
    "client_key",
    "storage",
    "watch_observers",
}
SSL_PARAMS = {"sslmode", "sslrootcert", "sslcert", "sslkey"}
IDENTITY = [
    "service.namespace",
    "service.instance.id",
    "obenhub.cluster.name",
    "server.address",
    "server.port",
    "oracledb.database.unique_name",
]
STMT = re.compile(
    r'^set\(((?:resource\.|log\.)?attributes\["(?:' + "|".join(re.escape(k) for k in IDENTITY) + r')"\]), .*\)$'
)
ENV = re.compile(r"\$\{env:([A-Za-z0-9_]+)\}")
FILE = re.compile(r"\$\{file:[^}]*?/packs/")
WHOLE_ENV = re.compile(r"^\$\{env:[A-Za-z0-9_]+\}$")

# (lab file glob, kind, component glob, mode, reason). Modes: "extra-attr:<key>"
# (the lab's resource processor has one more attribute), "subset" (only the
# keys the lab sets are compared), "only:<k1,k2>" (only these keys are compared).
ALLOW = [
    (
        "lab/pgha/files/otelcol.yaml.tmpl (rendered)",
        "processors",
        "resource/host",
        "extra-attr:obenhub.cluster.name",
        "the lab labels host series with the cluster of the node; ADR 0006 decision 7 says host series do not carry it",
    ),
    (
        "lab/oracle/files/otelcol-host.yaml",
        "processors",
        "resource/host",
        "extra-attr:obenhub.cluster.name",
        "the lab labels host series with the cluster of the VM; ADR 0006 decision 7 says host series do not carry it",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "kubeletstats",
        "subset",
        "the chart's kubeletstats preset supplies the other keys; only insecure_skip_verify is set here",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "file_log",
        "only:operators",
        "the chart's logsCollection preset collects every pod log; the pack reads the postgres container of the instance pods, so only the operators are compared",
    ),
    (
        "lab/k8s/otel/*-values.yaml",
        "telemetry",
        "service.telemetry",
        "subset",
        "the chart sets service.telemetry.resource from its telemetry.resourceAttributes values",
    ),
    (
        "lab/overhead/otelcol.yaml",
        "telemetry",
        "service.telemetry",
        "subset",
        "one-off overhead measurement: the Collector's own metrics are not shipped, only the level is set",
    ),
]
# (lab file glob, kind, component glob, reason): no pack component to compare.
UNMAPPED_OK = [
    (
        "lab/oracle/files/otelcol-obs.yaml",
        "receivers",
        "journald/observer",
        "journal of the Data Guard observers (owner-provided units); no pack fragment reads it",
    ),
]

# fragment key -> (pack, fragment component) for sql_query by queries file
SQL_QUERY = {
    ("postgresql", "queries.yaml"): ("postgresql", "sql_query/obenhub-postgresql"),
    ("pgbouncer", "queries.yaml"): ("pgbouncer", "sql_query/obenhub-pgbouncer"),
    ("oracledb-dg", "queries.yaml"): ("oracledb-dg", "sql_query/obenhub-oracledb-dg"),
    ("oracledb-dg", "queries-primary.yaml"): ("oracledb-dg", "sql_query/obenhub-oracledb-dg-account"),
    ("oracledb-backup", "queries.yaml"): ("oracledb-backup", "sql_query/obenhub-oracledb-backup"),
}
RESOURCE = {  # service.name -> pack
    "postgresql": "postgresql",
    "pgbouncer": "pgbouncer",
    "pgbackrest": "pgbackrest",
    "patroni": "patroni",
    "etcd": "etcd",
    "host": "host",
}

findings = []


def fail(msg):
    findings.append(msg)


def yq(path):
    out = subprocess.run(["yq", "-o=json", ".", str(path)], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def load_fragments():
    frags = {}
    for p in sorted((ROOT / "packs").glob("*/otelcol.yaml")):
        frags[p.parent.name] = yq(p)
    return frags


def env_names(obj):
    return set(ENV.findall(json.dumps(obj)))


# ---------------------------------------------------------------- normalise


def norm(x):
    if isinstance(x, dict):
        d = {k: norm(v) for k, v in x.items() if k not in IGNORE_KEYS}
        if "additional_params" in d and isinstance(d["additional_params"], dict):
            d["additional_params"] = {k: v for k, v in d["additional_params"].items() if k not in SSL_PARAMS}
            if not d["additional_params"]:
                del d["additional_params"]
        ident = x.get("key", x.get("name"))
        if ident in IDENTITY:
            for k in ("value", "from_attribute", "from_context"):
                d.pop(k, None)
        return d
    if isinstance(x, list):
        return [norm(i) for i in x]
    if isinstance(x, str):
        x = FILE.sub("${file:packs/", x)
        return STMT.sub(r"set(\1, <identity>)", x)
    return x


def short(v):
    s = json.dumps(v)
    return s if len(s) < 70 else s[:67] + "..."


def diff(f, lab, path, out, subset=False):
    """Differences of lab from fragment f; both normalised."""
    if isinstance(f, str) and WHOLE_ENV.match(f):
        return
    if isinstance(f, dict):
        if not isinstance(lab, dict):
            out.append(f"{path}: the lab has {short(lab)}, the fragment a mapping")
            return
        for k, v in f.items():
            if k not in lab:
                if not subset and not (isinstance(v, str) and WHOLE_ENV.match(v)):
                    out.append(f"{path}.{k}: missing in the lab")
            else:
                diff(v, lab[k], f"{path}.{k}", out, subset)
        for k in lab:
            if k not in f:
                out.append(f"{path}.{k}: not in the fragment (lab: {short(lab[k])})")
    elif isinstance(f, list):
        if not isinstance(lab, list) or len(f) != len(lab):
            out.append(f"{path}: lab {short(lab)} vs fragment {short(f)}")
            return
        for i, (a, b) in enumerate(zip(f, lab, strict=True)):
            diff(a, b, f"{path}[{i}]", out, subset)
    elif isinstance(f, str) and "${env:" in f:
        parts = ENV.split(f)  # text, name, text, name, ...
        rx = ".*".join(re.escape(p) for p in parts[::2])
        if not isinstance(lab, str) or not re.fullmatch(rx, lab, re.S):
            out.append(f"{path}: lab {short(lab)} vs fragment pattern {short(f)}")
    elif f != lab:
        out.append(f"{path}: lab {short(lab)} vs fragment {short(f)}")


# ---------------------------------------------------------------- classify


def attr_value(cfg, key):
    for a in cfg.get("attributes", []):
        if isinstance(a, dict) and a.get("key") == key:
            return a.get("value")
    return None


def classify(kind, cid, cfg):
    """List of (pack, fragment component) targets, or None when unmapped."""
    t = cid.split("/")[0]
    cfg = cfg if isinstance(cfg, dict) else {}
    if kind == "receivers":
        if t == "postgresql":
            return [("postgresql", "postgresql/obenhub-postgresql")]
        if t == "sql_query":
            m = re.search(r"packs/([a-z-]+)/(queries[a-z-]*\.yaml)", str(cfg.get("queries", "")))
            tgt = SQL_QUERY.get((m.group(1), m.group(2))) if m else None
            return [tgt] if tgt else None
        if t == "prometheus":
            try:
                job = cfg["config"]["scrape_configs"][0]["job_name"]
            except (KeyError, IndexError, TypeError):
                return None
            if job in ("pgbackrest", "patroni", "etcd"):
                return [(job, f"prometheus/obenhub-{job}")]
            return None
        if t == "file_log":
            inc = json.dumps(cfg.get("include", ""))
            if "postgresql-" in inc:
                return [("postgresql", "file_log/obenhub-postgresql")]
            if "ALERT_LOG" in inc:
                return [("oracledb-dg", "file_log/obenhub-oracledb-dg-alert")]
            if "cnpg-json" in json.dumps(cfg.get("operators", "")):
                return [("cnpg", "file_log/obenhub-cnpg")]
            return None
        if t == "host_metrics":
            return [("host", "host_metrics/obenhub-host")]
        if t == "journald":
            if "dg-observer" in json.dumps(cfg):
                return None
            if "units" in cfg:
                return [("host", "journald/obenhub-host-units")]
            if cfg.get("dmesg"):
                return [("host", "journald/obenhub-host-kernel")]
            return None
        if t == "oracledb":
            return [("oracledb-dg", "oracledb/obenhub-oracledb-dg")]
        if t == "tcp_check":
            return [("oracledb-dg", "tcp_check/obenhub-oracledb-dg")]
        if t == "kubeletstats":
            return [("k8s", "kubeletstats/obenhub-k8s")]
        if t == "receiver_creator":
            inner = cfg.get("receivers", {})
            if "postgresql" in inner:
                return [("cnpg", "receiver_creator/obenhub-cnpg-postgresql")]
            if "prometheus" in inner:
                return [("cnpg", "receiver_creator/obenhub-cnpg")]
        return None
    if kind == "processors":
        if t == "memory_limiter":
            return [("*", "memory_limiter/obenhub")]
        if t == "batch":
            return [("*", "batch/obenhub")]
        if t == "resource_detection":
            return [
                ("host", "resource_detection/obenhub-host"),
                ("oracledb-dg", "resource_detection/obenhub-oracledb-dg"),
            ]
        if t == "attributes" and "pgbouncer" in cid:
            return [("pgbouncer", "attributes/obenhub-pgbouncer")]
        if t == "transform":
            s = json.dumps(cfg)
            if "pgbouncer" in cid or "datapoint.value_double" in s:
                return [("pgbouncer", "transform/obenhub-pgbouncer-seconds")]
            if "ora_number" in s:
                return [("oracledb-dg", "transform/obenhub-oracledb-dg-alert")]
            if "record" in s:
                return [("cnpg", "transform/obenhub-cnpg")]
            return None
        if t == "resource":
            svc = attr_value(cfg, "service.name")
            has_from = any(isinstance(a, dict) and "from_attribute" in a for a in cfg.get("attributes", []))
            if svc == "postgresql" and has_from:
                return [("cnpg", "resource/obenhub-cnpg-postgresql")]
            if svc == "cnpg-instance-manager":
                return [("cnpg", "resource/obenhub-cnpg")]
            if svc == "oracledb":
                if attr_value(cfg, "oracledb.database.unique_name") is not None:
                    return [("oracledb-dg", "resource/obenhub-oracledb-dg-alert")]
                return [
                    ("oracledb-dg", "resource/obenhub-oracledb-dg"),
                    ("oracledb-backup", "resource/obenhub-oracledb-backup"),
                ]
            if svc in RESOURCE:
                p = RESOURCE[svc]
                return [(p, f"resource/obenhub-{p}")]
        return None
    return None


def lookup(frags, kind, pack, fid):
    if pack == "*":
        pack = "postgresql"
    return frags[pack].get(kind, {}).get(fid)


def allow_for(label, kind, cid, used):
    for i, (fg, k, cg, mode, _reason) in enumerate(ALLOW):
        if k == kind and fnmatch.fnmatchcase(label, fg) and fnmatch.fnmatchcase(cid, cg):
            used.add(i)
            return mode
    return None


def unmapped_ok(label, kind, cid, used):
    for i, (fg, k, cg, _reason) in enumerate(UNMAPPED_OK):
        if k == kind and fnmatch.fnmatchcase(label, fg) and fnmatch.fnmatchcase(cid, cg):
            used.add(i)
            return True
    return False


compared = [0]


def compare(frags, label, kind, cid, cfg, f_cfg, tag, used, mode):
    """Compare lab component cfg with fragment component f_cfg; report."""
    compared[0] += 1
    subset = False
    a, b = norm(f_cfg), norm(cfg)
    if mode == "subset":
        subset = True
    elif mode and mode.startswith("only:"):
        keys = mode[5:].split(",")
        a = {k: v for k, v in a.items() if k in keys}
        b = {k: v for k, v in b.items() if k in keys}
    elif mode and mode.startswith("extra-attr:"):
        key = mode[11:]
        b = dict(b)
        b["attributes"] = [x for x in b["attributes"] if x.get("key") != key]
    out = []
    diff(a, b, "", out, subset)
    for o in out:
        fail(f"{label}: {kind.rstrip('s')} {cid} (pack {tag}){o}")


def check_lab(frags, label, path, used_allow, used_unmapped):
    doc = yq(path)
    if label.endswith("-values.yaml"):
        doc = doc.get("config", {})
    for kind in ("receivers", "processors"):
        for cid, cfg in (doc.get(kind) or {}).items():
            if cfg is None and kind == "receivers":
                continue  # `jaeger: null` removes a chart default
            targets = classify(kind, cid, cfg)
            if targets is None:
                if not unmapped_ok(label, kind, cid, used_unmapped):
                    fail(
                        f"{label}: {kind[:-1]} {cid} maps to no pack component (add a rule to classify() or an UNMAPPED_OK entry with a reason)"
                    )
                continue
            mode = allow_for(label, kind, cid, used_allow)
            for pack, fid in targets:
                f_cfg = lookup(frags, kind, pack, fid)
                if f_cfg is None:
                    fail(f"{label}: {kind[:-1]} {cid}: fragment component {fid} of pack {pack} does not exist")
                    continue
                compare(frags, label, kind, cid, cfg, f_cfg, f"{pack}/{fid}", used_allow, mode)
            # receiver_creator: the inner receivers are the PostgreSQL pack's
            if kind == "receivers" and cid.startswith("receiver_creator"):
                for ik, ic in (cfg.get("receivers") or {}).items():
                    inner = (ic or {}).get("config", {})
                    tg = classify("receivers", ik, inner)
                    if tg and tg[0][0] != "cnpg":
                        pack, fid = tg[0]
                        compare(
                            frags,
                            label,
                            kind,
                            f"{cid} > {ik}",
                            inner,
                            lookup(frags, kind, pack, fid),
                            f"{pack}/{fid}",
                            used_allow,
                            None,
                        )
    tele = (doc.get("service") or {}).get("telemetry")
    if tele is not None:
        mode = allow_for(label, "telemetry", "service.telemetry", used_allow)
        f_tele = frags["collector"]["service"]["telemetry"]
        compare(frags, label, "telemetry", "service.telemetry", tele, f_tele, "collector", used_allow, mode)


# ---------------------------------------------------------------- fragments


def check_fragments(frags):
    shared = {}
    for pack, fr in frags.items():
        where = f"packs/{pack}/otelcol.yaml"
        for kind in ("receivers", "processors"):
            for cid in fr.get(kind, {}):
                if not re.search(r"/obenhub(-|$)", cid):
                    fail(f"{where}: {kind[:-1]} {cid}: the name must end in /obenhub or /obenhub-<pack>")
        for pname, p in (fr.get("service", {}).get("pipelines") or {}).items():
            if not re.fullmatch(r"(metrics|logs)/obenhub-[a-z0-9-]+", pname):
                fail(f"{where}: pipeline {pname}: the name must be <signal>/obenhub-<pack>[-suffix]")
            if p.get("exporters") != ["otlp/obenhub"]:
                fail(f"{where}: pipeline {pname}: exporters must be [otlp/obenhub]")
        if "exporters" in fr or "extensions" in fr or "connectors" in fr:
            fail(f"{where}: a fragment holds no exporters, extensions or connectors (the base does)")
        if "extensions" in fr.get("service", {}):
            fail(f"{where}: service.extensions would replace the base's list")
        for pack_, fname in re.findall(r"\$\{file:/etc/otelcol-contrib/packs/([^/]+)/([^}]+)\}", json.dumps(fr)):
            if not (ROOT / "packs" / pack_ / fname).is_file():
                fail(f"{where}: packs/{pack_}/{fname} does not exist")
        for cid in ("memory_limiter/obenhub", "batch/obenhub"):
            if cid in fr.get("processors", {}):
                shared.setdefault(cid, []).append((pack, fr["processors"][cid]))
        # README lists exactly the variables
        readme = ROOT / "packs" / pack / "README.md"
        names = env_names(fr)
        if not readme.is_file():
            fail(f"packs/{pack}/README.md is missing (it documents the fragment's variables)")
            continue
        text = readme.read_text()
        m = re.search(r"^## Collector fragment\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if not m:
            fail(f'packs/{pack}/README.md: no "## Collector fragment" section')
            continue
        doc_names = set(re.findall(r"^\| `(OBENHUB_[A-Z0-9_]+)`", m.group(1), re.M))
        for n in sorted(names - doc_names):
            fail(f"packs/{pack}/README.md: variable {n} of the fragment is not documented")
        for n in sorted(doc_names - names):
            fail(f"packs/{pack}/README.md: documents {n}, which the fragment does not use")
    for cid, lst in shared.items():
        first = json.dumps(lst[0][1], sort_keys=True)
        for pack, cfg in lst[1:]:
            if json.dumps(cfg, sort_keys=True) != first:
                fail(f"packs/{pack}/otelcol.yaml: {cid} differs from packs/{lst[0][0]}/otelcol.yaml")


def dummy(name):
    if name.endswith("_PORT"):
        return "5432"
    if name == "OBENHUB_K8S_KUBELET_INSECURE":
        return "true"  # false makes the receiver read the service account CA at start
    if name.endswith("INSECURE") or name.endswith("SKIP_VERIFY"):
        return "false"
    return {
        "OBENHUB_PG_DATABASES": "[postgres]",
        "OBENHUB_HOST_JOURNAL_UNITS": "[otelcol-contrib]",
        "OBENHUB_PATRONI_SCHEME": "https",
        "OBENHUB_GATEWAY_ENDPOINT": "localhost:4317",
        "OBENHUB_COLLECTOR_METRICS_ENDPOINT": "http://localhost:4318/v1/metrics",
        "OBENHUB_ETCD_METRICS_ENDPOINT": "127.0.0.1:2381",
        "OBENHUB_STORAGE_DIR": "/tmp/obenhub-storage",
    }.get(name, "disable" if name.endswith("SSLMODE") else "dummy")


def main():
    args = sys.argv[1:]
    if "--fragments" in args:
        for p in sorted((ROOT / "packs").glob("*/otelcol.yaml")):
            print(p.relative_to(ROOT))
        return 0
    frags = load_fragments()
    if "--env" in args:
        names = env_names(frags) | env_names(yq(ROOT / "packs/otelcol-base.yaml"))
        for n in sorted(names):
            print(f"{n}={dummy(n)}")
        return 0
    labs = [] if "--only" in args else [(p, ROOT / p) for p in LABS]
    for i, a in enumerate(args):
        if a == "--lab":
            label, _, path = args[i + 1].partition("=")
            labs.append((label, Path(path)))
    if "--only" not in args:
        tracked = subprocess.run(
            ["git", "ls-files", "lab/*otelcol*.yaml", "lab/*/otelcol/*.yaml"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        for f in tracked:
            if "/results/" in f:
                continue  # evidence files of a run
            if f not in LABS and f not in EXCLUDED and "\nservice:" in "\n" + (ROOT / f).read_text():
                fail(
                    f"{f}: a Collector configuration that is neither in LABS nor in EXCLUDED of scripts/check-otelcol-fragments.py"
                )
    check_fragments(frags)
    used_allow, used_unmapped = set(), set()
    for label, path in labs:
        check_lab(frags, label, path, used_allow, used_unmapped)
    if "--only" not in args:
        for i, e in enumerate(ALLOW):
            if i not in used_allow:
                fail(f"ALLOW entry matched nothing, remove it: {e[0]} {e[1]} {e[2]} {e[3]}")
        for i, e in enumerate(UNMAPPED_OK):
            if i not in used_unmapped:
                fail(f"UNMAPPED_OK entry matched nothing, remove it: {e[0]} {e[1]} {e[2]}")
    for f in findings:
        print(f"drift: {f}", file=sys.stderr)
    if not findings:
        print(
            f"ok   {len(frags)} fragments, {len(labs)} lab configurations, {compared[0]} components compared: no drift"
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
