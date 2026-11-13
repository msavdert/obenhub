# shellcheck shell=bash disable=SC2034
# Versions installed on the pgha VMs (sourced by scripts/provision.sh).
# The '# renovate:' annotations use the custom managers for lab/**/*.sh in
# renovate.json. The two PGDG package pins at the bottom use datasource=deb and
# the manager with the PGDG trixie registryUrlTemplate. Unconfirmed: the deb
# manager has not yet been seen to open a pull request.

# renovate: datasource=github-releases depName=etcd-io/etcd extractVersion=^v(?<version>.+)$
ETCD_VERSION=3.6.16
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-collector-releases extractVersion=^v(?<version>.+)$
OTELCOL_VERSION=0.164.0

# PGDG (apt.postgresql.org, suite trixie-pgdg), versions seen with apt-cache
# madison on 2026-11-09 (PostgreSQL 18.7 candidate seen 2026-11-12). Same Patroni and PostgreSQL as lab/stage3/postgres.
PG_MAJOR=18
# renovate: datasource=deb depName=postgresql-18
PG_PACKAGE_VERSION=18.7-1.pgdg13+2
# renovate: datasource=deb depName=patroni
PATRONI_PACKAGE_VERSION=4.1.5-2.pgdg13+1
