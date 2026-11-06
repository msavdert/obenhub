#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the products in eol.toml against endoflife.date.

Exit 0: all cycles supported beyond warn_days.
Exit 1: a cycle is EOL, ends within warn_days, or a slug/cycle is unknown.
Exit 2: network or parse error.
"""

import json
import sys
import tomllib
import urllib.error
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

API = "https://endoflife.date/api/v1/products/{}/"
CONFIG = Path(__file__).resolve().parent.parent / "eol.toml"


def fetch(slug):
    req = urllib.request.Request(API.format(slug), headers={"User-Agent": "obenhub-eol-check"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)["result"]["releases"]
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def eol_of(release):
    """Return (is_eol_now, date_or_None) from an API release entry."""
    value = release.get("eolFrom")
    if isinstance(value, str):
        return False, date.fromisoformat(value)  # ValueError handled by caller
    if release.get("isEol") is True:
        return True, None
    return False, None


def main():
    cfg = tomllib.loads(CONFIG.read_text(encoding="utf-8"))
    warn_days = int(cfg.get("warn_days", 120))
    today = datetime.now(timezone.utc).date()
    rows, problems = [], 0
    for prod in cfg["product"]:
        try:
            releases = fetch(prod["name"])
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as exc:
            print(f"network or parse error for {prod['name']}: {exc}", file=sys.stderr)
            return 2
        for cycle in prod["cycles"]:
            if releases is None:
                rows.append((prod["name"], cycle, "-", "-", "UNKNOWN PRODUCT"))
                problems += 1
                continue
            match = next((r for r in releases if r.get("name") == cycle), None)
            if match is None:
                rows.append((prod["name"], cycle, "-", "-", "UNKNOWN CYCLE"))
                problems += 1
                continue
            try:
                is_eol, eol_date = eol_of(match)
            except ValueError as exc:
                print(f"malformed eol date for {prod['name']} {cycle}: {exc}", file=sys.stderr)
                return 2
            if eol_date is not None:
                days = (eol_date - today).days
                if days <= 0:
                    status = "EOL"
                elif days <= warn_days:
                    status = "EOL SOON"
                else:
                    status = "ok"
                rows.append((prod["name"], cycle, str(eol_date), str(days), status))
            else:
                status = "EOL" if is_eol else "ok"
                rows.append((prod["name"], cycle, "-", "-", status))
            if status != "ok":
                problems += 1
    header = ("product", "cycle", "eol", "days", "status")
    widths = [max(len(str(r[i])) for r in rows + [header]) for i in range(5)]
    for row in [header] + rows:
        print("  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())
    print(f"warn_days={warn_days} today={today}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
