# SPDX-License-Identifier: Apache-2.0
"""Shared helpers of test-pack-sql.py and pack-catalog-diff.py.

Reads packs/postgresql/queries.yaml (the entries and their `# pg-min: <N>`
comment) and packs/postgresql/tests/images.sh with the standard library, and
runs one throwaway PostgreSQL container per major. Passwords travel in the
environment (`docker exec -e NAME`, no value on the command line), never argv.
"""

import os
import re
import secrets
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import packmetrics

REPO = Path(__file__).resolve().parent.parent
QUERIES = REPO / "packs/postgresql/queries.yaml"
IMAGES = REPO / "packs/postgresql/tests/images.sh"
ROLE_SQL = REPO / "packs/postgresql/monitoring-role.sql"
LABEL = "obenhub.packsql"
OWNER = "obenhub.packsql.owner"  # host:pid of the run that created the container


def read_images():
    """Return {major: image reference} from tests/images.sh."""
    images = {}
    for m in re.finditer(r"^PG_IMAGE_(\d+)=(\S+)$", IMAGES.read_text(encoding="utf-8"), re.M):
        images[int(m.group(1))] = m.group(2)
    return images


def read_queries(path=QUERIES, tag="pg-min"):
    """Return a list of {n, sql, pg_min, min, metric, columns} for each `- sql:` entry.

    min is the value of the `# <tag>: V` line (V a major for pg-min, digits and dots otherwise; any other value raises ValueError) in the comment
    block directly above the entry, as a string, or None; pg_min is its integer
    for the default tag `pg-min` (the Oracle half passes `ora-min`). The SQL is the inline value or the
    `|` block (4-space indent) up to the `  metrics:` line. metric is the
    first metric_name, for the matrix; columns are the value_column and
    attribute_columns names of the entry's metrics. Raises ValueError when a
    top-level `- ` line is not `- sql:`, so no entry is skipped silently.
    """
    lines = path.read_text(encoding="utf-8").split("\n")
    starts = []
    for i, line in enumerate(lines):
        if line.startswith("- sql:"):
            starts.append(i)
        elif re.match(r"-(\s|$)", line):
            raise ValueError(f"{path.name}:{i + 1}: top-level entry does not begin with '- sql:': {line[:60]}")
    entries = []
    for idx, i in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
        found = None
        j = i - 1
        while j >= 0 and lines[j].startswith("#"):
            if re.match(rf"#\s*{re.escape(tag)}:", lines[j]):
                value = r"\d+" if tag == "pg-min" else r"\d+(?:\.\d+)*"
                m = re.match(rf"#\s*{re.escape(tag)}:\s*({value})\s*$", lines[j])
                if not m:
                    raise ValueError(f"{path.name}:{j + 1}: cannot parse '{tag}' line: {lines[j][:60]}")
                found = m.group(1)
            j -= 1
        rest = lines[i][len("- sql:") :].strip()
        k = i + 1
        if rest == "|":
            body = []
            while k < end and not lines[k].startswith("  metrics:"):
                body.append(lines[k][4:])
                k += 1
            sql = "\n".join(body)
        else:
            sql = rest
        metrics, _ = packmetrics.parse_lines(lines[k:end])
        columns = []
        for mt in metrics:
            columns.append(mt.get("value_column", ""))
            columns += mt.get("attribute_columns", [])
        entries.append(
            {
                "n": len(entries) + 1,
                "sql": sql,
                "min": found,
                "pg_min": int(found) if found and tag == "pg-min" else None,
                "metric": metrics[0]["metric_name"] if metrics else "?",
                "columns": columns,
            }
        )
    if not entries or len(entries) != sum(1 for ln in lines if re.match(r"-(\s|$)", ln)):
        raise ValueError(f"{path.name}: parsed {len(entries)} queries, entry count differs")
    return entries


def run(args, stdin=None, env=None, check=True):
    p = subprocess.run(args, input=stdin, capture_output=True, text=True, env=env, check=False)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])}...: exit {p.returncode}: {p.stderr.strip()[-400:]}")
    return p


