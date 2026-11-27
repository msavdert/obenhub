#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install test of deploy/ (roadmap D2): the backend of deploy/compose, a host
# Collector laid out as deploy/README.md "Host Collector" says, and a plain
# PostgreSQL container with its default configuration and no lab file. It
# asserts that the heartbeat is there, that nothing but Watchdog fires once
# every `for:` has elapsed, that the dead-man route delivers Watchdog about
# every 60 s, and that the dashboard panels have data. One JSON line per run
# goes to deploy/results/runs.jsonl. Needs docker, jq, curl, openssl; takes
# about 15 minutes. Not part of `mise run check`.
#   mise run deploy:install-test
# Environment: INSTALL_TEST_PORT_BASE (default 61000; six ports from there are
# bound on 127.0.0.1), INSTALL_TEST_EVIDENCE=0 to skip the runs.jsonl line,
# INSTALL_TEST_SETTLE=<seconds> to shorten the settle while debugging the test
# (no evidence line is written then).
#
# The backend, the settle wait and the assertions are in lib.sh, shared with
# vm-test.sh.
#
# Files used are those deploy/README.md tells a user to use (deploy/, packs/).
# One exception, by D1's design: the Grafana service mounts
# lab/mon/grafana/provisioning (generic datasources and a dashboard provider).
# Two deviations, both test-only:
#  - the contrib image has no journalctl, so the journald receivers of the host
#    pack cannot read anything; an overlay replaces the receivers of the host
#    logs pipeline by the base's `nop` (a list is replaced on merge), pack
#    files stay untouched. The journal is therefore not tested here.
#  - the Collector runs in a container. Without root_path the filesystem
#    scraper reports nothing there (measured with 0.165.0: 0 data points, and it
#    logs a warning), so the overlay sets root_path of the host pack's receiver
#    to /hostfs and the host's / is mounted there read-only, as the upstream
#    hostmetrics receiver README describes for containers. The host pack does
#    not set root_path itself; this is the test's choice, not a pack feature.
#    The whole / is mounted, not just /proc: the scraper reads the mount list
#    from <root_path>/proc and calls statfs on <root_path><mountpoint>, so the
#    mount points must be reachable. With only /proc mounted a debug run still
#    reported "/" with the host's numbers, but only because Docker's data root
#    lives on the host's / (the container's overlay root answers the statfs);
#    /boot and /boot/efi were missing. That is luck, not a reading of the host.
# shellcheck disable=SC2329  # functions are called from the EXIT trap and settle_wait
set -euo pipefail

# shellcheck source=deploy/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_NAME=install-test
project=obenhub-install-test
net="$project-pg"
mon="${project}_mon"
pgc="$project-pg"
colc="$project-otelcol"
# PostgreSQL 18 pin of the labs (lab/stage3/compose.yaml, lab/slice1/compose.yaml);
# scripts/check-deploy-pins.py fails when this line differs from them.
PG_IMAGE=postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
# the host Collector runs the image of the gateway, as deploy/README.md asks
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' "$repo/deploy/compose/compose.yaml")"
[ -n "$OTELCOL_IMAGE" ] || { echo "install-test: gateway image not found in compose.yaml" >&2; exit 2; }

base="${INSTALL_TEST_PORT_BASE:-61000}"
p_grafana=$base p_vm=$((base + 1)) p_vl=$((base + 2)) p_vmalert=$((base + 3)) p_am=$((base + 4)) p_gw=$((base + 5))
lib_check_ports "set INSTALL_TEST_PORT_BASE"

lib_init
EVIDENCE_IMAGES="$PG_IMAGE $OTELCOL_IMAGE"

teardown() {
  set +e
  docker rm -f "$colc" "$pgc" >/dev/null 2>&1
  backend_down
  docker network rm "$net" >/dev/null 2>&1
  rm -rf "${tmp:?}"
}
collector_alive() { docker ps -q -f name="^$colc\$" | grep -q .; }
collector_diag() { docker logs --tail 30 "$colc"; }

