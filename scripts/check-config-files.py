#!/usr/bin/env python3
"""Check that each lab's config_hash reads the same rule files on both sides.

lib-core.sh compares a hash of the repository files in CONFIG_FILES (each lab's
scenarios/lib.sh) with a hash of what the vmalert container prints for
VMALERT_LOADED_CAT. A rule file added to one list and not the other makes every
scenario of the lab fail its pre-flight, and no unit test sees it. This maps
every rule file in CONFIG_FILES to its path inside vmalert through the rendered
Compose bind mounts and compares that ordered list with the expanded
VMALERT_LOADED_CAT. Needs docker (compose config only, nothing is started).
"""

import fnmatch
import json
import os
import subprocess
import sys
import tempfile

LABS = {
    "slice1": "lab/slice1/compose.yaml",
    "stage3": "lab/stage3/compose.yaml",
    "pgha": "lab/pgha/mon/compose.yaml",
    "k8s": "lab/k8s/mon/compose.yaml",
    "oracle": "lab/oracle/mon/compose.yaml",
}
DEFAULT_CAT = "cat /etc/vmalert/inventory.yml /etc/vmalert/pack/*.yml"
ENV = [
    "APP_PASSWORD=dummy",
    "GRAFANA_ADMIN_PASSWORD=dummy",
    "LOGICAL_PASSWORD=dummy",
    "OTEL_MONITOR_PASSWORD=dummy",
    "POSTGRES_PASSWORD=dummy",
    "REPLICATOR_PASSWORD=dummy",
    "GATEWAY_IP=10.0.0.2",
    "GATEWAY_PORT=4317",
    "GATEWAY_UID=1000",
    "GATEWAY_GID=1000",
]


def lib_values(lab):
    """CONFIG_FILES (absolute paths, in order) and VMALERT_LOADED_CAT of a lab."""
    lib = f"lab/{lab}/scenarios/lib.sh"
    script = (
        'LAB_DIR="$PWD/lab/$1"; VMALERT_LOADED_CAT=""; '
        'eval "$(grep -E \'^(CONFIG_FILES|VMALERT_LOADED_CAT)=\' "$2")"; '
        'printf "%s\\n" "${VMALERT_LOADED_CAT:-}"; '
        'for f in "${CONFIG_FILES[@]}"; do realpath -m "$f"; done'
    )
    out = subprocess.run(
        ["bash", "-c", script, "_", lab, lib],
        capture_output=True,
        text=True,
        check=True,
        env={**os.environ, "LC_ALL": "C"},
    ).stdout.splitlines()
    return out[1:], out[0] or DEFAULT_CAT


def vmalert_binds(compose, envfile):
    """Bind mounts of the vmalert service: (absolute source, target)."""
    out = subprocess.run(
        ["docker", "compose", "--env-file", envfile, "-f", compose, "config", "--format", "json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    vols = json.loads(out)["services"]["vmalert"].get("volumes", [])
    return [(os.path.realpath(v["source"]), v["target"]) for v in vols if v.get("type") == "bind"]


def container_path(path, binds):
    for src, dst in binds:
        if path == src:
            return dst
        if path.startswith(src + os.sep):
            return dst + path[len(src) :]
    return None


def main():
    failed = False
    with tempfile.NamedTemporaryFile("w", suffix=".env") as env:
        env.write("\n".join(ENV) + "\n")
        env.flush()
        for lab, compose in LABS.items():
            files, cat = lib_values(lab)
            rules = [f for f in files if not f.endswith("alertmanager.yml")]
            binds = vmalert_binds(compose, env.name)
            mapped, problems = [], []
            for f in rules:
                c = container_path(f, binds)
                if c is None:
                    problems.append(f"{os.path.relpath(f)} is in CONFIG_FILES but not mounted into vmalert")
                else:
                    mapped.append(c)
            words = cat.split()
            if not words or words[0] != "cat":
                problems.append(f"VMALERT_LOADED_CAT is not a plain cat: {cat}")
                words = ["cat"]
            expanded = []
            for pattern in words[1:]:
                expanded += sorted(p for p in mapped if fnmatch.fnmatchcase(p, pattern))
            if not problems and expanded != mapped:
                problems.append(f"CONFIG_FILES maps to {mapped}, VMALERT_LOADED_CAT reads {expanded}")
            if problems:
                failed = True
                for p in problems:
                    print(f"FAIL {lab}: {p}")
            else:
                print(f"ok   {lab}: {len(mapped)} rule files, same order on both sides")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
