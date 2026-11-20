#!/usr/bin/env python3
"""Pack Collector fragments (packs/<pack>/otelcol.yaml): consistency and drift.

ADR 0005 decision 3: a pack holds one complete Collector fragment; lab
Collector configurations stay hand-written, and this check fails when a lab's
block for a pack component differs from the fragment's component in anything
but what the rules below allow.

Checks (exit 1 on any finding):
1. every fragment is well formed: component names end in `obenhub` or
`obenhub-<pack>`, pipelines are named `<signal>/obenhub-<pack>*` and export to
otlp_http/obenhub, each ${file:/etc/otelcol-contrib/packs/<pack>/<f>} names a
file that exists, the shared processors are identical in every fragment;
2. the variables of a fragment (${env:...}, plus K8S_NODE_NAME for the k8s base)
are exactly the ones its pack README lists in the "Collector fragment" table,
and the variables of each base file are exactly the ones its header lists;
3. drift: each component of each lab configuration that belongs to a pack is
compared with the fragment's component, after normalisation; so is each lab
pipeline that holds pack receivers (the mapped receivers and the ordered,
mapped processors must equal the fragment pipeline's).

Limits: pipelines are compared per component type, not per lab instance (in
slice1, metrics/primary wired to resource/standby passes); an ALLOW entry
counts as used when its glob matches a component, even when the difference
it excuses is gone; pipelines fed by chart presets (k8s) are not compared.

What may differ between a lab block and the fragment (nothing else):
- Keys in PARAM_KEYS (endpoint, host, port, targets, username, service,
scheme, datasource): the lab may hold any value where the fragment holds
${env:...} (text around the variable is matched), and `scheme` may be absent.
A credential (`password`, the password part of `datasource`) that the fragment
takes from ${env:...} must come from an ${env:...} in the lab too.
- Keys in IGNORE_KEYS (TLS settings, the storage extension name, the observer
a receiver_creator watches), the ssl* keys of sql_query additional_params, and
the directory part of ${file:.../packs/<pack>/...}.
- The value (or from_attribute) of the identity keys in IDENTITY, in resource
attribute lists, in service.telemetry.resource and in `set(attributes[
"<identity key>"], ...)` statements.
- Entries of ALLOW, each with a reason (a different value where the fragment
holds ${env:...}, a subset, an extra attribute, a pipeline difference); an
entry that matches nothing is an error.
Components with no pack are listed in UNMAPPED_OK with a reason; any other
component that cannot be mapped is an error. A pipeline whose receivers are
all supplied by a chart preset (receivers: [] in a Helm values file) cannot be
compared and is skipped.

Usage: check-otelcol-fragments.py [--lab LABEL=PATH]... [--only]
check-otelcol-fragments.py --env         # NAME=value dummies for validation
check-otelcol-fragments.py --fragments   # "<fragment> <base> <vm|k8s>" lines
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

BASE = "packs/otelcol-base.yaml"
BASE_K8S = "packs/otelcol-base-k8s.yaml"
K8S_PACKS = {"cnpg", "k8s"}  # fragments that run in Kubernetes: BASE_K8S, no startup test

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
# keys where a lab may hold another value than the fragment's ${env:...}
PARAM_KEYS = {"endpoint", "host", "port", "targets", "username", "service", "scheme", "datasource", "password"}
OPTIONAL_KEYS = {"scheme"}  # may be absent in the lab
CREDENTIAL_KEYS = {"password"}
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
DSN_PASSWORD_ENV = re.compile(r"://[^:/@]*:\$\{env:[A-Za-z0-9_]+\}@")

# (lab file glob, kind, component glob, mode, reason). kind: receivers,
# processors, telemetry (service.telemetry), pipelines. Modes:
#   extra-attr:<key>  the lab's resource processor has one more attribute
#   subset            only the keys the lab sets are compared
#   only:<k1,k2>      only these keys are compared
#   param:<k1,k2>     these keys may hold another value than the fragment's ${env:...}
#   ignore:<k1,k2>    these keys (at any depth) are not compared
#   receivers-subset  (pipelines) the lab pipeline has fewer receivers
#   drop-processors:<t1,t2>  (pipelines) lab processors of these types are not compared
ALLOW = [
    (
        "lab/pgha/files/otelcol.yaml.tmpl (rendered)",
        "processors",
        "resource/host",
        "extra-attr:obenhub.cluster.name",
        "ADR 0006 decision 7 exempts host series from the cluster name; the lab labels a host with the cluster it serves",
    ),
    (
        "lab/oracle/files/otelcol-host.yaml",
        "processors",
        "resource/host",
        "extra-attr:obenhub.cluster.name",
        "ADR 0006 decision 7 exempts host series from the cluster name; the lab labels a VM with the cluster it serves",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "kubeletstats",
        "subset",
        "the chart's kubeletMetrics preset supplies the other keys; only insecure_skip_verify is set here",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "kubeletstats",
        "param:insecure_skip_verify",
        "kubelet certificate verification: the kind lab skips it, the fragment leaves it to the installation",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "file_log",
        "only:operators",
        "the chart's logsCollection preset collects every pod log; the pack reads the postgres container of the instance pods, so only the operators are compared",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "file_log",
        "param:if",
        "the namespace of the Cluster is a lab value",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "receiver_creator/postgresql*",
        "param:databases,rule",
        "the databases to read and the CloudNativePG Cluster name are lab values",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "receivers",
        "receiver_creator/cnpg",
        "param:rule",
        "the CloudNativePG Cluster name is a lab value",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "processors",
        "transform/cnpg",
        "ignore:conditions",
        "the lab selects the postgres container of its one namespace; the fragment also pins the pod name to <cluster>-<n>, which the lab has not needed with a single Cluster",
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
    (
        "*",
        "receivers",
        "postgresql*",
        "param:databases",
        "the application databases to read differ per lab",
    ),
    (
        "*",
        "receivers",
        "file_log*",
        "param:include",
        "log file locations differ per installation",
    ),
    (
        "*",
        "receivers",
        "journald/*",
        "param:units",
        "the systemd units to follow differ per machine",
    ),
    (
        "lab/oracle/files/otelcol-obs.yaml",
        "pipelines",
        "metrics/standby",
        "receivers-subset",
        "the oracledb receiver and the account query read the primary only; the standby has neither",
    ),
    (
        "lab/k8s/otel/agent-values.yaml",
        "pipelines",
        "metrics/*",
        "drop-processors:k8s_attributes",
        "enrichment from the chart's preset (the k8s pack's own k8s_attributes); the cnpg fragment does not carry it",
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

SQL_QUERY = {
    ("postgresql", "queries.yaml"): ("postgresql", "sql_query/obenhub-postgresql"),
    ("pgbouncer", "queries.yaml"): ("pgbouncer", "sql_query/obenhub-pgbouncer"),
    ("oracledb-dg", "queries.yaml"): ("oracledb-dg", "sql_query/obenhub-oracledb-dg"),
    ("oracledb-dg", "queries-primary.yaml"): (
        "oracledb-dg",
        "sql_query/obenhub-oracledb-dg-account",
    ),
    ("oracledb-backup", "queries.yaml"): (
        "oracledb-backup",
        "sql_query/obenhub-oracledb-backup",
    ),
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
compared = [0]


def fail(msg):
    findings.append(msg)


def yq(path):
    out = subprocess.run(["yq", "-o=json", ".", str(path)], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def load_fragments():
    return {p.parent.name: yq(p) for p in sorted((ROOT / "packs").glob("*/otelcol.yaml"))}


def env_names(obj):
    return set(ENV.findall(json.dumps(obj)))


def base_of(pack):
    return BASE_K8S if pack in K8S_PACKS else BASE


# ---------------------------------------------------------------- normalise


def norm(x, ign=frozenset()):
    if isinstance(x, dict):
        skip = IGNORE_KEYS | ign
        d = {k: norm(v, ign) for k, v in x.items() if k not in skip}
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
        return [norm(i, ign) for i in x]
    if isinstance(x, str):
        x = FILE.sub("${file:packs/", x)
        return STMT.sub(r"set(\1, <identity>)", x)
    return x


def short(v):
    s = json.dumps(v)
    return s if len(s) < 70 else s[:67] + "..."


def has_env(v):
    return isinstance(v, str) and "${env:" in v


def diff(f, lab, path, out, subset, params, key=None, inparam=False):
    """Differences of lab from fragment f; both normalised."""
    inparam = inparam or key in params
    if inparam and isinstance(f, str) and has_env(f):
        if key in CREDENTIAL_KEYS and not (isinstance(lab, str) and has_env(lab)):
            out.append(f"{path}: a credential must come from ${{env:...}} in the lab too")
        if key == "datasource" and not (isinstance(lab, str) and DSN_PASSWORD_ENV.search(lab)):
            out.append(f"{path}: the password of the data source must come from ${{env:...}} in the lab too")
        if WHOLE_ENV.match(f):
            return
        rx = ".*".join(re.escape(p) for p in ENV.split(f)[::2])
        if not isinstance(lab, str) or not re.fullmatch(rx, lab, re.S):
            out.append(f"{path}: lab {short(lab)} vs fragment pattern {short(f)}")
        return
    if isinstance(f, dict):
        if not isinstance(lab, dict):
            out.append(f"{path}: the lab has {short(lab)}, the fragment a mapping")
            return
        for k, v in f.items():
            if k not in lab:
                if not subset and k not in OPTIONAL_KEYS:
                    out.append(f"{path}.{k}: missing in the lab")
            else:
                diff(v, lab[k], f"{path}.{k}", out, subset, params, k, inparam)
        for k in lab:
            if k not in f:
                out.append(f"{path}.{k}: not in the fragment (lab: {short(lab[k])})")
    elif isinstance(f, list):
        if not isinstance(lab, list) or len(f) != len(lab):
            out.append(f"{path}: lab {short(lab)} vs fragment {short(f)}")
            return
        for i, (a, b) in enumerate(zip(f, lab, strict=True)):
            diff(a, b, f"{path}[{i}]", out, subset, params, key, inparam)
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


def hint(kind, cid, cfg):
    cfg = cfg if isinstance(cfg, dict) else {}
    if kind == "receivers" and cid.startswith("journald") and "units" not in cfg and not cfg.get("dmesg"):
        return (
            f"journald receiver {cid} has neither a `units` key nor `dmesg: true`; "
            "the host pack maps a journald receiver by one of them"
        )
    return "add a rule to classify() or an UNMAPPED_OK entry with a reason"


def lookup(frags, kind, pack, fid):
    return frags["postgresql" if pack == "*" else pack].get(kind, {}).get(fid)


def modes_for(label, kind, cid, used):
    out = []
    for i, (fg, k, cg, mode, _reason) in enumerate(ALLOW):
        if k == kind and fnmatch.fnmatchcase(label, fg) and fnmatch.fnmatchcase(cid, cg):
            used.add(i)
            out.append(mode)
    return out


def unmapped_ok(label, kind, cid, used):
    for i, (fg, k, cg, _reason) in enumerate(UNMAPPED_OK):
        if k == kind and fnmatch.fnmatchcase(label, fg) and fnmatch.fnmatchcase(cid, cg):
            used.add(i)
            return True
    return False


def compare(label, kind, cid, cfg, f_cfg, tag, modes):
    """Compare lab component cfg with fragment component f_cfg; report."""
    compared[0] += 1
    subset = False
    params = set(PARAM_KEYS)
    ign = set()
    only = None
    extra = []
    for m in modes:
        if m == "subset":
            subset = True
        elif m.startswith("only:"):
            only = (only or set()) | set(m[5:].split(","))
        elif m.startswith("param:"):
            params |= set(m[6:].split(","))
        elif m.startswith("ignore:"):
            ign |= set(m[7:].split(","))
        elif m.startswith("extra-attr:"):
            extra.append(m[11:])
    a, b = norm(f_cfg, ign), norm(cfg, ign)
    if only is not None:
        a = {k: v for k, v in a.items() if k in only}
        b = {k: v for k, v in b.items() if k in only}
    for key in extra:
        b = dict(b)
        b["attributes"] = [x for x in b["attributes"] if x.get("key") != key]
    out = []
    diff(a, b, "", out, subset, params)
    for o in out:
        fail(f"{label}: {kind.rstrip('s')} {cid} (pack {tag}){o}")


def check_pipelines(frags, label, doc, used_allow):
    defined = doc.get("receivers") or {}
    procs = doc.get("processors") or {}
    for pname, pl in ((doc.get("service") or {}).get("pipelines") or {}).items():
        if not pl:
            continue  # `traces: null` removes a chart default
        sig = pname.split("/")[0]
        by_pack = {}
        for r in pl.get("receivers") or []:
            if r not in defined:
                continue  # supplied by a chart preset
            tg = classify("receivers", r, defined[r])
            if tg:
                by_pack.setdefault(tg[0][0], []).append(tg[0][1])
        modes = modes_for(label, "pipelines", pname, used_allow)
        drop = set()
        for m in modes:
            if m.startswith("drop-processors:"):
                drop |= set(m.split(":", 1)[1].split(","))
        for pack, rec in by_pack.items():
            fps = [
                (n, p)
                for n, p in (frags[pack].get("service", {}).get("pipelines") or {}).items()
                if n.split("/")[0] == sig and set(rec) & set(p.get("receivers", []))
            ]
            where = f"{label}: pipeline {pname} (pack {pack})"
            if not fps:
                fail(f"{where}: the fragment has no {sig} pipeline with {sorted(rec)}")
                continue
            fname, fp = fps[0]
            compared[0] += 1
            frec = set(fp["receivers"])
            ok = set(rec) <= frec if "receivers-subset" in modes else set(rec) == frec
            if not ok:
                fail(f"{where}: receivers {sorted(set(rec))} vs fragment {fname} {sorted(frec)}")
            mapped = []
            for pr in pl.get("processors") or []:
                if pr.split("/")[0] in drop:
                    continue
                tg = classify("processors", pr, procs.get(pr))  # may be defined in a merged file
                pick = [fid for p, fid in tg or [] if p in (pack, "*")]
                if not pick:
                    fail(f"{where}: processor {pr} is not a component of pack {pack}")
                    mapped.append(f"?{pr}")
                else:
                    mapped.append(pick[0])
            if mapped != fp.get("processors"):
                fail(f"{where}: processors {mapped} vs fragment {fname} {fp.get('processors')}")


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
                    fail(f"{label}: {kind[:-1]} {cid} maps to no pack component: {hint(kind, cid, cfg)}")
                continue
            modes = modes_for(label, kind, cid, used_allow)
            for pack, fid in targets:
                f_cfg = lookup(frags, kind, pack, fid)
                if f_cfg is None:
                    fail(f"{label}: {kind[:-1]} {cid}: fragment component {fid} of pack {pack} does not exist")
                    continue
                compare(label, kind, cid, cfg, f_cfg, f"{pack}/{fid}", modes)
            # receiver_creator: the inner receivers are the PostgreSQL pack's
            if kind == "receivers" and cid.startswith("receiver_creator"):
                for ik, ic in (cfg.get("receivers") or {}).items():
                    inner = (ic or {}).get("config", {})
                    tg = classify("receivers", ik, inner)
                    if tg and tg[0][0] != "cnpg":
                        pack, fid = tg[0]
                        name = f"{cid} > {ik}"
                        compare(
                            label,
                            kind,
                            name,
                            inner,
                            lookup(frags, kind, pack, fid),
                            f"{pack}/{fid}",
                            modes_for(label, kind, name, used_allow),
                        )
    tele = (doc.get("service") or {}).get("telemetry")
    if tele is not None:
        modes = modes_for(label, "telemetry", "service.telemetry", used_allow)
        compare(
            label,
            "telemetry",
            "service.telemetry",
            tele,
            frags["collector"]["service"]["telemetry"],
            "collector",
            modes,
        )
    check_pipelines(frags, label, doc, used_allow)


# ---------------------------------------------------------------- fragments


def base_vars_documented():
    for b in (BASE, BASE_K8S):
        text = (ROOT / b).read_text()
        documented = set(re.findall(r"^#   ([A-Z][A-Z0-9_]+) {2,}\S", text, re.M))
        used = set(ENV.findall(text))
        for n in sorted(used - documented):
            fail(f"{b}: variable {n} is not documented in the header comment")
        for n in sorted(documented - used):
            fail(f"{b}: the header documents {n}, which the file does not use")


def check_fragments(frags):
    shared = {}
    base_env = env_names(yq(ROOT / BASE))
    k8s_extra = env_names(yq(ROOT / BASE_K8S)) - base_env
    for pack, fr in frags.items():
        where = f"packs/{pack}/otelcol.yaml"
        for kind in ("receivers", "processors"):
            for cid in fr.get(kind, {}):
                if not re.search(r"/obenhub(-|$)", cid):
                    fail(f"{where}: {kind[:-1]} {cid}: the name must end in /obenhub or /obenhub-<pack>")
        for pname, p in (fr.get("service", {}).get("pipelines") or {}).items():
            if not re.fullmatch(r"(metrics|logs)/obenhub-[a-z0-9-]+", pname):
                fail(f"{where}: pipeline {pname}: the name must be <signal>/obenhub-<pack>[-suffix]")
            if p.get("exporters") != ["otlp_http/obenhub"]:
                fail(f"{where}: pipeline {pname}: exporters must be [otlp_http/obenhub]")
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
        readme = ROOT / "packs" / pack / "README.md"
        names = env_names(fr) | (k8s_extra if pack in K8S_PACKS else set())
        if not readme.is_file():
            fail(f"packs/{pack}/README.md is missing (it documents the fragment's variables)")
            continue
        m = re.search(r"^## Collector fragment\n(.*?)(?=^## |\Z)", readme.read_text(), re.S | re.M)
        if not m:
            fail(f'packs/{pack}/README.md: no "## Collector fragment" section')
            continue
        doc_names = set(re.findall(r"^\| `([A-Z][A-Z0-9_]+)`", m.group(1), re.M))
        for n in sorted(names - doc_names):
            fail(f"packs/{pack}/README.md: variable {n} is not documented")
        for n in sorted(doc_names - names):
            fail(f"packs/{pack}/README.md: documents {n}, which the fragment and its base do not use")
    for cid, lst in shared.items():
        first = json.dumps(lst[0][1], sort_keys=True)
        for pack, cfg in lst[1:]:
            if json.dumps(cfg, sort_keys=True) != first:
                fail(f"packs/{pack}/otelcol.yaml: {cid} differs from packs/{lst[0][0]}/otelcol.yaml")
    base_vars_documented()


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
        # nothing listens here: the startup test must not need a backend
        "OBENHUB_GATEWAY_ENDPOINT": "http://127.0.0.1:4318",
        "OBENHUB_ETCD_METRICS_ENDPOINT": "127.0.0.1:2381",
        "OBENHUB_STORAGE_DIR": "/tmp/obenhub-storage",
    }.get(name, "disable" if name.endswith("SSLMODE") else "dummy")


def main():
    args = sys.argv[1:]
    if "--fragments" in args:
        for p in sorted((ROOT / "packs").glob("*/otelcol.yaml")):
            pack = p.parent.name
            kind = "k8s" if pack in K8S_PACKS else "vm"
            print(p.relative_to(ROOT), base_of(pack), kind)
        return 0
    frags = load_fragments()
    if "--env" in args:
        names = env_names(frags) | env_names(yq(ROOT / BASE)) | env_names(yq(ROOT / BASE_K8S))
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
                    f"{f}: a Collector configuration that is neither in LABS nor in EXCLUDED "
                    "of scripts/check-otelcol-fragments.py"
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
            f"ok   {len(frags)} fragments, {len(labs)} lab configurations, {compared[0]} components and pipelines compared: no drift"
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
