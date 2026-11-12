#!/usr/bin/env bash
# One-time setup of the Collector overhead measurement. Targets pg-lab
# (10.0.0.13, Debian 13) over ssh from the box; it changes only pg-lab.
#
# What it does (idempotent):
#   - installs otelcol-contrib (VERSION below) from the official release tarball,
#     verified against the release's per-asset .sha256 file;
#   - creates the system user otelcol, /etc/otelcol-contrib/env (root, 0600,
#     random OTEL_MONITOR_PASSWORD generated on pg-lab, never printed) and the
#     systemd unit obenhub-otelcol.service (own cgroup, left disabled);
#   - passwords go to psql through stdin only, with pg_stat_statements.track
#     set to none first so no statement text carrying one is recorded;
#   - mirrors the slice 1 PostgreSQL settings in conf.d/90-overhead.conf,
#     restarts postgresql@18-main, creates role otel_monitor and
#     pg_stat_statements;
#   - copies otelcol.yaml to /etc/otelcol-contrib/config.yaml and the shared
#     pack lab/packs/postgresql/queries.yaml (the version in this checkout)
#     to /etc/otelcol-contrib/packs/postgresql/queries.yaml;
#   - initialises pgbench (scale 100) in database postgres.
# Usage: lab/overhead/setup.sh
set -euo pipefail

HOST="${PGLAB_HOST:-pg-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-collector-releases extractVersion=^v(?<version>.+)$
VERSION=0.164.0
SCALE="${SCALE:-100}"

scp -q "$HERE/otelcol.yaml" "$HOST:/tmp/obenhub-otelcol.yaml"
scp -q "$HERE/../packs/postgresql/queries.yaml" "$HOST:/tmp/obenhub-queries.yaml"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$HOST" sudo VERSION="$VERSION" SCALE="$SCALE" bash -s <<'REMOTE'
set -euo pipefail
base=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$VERSION
f=otelcol-contrib_${VERSION}_linux_amd64.tar.gz

if ! /usr/local/bin/otelcol-contrib --version 2>/dev/null | grep -q "$VERSION"; then
  d=$(mktemp -d)
  curl -fsSL -o "$d/$f" "$base/$f"
  curl -fsSL -o "$d/$f.sha256" "$base/$f.sha256"
  # the release file holds the bare hash
  echo "$(cut -d' ' -f1 "$d/$f.sha256")  $d/$f" | sha256sum -c -
  tar -xzf "$d/$f" -C "$d" otelcol-contrib
  install -m 0755 "$d/otelcol-contrib" /usr/local/bin/otelcol-contrib
  rm -rf "$d"
fi

id otelcol >/dev/null 2>&1 || useradd --system --home-dir /var/lib/otelcol-overhead --shell /usr/sbin/nologin otelcol
install -d -m 0755 /etc/otelcol-contrib
install -d -m 0750 -o otelcol -g otelcol /var/lib/otelcol-overhead
if [ ! -f /etc/otelcol-contrib/env ]; then
  (umask 077; echo "OTEL_MONITOR_PASSWORD=$(openssl rand -hex 24)" >/etc/otelcol-contrib/env)
fi
chown root:root /etc/otelcol-contrib/env
chmod 0600 /etc/otelcol-contrib/env
install -m 0644 /tmp/obenhub-otelcol.yaml /etc/otelcol-contrib/config.yaml
rm -f /tmp/obenhub-otelcol.yaml
install -d -m 0755 /etc/otelcol-contrib/packs/postgresql
install -m 0644 /tmp/obenhub-queries.yaml /etc/otelcol-contrib/packs/postgresql/queries.yaml
rm -f /tmp/obenhub-queries.yaml
sha256sum /etc/otelcol-contrib/packs/postgresql/queries.yaml

cat >/etc/systemd/system/obenhub-otelcol.service <<'UNIT'
[Unit]
Description=obenhub Collector (overhead measurement)
After=postgresql@18-main.service

[Service]
User=otelcol
Group=otelcol
EnvironmentFile=/etc/otelcol-contrib/env
ExecStart=/usr/local/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml
Restart=no
MemoryAccounting=yes
CPUAccounting=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl disable obenhub-otelcol.service >/dev/null 2>&1 || true

cat >/etc/postgresql/18/main/conf.d/90-overhead.conf <<'CONF'
# Mirrors lab/slice1/compose.yaml for the Collector overhead measurement.
shared_preload_libraries = 'pg_stat_statements'
reserved_connections = 8
logging_collector = on
log_destination = 'jsonlog'
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%a.log'
log_file_mode = 0644
log_truncate_on_rotation = on
log_timezone = 'UTC'
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 1000
track_io_timing = on
CONF
systemctl restart postgresql@18-main.service </dev/null
for _ in $(seq 30); do sudo -u postgres pg_isready -q </dev/null && break; sleep 1; done

# the password goes through stdin as a psql variable, not through argv
# shellcheck disable=SC1091
. /etc/otelcol-contrib/env
{
  printf "\\\\set mon_pw '%s'\n" "$OTEL_MONITOR_PASSWORD"
  cat <<'SQL'
-- keep the password statements out of pg_stat_statements (same session)
SET pg_stat_statements.track = 'none';
SELECT format('CREATE ROLE otel_monitor WITH LOGIN PASSWORD %L', :'mon_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'otel_monitor') \gexec
SELECT format('ALTER ROLE otel_monitor WITH LOGIN PASSWORD %L', :'mon_pw') \gexec
GRANT pg_monitor TO otel_monitor;
GRANT pg_use_reserved_connections TO otel_monitor;
ALTER ROLE otel_monitor SET statement_timeout = '5s';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
} | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d postgres >/dev/null

if ! sudo -u postgres psql -Atqc "select 1 from pg_class where relname='pgbench_accounts'" postgres </dev/null | grep -q 1; then
  sudo -u postgres pgbench -i -s "$SCALE" -q postgres </dev/null
fi
sudo -u postgres psql -Atc "select pg_size_pretty(pg_database_size('postgres'))" postgres </dev/null
REMOTE