def owner_alive(owner):
    """True while the run that created a container may still be running."""
    host, _, pid = owner.partition(":")
    if host and host != socket.gethostname():
        return True  # another host's run (shared docker daemon): leave it
    if not pid.isdigit():
        return False  # no owner label: a run from before the label existed
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Fleet:
    """One container per major, created in parallel, removed by label on exit."""

    def __init__(self, majors, images):
        self.run_id = secrets.token_hex(4)
        self.label = f"{LABEL}={self.run_id}"
        self.majors = majors
        self.images = images
        self.password = secrets.token_hex(12)  # superuser; also the monitoring role's
        self.env = {**os.environ, "POSTGRES_PASSWORD": self.password, "OTEL_MONITOR_PASSWORD": self.password}

    def name(self, major):
        return f"obenhub-packsql-{self.run_id}-{major}"

    def __enter__(self):
        # leftovers of a killed run: containers whose owning process on this host
        # is gone; a run in parallel keeps its containers
        out = run(
            ["docker", "ps", "-a", "--filter", f"label={LABEL}", "--format", f'{{{{.ID}}}} {{{{.Label "{OWNER}"}}}}'],
            check=False,
        ).stdout
        stale = [cid for cid, _, owner in (line.partition(" ") for line in out.splitlines()) if not owner_alive(owner)]
        if stale:
            run(["docker", "rm", "-f", "-v", *stale], check=False)
        return self

    def __exit__(self, *exc):
        self.cleanup()

    def cleanup(self):
        ids = run(["docker", "ps", "-aq", "--filter", f"label={self.label}"], check=False).stdout.split()
        if ids:
            run(["docker", "rm", "-f", "-v", *ids], check=False)

    def start(self):
        """Pull, start and wait for every container; the role is created. Returns once all are ready."""

        def one(major):
            image = self.images[major]
            run(["docker", "pull", "-q", image])
            run(
                [
                    "docker", "run", "-d", "--name", self.name(major), "--label", self.label, "--label", f"{OWNER}={socket.gethostname()}:{os.getpid()}",
                    "--tmpfs", "/var/lib/postgresql", "-e", "POSTGRES_PASSWORD",
                    image, "-c", "fsync=off", "-c", "max_connections=20",
                    "-c", "shared_preload_libraries=pg_stat_statements",
                ],
                env=self.env,
            )  # fmt: skip
            # the init server listens on the socket only; TCP answers once the final server is up
            for _ in range(120):
                if (
                    run(
                        ["docker", "exec", self.name(major), "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
                        check=False,
                    ).returncode
                    == 0
                ):
                    break
                time.sleep(1)
            else:
                raise RuntimeError(f"PostgreSQL {major} not ready")
            self.psql(
                major,
                ROLE_SQL.read_text(encoding="utf-8"),
                role="postgres",
                extra=["-c", r"\getenv mon_pw OTEL_MONITOR_PASSWORD"],
                first=True,
            )

        with ThreadPoolExecutor(len(self.majors)) as ex:
            list(ex.map(one, self.majors))

    def psql(self, major, sql, role="otel_monitor", extra=(), first=False, tuples=False, header=False):
        """Run sql on the container; returns the CompletedProcess (never raises on SQL errors, except for setup)."""
        args = ["docker", "exec", "-i", "-e", "PGPASSWORD", "-e", "OTEL_MONITOR_PASSWORD", self.name(major)]
        env = {**self.env, "PGPASSWORD": self.password}
        args += [
            "psql",
            "-h",
            "127.0.0.1",
            "-U",
            role,
            "-d",
            "postgres",
            "-X",
            "-q",
            "-v",
            "ON_ERROR_STOP=1",
            "-v",
            "VERBOSITY=verbose",
        ]
        if tuples:
            args += ["-A", "-t", "-F", "\t"]
        elif header:
            args += ["-A", "-F", "\t", "-P", "footer=off"]
        args += [*extra, "-f", "-"]
        p = run(args, stdin=sql, env=env, check=False)
        if first and p.returncode != 0:
            raise RuntimeError(f"role setup on {major}: {p.stderr.strip()[-400:]}")
        return p
