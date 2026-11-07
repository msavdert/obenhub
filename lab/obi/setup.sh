#!/usr/bin/env bash
# One-time setup of the OBI experiment. Targets pg-lab (10.0.0.13, Debian 13)
# over ssh from the box; it changes only pg-lab. Never run OBI anywhere else:
# it instruments every matching process on its kernel.
#
# What it does (idempotent):
#   - installs PgBouncer PGBOUNCER_VERSION from the PGDG apt repository that
#     pg-lab already uses, writes /etc/pgbouncer/pgbouncer.ini from
#     pgbouncer.ini, leaves the service stopped and disabled;
#   - installs OBI OBI_VERSION from the GitHub release tarball
#     (obi-v*-linux-amd64.tar.gz), verified against the release's SHA256SUMS,
#     into /opt/obi, with licence files;
#   - installs the Collector config as /etc/obi-lab/otelcol.yaml and the units
#     obi.service (root, needs eBPF) and obenhub-otelcol-obi.service (user
#     otelcol), both left stopped and disabled;
#   - writes /etc/obi-lab/tpcb-late.sql: the built-in pgbench TPC-B-like script
#     (as printed by pgbench -r) with a 12 s sleep before each client's first
#     transaction (run with -D started=0), for the diagnostic cell that lets OBI attach before the
#     statements are prepared;
#   - creates role obi_bench (random password generated on pg-lab, never
#     printed, kept in /etc/obi-lab/pgpass and /etc/pgbouncer/userlist.txt)
#     with access to the pgbench tables in database postgres. Password
#     statements go through stdin with pg_stat_statements.track = none.
# Requires lab/overhead/setup.sh to have run (pgbench tables, otelcol-contrib,
# user otelcol).
# Usage: lab/obi/setup.sh
set -euo pipefail

HOST="${PGLAB_HOST:-pg-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-ebpf-instrumentation extractVersion=^v(?<version>.+)$
OBI_VERSION=1.0.0
# assumption: the PGDG package revision as seen on pg-lab on 2026-11-07
PGBOUNCER_VERSION=1.26.1-1.pgdg13+1

T=$(ssh "$HOST" mktemp -d)   # private staging directory on pg-lab
scp -q "$HERE/obi.yaml" "$HERE/otelcol.yaml" "$HERE/pgbouncer.ini" "$HERE/measure-cell.sh" "$HOST:$T/"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$HOST" sudo T="$T" OBI_VERSION="$OBI_VERSION" PGBOUNCER_VERSION="$PGBOUNCER_VERSION" bash -s <<'REMOTE'
set -euo pipefail
id otelcol >/dev/null 2>&1 || { echo "user otelcol missing: run lab/overhead/setup.sh first" >&2; exit 1; }

dpkg -s pgbouncer 2>/dev/null | grep -q "^Version: $PGBOUNCER_VERSION$" \
  || DEBIAN_FRONTEND=noninteractive apt-get install -y "pgbouncer=$PGBOUNCER_VERSION" </dev/null
systemctl disable --now pgbouncer.service >/dev/null 2>&1 || true
[ -f /etc/pgbouncer/pgbouncer.ini.orig ] || cp -p /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.orig
install -m 0640 -o postgres -g postgres "$T/pgbouncer.ini" /etc/pgbouncer/pgbouncer.ini

base=https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/releases/download/v$OBI_VERSION
f=obi-v${OBI_VERSION}-linux-amd64.tar.gz
if [ "$(cat /opt/obi/VERSION 2>/dev/null)" != "$OBI_VERSION" ]; then
  d=$(mktemp -d)
  curl -fsSL -o "$d/$f" "$base/$f"
  curl -fsSL -o "$d/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$d" && grep " $f\$" SHA256SUMS | sha256sum -c -)
  install -d -m 0755 /opt/obi
  tar -xzf "$d/$f" -C /opt/obi obi LICENSE NOTICE
  echo "$OBI_VERSION" >/opt/obi/VERSION
  rm -rf "$d"
fi

install -d -m 0755 /etc/obi-lab
install -d -m 0750 -o otelcol -g otelcol /var/lib/obi-lab
install -m 0644 "$T/obi.yaml" /etc/obi-lab/obi.yaml
install -m 0644 "$T/otelcol.yaml" /etc/obi-lab/otelcol.yaml
install -m 0755 "$T/measure-cell.sh" /usr/local/sbin/obi-measure-cell.sh
# tpcb-late.sql is pgbench's built-in TPC-B-like script with a sleep added.
# Source: src/bin/pgbench/pgbench.c (the tpcb-like script text), postgres/postgres
# tag REL_18_6 (commit 724edf9bde9d356724ad384a2e196edc3c9f80f7, from
# git ls-remote 2026-11-07; pg-lab's pgbench is 18.6, assumed built from that
# tag). Licence: PostgreSQL License (COPYRIGHT at that tag). The statements
# were copied from the output of pgbench -r, not from the source file itself.
cat >/etc/obi-lab/tpcb-late.sql <<'SQL'
\if :started = 0
\sleep 12 s
\set started 1
\endif
\set aid random(1, 100000 * :scale)
\set bid random(1, 1 * :scale)
\set tid random(1, 10 * :scale)
\set delta random(-5000, 5000)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;
SQL
rm -rf "$T"

cat >/etc/systemd/system/obenhub-otelcol-obi.service <<'UNIT'
[Unit]
Description=obenhub Collector (OBI experiment)

[Service]
User=otelcol
Group=otelcol
ExecStart=/usr/local/bin/otelcol-contrib --config=/etc/obi-lab/otelcol.yaml
Restart=no
CPUAccounting=yes
MemoryAccounting=yes

[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/obi.service <<'UNIT'
[Unit]
Description=OpenTelemetry eBPF Instrumentation (OBI experiment)
After=obenhub-otelcol-obi.service

[Service]
ExecStart=/opt/obi/obi -config /etc/obi-lab/obi.yaml
Restart=no
CPUAccounting=yes
MemoryAccounting=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl disable obi.service obenhub-otelcol-obi.service >/dev/null 2>&1 || true

if [ ! -f /etc/obi-lab/pw ]; then
  (umask 077; openssl rand -hex 24 >/etc/obi-lab/pw)
fi
pw=$(cat /etc/obi-lab/pw)
# pgpass for the postgres OS user (pgbench runs as postgres); user list for PgBouncer
(umask 077; printf '127.0.0.1:*:*:obi_bench:%s\n' "$pw" >/etc/obi-lab/pgpass)
chown postgres:postgres /etc/obi-lab/pgpass
(umask 027; printf '"obi_bench" "%s"\n' "$pw" >/etc/pgbouncer/userlist.txt)
chown postgres:postgres /etc/pgbouncer/userlist.txt

{
  printf "\\\\set bench_pw '%s'\n" "$pw"
  cat <<'SQL'
SET log_min_error_statement = panic;
SET pg_stat_statements.track = 'none';
SELECT format('CREATE ROLE obi_bench WITH LOGIN PASSWORD %L', :'bench_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'obi_bench') \gexec
SELECT format('ALTER ROLE obi_bench WITH LOGIN PASSWORD %L', :'bench_pw') \gexec
GRANT SELECT, UPDATE ON pgbench_accounts, pgbench_tellers, pgbench_branches TO obi_bench;
GRANT INSERT ON pgbench_history TO obi_bench;
SQL
} | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d postgres >/dev/null

sha256sum /opt/obi/obi
dpkg -s pgbouncer | grep '^Version'
REMOTE
