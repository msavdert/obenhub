# shellcheck shell=bash disable=SC2034
# Versions installed on the pgha VMs (sourced by scripts/provision.sh).
# The two '# renovate:' annotations use the existing custom manager for
# lab/**/*.sh (renovate.json); the PGDG package pins below carry no annotation
# on purpose: that manager has no apt repository URL, and a deb annotation
# without one would only produce errors.

# renovate: datasource=github-releases depName=etcd-io/etcd extractVersion=^v(?<version>.+)$
ETCD_VERSION=3.6.16
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-collector-releases extractVersion=^v(?<version>.+)$
OTELCOL_VERSION=0.164.0

# PGDG (apt.postgresql.org, suite trixie-pgdg), versions seen with apt-cache
# madison on 2026-11-09. Same Patroni and PostgreSQL as lab/stage3/postgres.
PG_MAJOR=18
PG_PACKAGE_VERSION=18.6-1.pgdg13+2
PATRONI_PACKAGE_VERSION=4.1.5-2.pgdg13+1
