#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail when a pin in deploy/ differs from the lab's pin of the same thing.

deploy/ is a second copy of what the labs run, so the pins must not drift:

1. The services of deploy/compose/compose.yaml that have an image are the
lab-pinned ones, and each image equals the image of the same service in
lab/mon/compose.base.yaml (the gateway: lab/pgha/mon/compose.yaml).
2. The Grafana plugin versions of both are equal.
3. deploy/helm/versions.sh OTEL_CHART_VERSION, OTEL_CHART_REPO and OTELCOL_IMAGE
equal lab/k8s/versions.sh, and OTELCOL_IMAGE equals the gateway image.

Plain text matching, standard library only, no network.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def service_images(path):
    """{service: image} of a compose file: the `image:` line under each top-level service."""
    out, service = {}, None
    for line in path.read_text().splitlines():
        m = re.fullmatch(r"  ([a-z0-9_-]+):\s*", line)
        if m:
            service = m.group(1)
        m = re.fullmatch(r"    image: *(\S+)(?:\s+#.*)?", line)
        if m and service:
            out[service] = m.group(1)
    return out


def plugins(path):
    m = re.search(r"GF_PLUGINS_PREINSTALL_SYNC: (\S+)", path.read_text())
    return m.group(1) if m else None


def shell_var(path, name):
    m = re.search(rf"^{name}=(\S+)$", path.read_text(), re.M)
    return m.group(1) if m else None


def main():
    deploy = ROOT / "deploy/compose/compose.yaml"
    base = ROOT / "lab/mon/compose.base.yaml"
    pgha = ROOT / "lab/pgha/mon/compose.yaml"
    k8s = ROOT / "lab/k8s/versions.sh"
    helm = ROOT / "deploy/helm/versions.sh"

    errors = []

    def same(what, got, want, want_src):
        if got is None or want is None:
            errors.append(f"{what}: not found (got {got!r}, {want_src} has {want!r})")
        elif got != want:
            errors.append(f"{what}: {got} differs from {want_src}: {want}")

    d, b, p = service_images(deploy), service_images(base), service_images(pgha)
    if not d:
        errors.append("deploy/compose/compose.yaml: no images found")
    expected = set(b) | {"gateway"}
    if set(d) != expected:
        errors.append(
            f"deploy/compose/compose.yaml services with an image {sorted(d)} differ from the lab-pinned ones {sorted(expected)}"
        )
    for service, image in d.items():
        if service == "gateway":
            same("compose gateway image", image, p.get("gateway"), "lab/pgha/mon/compose.yaml")
        else:
            same(f"compose {service} image", image, b.get(service), "lab/mon/compose.base.yaml")
    same("Grafana plugins", plugins(deploy), plugins(base), "lab/mon/compose.base.yaml")
    for name in ("OTEL_CHART_VERSION", "OTEL_CHART_REPO", "OTELCOL_IMAGE"):
        same(f"helm {name}", shell_var(helm, name), shell_var(k8s, name), "lab/k8s/versions.sh")
    same("helm OTELCOL_IMAGE", shell_var(helm, "OTELCOL_IMAGE"), d.get("gateway"), "the compose gateway")

    for e in errors:
        print(f"check-deploy-pins: {e}", file=sys.stderr)
    if not errors:
        print("check-deploy-pins: deploy pins match the lab")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
