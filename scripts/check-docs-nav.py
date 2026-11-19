#!/usr/bin/env python3
"""Fail when a page under docs/ is missing from the nav in zensical.toml, or
the nav names a page that does not exist. `zensical build --strict` (0.1.1)
reports neither: a page left out of the nav is built but not linked."""

import pathlib
import sys
import tomllib

root = pathlib.Path(__file__).resolve().parent.parent
conf = tomllib.loads((root / "zensical.toml").read_text())["project"]
docs = root / conf.get("docs_dir", "docs")
if "nav" not in conf:
    sys.exit("zensical.toml has no [project] nav")


def pages(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from pages(item)
    elif isinstance(node, dict):
        for value in node.values():
            yield from pages(value)


nav = list(pages(conf["nav"]))
on_disk = {p.relative_to(docs).as_posix() for p in docs.rglob("*.md")}
errors = [f"in docs/ but not in the nav: {p}" for p in sorted(on_disk - set(nav))]
errors += [f"in the nav but not in docs/: {p}" for p in nav if p not in on_disk]
errors += [f"twice in the nav: {p}" for p in sorted({p for p in nav if nav.count(p) > 1})]
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