# a. fresh state: certificates, .env, compose project (the repo checkout stays clean)
backend_up gateway

# b. plain PostgreSQL: default configuration, own network, monitoring role from the pack
docker network create "$net" >/dev/null
pgpw="$(openssl rand -hex 12)"
monpw="$(openssl rand -hex 12)"
docker run -d --name "$pgc" --network "$net" --network-alias pg -e POSTGRES_PASSWORD="$pgpw" "$PG_IMAGE" >/dev/null
for _ in $(seq 60); do docker exec "$pgc" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
# the init scripts restart the server once; wait until it answers over TCP twice in a row
sleep 3
for _ in $(seq 60); do docker exec "$pgc" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
docker exec -i -e OTEL_MONITOR_PASSWORD="$monpw" "$pgc" psql -U postgres -v ON_ERROR_STOP=1 -q \
  -c '\getenv mon_pw OTEL_MONITOR_PASSWORD' -f - <"$repo/packs/postgresql/monitoring-role.sql" >/dev/null \
  || fail "monitoring-role.sql"

# c. host Collector: files as /etc/otelcol-contrib, as deploy/README.md lays them out
oc="$tmp/otelcol"
install -d "$oc/packs" "$oc/tls"
cp "$repo/packs/otelcol-base.yaml" "$oc/packs/"
for p in collector host postgresql; do cp -r "$repo/packs/$p" "$oc/packs/"; done
cp "$repo/deploy/collector/otelcol-tls.yaml" "$oc/"
cp "$repo/deploy/collector/obenhub.env.example" "$oc/obenhub.env"
cp "$cdir/tls/ca.crt" "$cdir/tls/client.crt" "$cdir/tls/client.key" "$oc/tls/"
chmod 0600 "$oc/obenhub.env"
sed -i -e "s#^OBENHUB_GATEWAY_ENDPOINT=.*#OBENHUB_GATEWAY_ENDPOINT=https://gateway:4318#" \
  -e "s#^OBENHUB_PG_HOST=.*#OBENHUB_PG_HOST=pg#" -e "s#^OBENHUB_PG_PASSWORD=.*#OBENHUB_PG_PASSWORD=$monpw#" \
  -e "s#^OBENHUB_PG_LOG_GLOB=.*#OBENHUB_PG_LOG_GLOB=/nonexistent/postgresql-*.json#" "$oc/obenhub.env"
# docker --env-file keeps single quotes that a shell would strip
sed -n "s/^\([A-Z_0-9]*\)='\(.*\)'$/\1=\2/p;t;/^[A-Z_0-9]*=/p" "$oc/obenhub.env" >"$tmp/docker.env"
cat >"$oc/install-test-overlay.yaml" <<'YAML'
# test only (see install-test.sh): no journalctl in the contrib image, and the
# host's / is mounted at /hostfs so the filesystem scraper has something to read
receivers:
  host_metrics/obenhub-host:
    root_path: /hostfs
service:
  pipelines:
    logs/obenhub-host:
      receivers: [nop]
YAML
chmod -R a+rX "$oc"
log "host Collector: start $OTELCOL_IMAGE"
docker run -d --name "$colc" --network "$net" --user "$(id -u):$(id -g)" --env-file "$tmp/docker.env" \
  --tmpfs /var/lib/otelcol-contrib:mode=1777 -v "$oc:/etc/otelcol-contrib:ro" -v /:/hostfs:ro "$OTELCOL_IMAGE" \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml \
  --config=/etc/otelcol-contrib/install-test-overlay.yaml >/dev/null
docker network connect "$mon" "$colc"
tcol=$(date +%s)

# d. settle, then the error count of the Collector's log
settle_wait collector_alive collector_diag
docker logs "$colc" 2>&1 | grep -ci 'error' | sed 's/^/Collector log lines with "error": /' || true

assert_backend
assert_panels

# the EXIT trap prints the summary line and appends the evidence row
completed=true
exit 0
