#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail unless every alert carries a description and the runbook_url that fits it.

check-alert-docs.py     enforce everything
check-alert-docs.py --allow-missing-runbooks
    print, but do not fail on, scenario-fired alerts whose docs/runbooks/<pack>.md section is missing

An alert in packs/*/rules.yml must have the annotations `description` and
`runbook_url` (every tier of one alertname the same description and URL).
The URL is `<site_url>runbooks/<pack>/#<anchor>` when a lab scenario waits for
the alert (an EXPECT entry, scripts/packalerts.py), else
`<site_url>reference/<pack>-pack-alerts/#<anchor>`, with the anchor the
lowercased alert name. The anchor must exist as a `##` heading in the page the
URL names: docs/reference/<pack>-pack-alerts.md is generated, so a missing
heading means the generator was not run; docs/runbooks/<pack>.md is written by
hand and holds one section for each alert a scenario fires and for no other.

Also failing: a scenario that expects an alert with no rule, and a rule file
outside packs/ that defines an alert (it would have no reference page).
"""

import re
import sys

from packalerts import ROOT, lab_alert_files, pack_alerts, scenario_alerts


def headings(path):
    """The level-2 headings of a markdown file, outside code fences."""
    found, fence = [], False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        elif not fence and line.startswith("## "):
            found.append(line[3:].strip())
    return found


def slug(text):
    """The toc extension's default id: word characters and hyphens, lowercased."""
    return re.sub(r"[-\s]+", "-", re.sub(r"[^\w\s-]", "", text).strip().lower())


def main():
    from packalerts import runbook_url

    allow_missing = "--allow-missing-runbooks" in sys.argv
    fired = scenario_alerts()
    errors, missing = [], []
    known = set()
    packs = pack_alerts()

    for path in lab_alert_files():
        errors.append(
            f"{path.relative_to(ROOT)}: defines an alert outside packs/; move it into a pack so it gets a reference entry"
        )

    for pack, alerts in packs.items():
        by_name = {}
        for a in alerts:
            by_name.setdefault(a["name"], []).append(a)
        reference = ROOT / "docs/reference" / f"{pack}-pack-alerts.md"
        runbook = ROOT / "docs/runbooks" / f"{pack}.md"
        ref_anchors = {slug(h) for h in headings(reference)} if reference.exists() else set()
        run_anchors = {slug(h) for h in headings(runbook)} if runbook.exists() else set()
        for name, tiers in by_name.items():
            known.add(name)
            where = f"packs/{pack}/rules.yml:{tiers[0]['line']} {name}"
            for key in ("description", "runbook_url"):
                if not all(t["annotations"].get(key) for t in tiers):
                    errors.append(f"{where}: no {key} annotation")
            for key in ("description", "runbook_url"):
                if len({t["annotations"].get(key) for t in tiers}) > 1:
                    errors.append(f"{where}: its tiers differ in {key}")
            want = runbook_url(pack, name, fired)
            for t in tiers:
                got = t["annotations"].get("runbook_url")
                if got and got != want:
                    errors.append(f"{where}: runbook_url is {got}, want {want}")
            anchor = want.rsplit("#", 1)[1]
            if name in fired:
                if anchor not in run_anchors:
                    missing.append(f"docs/runbooks/{pack}.md: no section ## {name} (fired by {', '.join(fired[name])})")
            elif anchor not in ref_anchors:
                errors.append(
                    f"{where}: no heading ## {name} in docs/reference/{pack}-pack-alerts.md (run scripts/gen-pack-alerts.py)"
                )

    for name in sorted(set(fired) - known):
        errors.append(f"{', '.join(fired[name])}: expects {name}, which no pack rule defines")

    for page in sorted((ROOT / "docs/runbooks").glob("*.md")) if (ROOT / "docs/runbooks").exists() else []:
        pack = page.stem
        names = {a["name"] for a in packs.get(pack, [])}
        for h in headings(page):
            if h not in names:
                errors.append(f"{page.relative_to(ROOT)}: section ## {h} is no alert of packs/{pack}/rules.yml")
            elif h not in fired:
                errors.append(
                    f"{page.relative_to(ROOT)}: section ## {h}: no scenario fires this alert, its entry is docs/reference/{pack}-pack-alerts.md"
                )

    for line in missing:
        print(("note: " if allow_missing else "") + line, file=sys.stderr)
    if allow_missing and missing:
        print(
            f"note: {len(missing)} scenario-fired alert names have no runbook section yet (--allow-missing-runbooks)",
            file=sys.stderr,
        )
    for line in errors:
        print(line, file=sys.stderr)
    if errors or (missing and not allow_missing):
        return 1
    n = sum(len(a) for a in packs.values())
    print(f"{n} alert rules carry description and runbook_url ({len(fired)} alert names fired by scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
