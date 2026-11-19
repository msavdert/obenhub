#!/usr/bin/env python3
"""Stub of VictoriaLogs and Alertmanager for lab/scenarios/test-harness.sh.

Run as: python3 -I test-stub.py PORT RECORDS_FILE [PROBE_MODE]

VictoriaLogs: POST /select/logsql/query (form field query) answers the subset
of LogsQL the harness sends, over the JSON lines in RECORDS_FILE: filters
_time:>X, _time:<=X, FIELD:=VAL, FIELD:*, -FIELD:=VAL, FIELD:in(a,b), then the
pipes stats [by (f,...)] count() n, sort by (_time [desc]), limit N,
fields f,... Times compare as strings (the harness writes fixed-width UTC).
Alertmanager: POST /-/reload and /api/v2/alerts, GET /api/v2/alerts. A posted
ObenhubSinkProbe is turned into a firing and a resolved record in RECORDS_FILE
unless PROBE_MODE is "dead". Not a model of either product; it only lets the
harness code run without a lab.
"""

import json
import re
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, RECORDS = int(sys.argv[1]), sys.argv[2]
PROBE_MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"


def now():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int(t % 1 * 1000)


def load():
    try:
        with open(RECORDS) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def split_pipes(q):
    return [p.strip() for p in q.split(" | ")]


def matches(rec, tok):
    m = re.match(r"^(-?)([\w.]+):(>|<=|=|\*|in\()(.*)$", tok)
    if not m:
        raise ValueError("filter not supported: " + tok)
    neg, field, op, val = m.groups()
    got = rec.get(field)
    if op == ">":
        ok = got is not None and got > val
    elif op == "<=":
        ok = got is not None and got <= val
    elif op == "=":
        ok = got == val.strip('"')
    elif op == "*":
        ok = got is not None and got != ""
    else:
        ok = got in val.rstrip(")").split(",")
    return (not ok) if neg else ok


def tokens(s):
    return re.findall(r'(?:[^\s"]|"[^"]*")+', s)


def query(q):
    pipes = split_pipes(q)
    recs = [r for r in load() if all(matches(r, t) for t in tokens(pipes[0]))]
    for p in pipes[1:]:
        m = re.match(r"^stats(?: by \(([^)]*)\))? count\(\) (\w+)$", p)
        if m:
            by = [x.strip() for x in m.group(1).split(",")] if m.group(1) else []
            groups = {}
            for r in recs:
                k = tuple(r.get(f, "") for f in by)
                groups[k] = groups.get(k, 0) + 1
            recs = [dict(zip(by, k, strict=True), **{m.group(2): str(n)}) for k, n in groups.items()]
            continue
        m = re.match(r"^sort by \((\w+)( desc)?\)$", p)
        if m:
            recs.sort(key=lambda r: r.get(m.group(1), ""), reverse=bool(m.group(2)))
            continue
        m = re.match(r"^limit (\d+)$", p)
        if m:
            recs = recs[: int(m.group(1))]
            continue
        m = re.match(r"^fields (.*)$", p)
        if m:
            keep = [x.strip() for x in m.group(1).split(",")]
            recs = [{k: r[k] for k in keep if k in r} for r in recs]
            continue
        raise ValueError("pipe not supported: " + p)
    return recs


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()

    def do_GET(self):
        if self.path.startswith("/api/v2/alerts"):
            return self.send(200, json.dumps([{"labels": {"alertname": "Watchdog"}}]))
        self.send(404, "{}")

    def do_POST(self):
        if self.path == "/select/logsql/query":
            try:
                q = urllib.parse.parse_qs(self.body())["query"][0]
                out = "".join(json.dumps(r) + "\n" for r in query(q))
            except Exception as e:  # noqa: BLE001 - report to the test, not crash
                print("stub:", e, file=sys.stderr, flush=True)
                return self.send(400, str(e), "text/plain")
            return self.send(200, out)
        if self.path == "/-/reload":
            return self.send(200, "")
        if self.path == "/api/v2/alerts":
            alerts = json.loads(self.body())
            if PROBE_MODE != "dead":
                with open(RECORDS, "a") as f:
                    for a in alerts:
                        if a["labels"].get("alertname") != "ObenhubSinkProbe":
                            continue
                        for st in ("firing", "resolved"):
                            f.write(
                                json.dumps(
                                    {
                                        "_time": now(),
                                        "status": st,
                                        "commonLabels.alertname": "ObenhubSinkProbe",
                                        "commonLabels.probe_run": a["labels"]["probe_run"],
                                    }
                                )
                                + "\n"
                            )
            return self.send(200, "{}")
        self.send(404, "{}")


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
