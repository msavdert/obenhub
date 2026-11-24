# Slice 1 PostgreSQL image: the pinned postgres image plus pgBackRest from PGDG
# (the image already carries the PGDG apt source). pgBackRest is MIT licensed
# (ADR 0007). The package version is pinned; the exporter image in
# compose.yaml bundles its own pgbackrest binary, which should be the same
# version (2.60.0 checked 2026-11-13). The package moved to 2.60.1 on
# 2026-11-22 while the exporter image still bundles 2.60.0 (same minor).
FROM postgres:19.0-trixie@sha256:908d19593a1444b2d4e85783f718b16e0d40f1baf7518420475df9e5f5ac67a2

# renovate: datasource=deb depName=pgbackrest
ARG PGBACKREST_VERSION=2.60.1-1.pgdg13+1

RUN apt-get update \
 && apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o postgres -g postgres /var/log/pgbackrest /var/lib/pgbackrest \
 && install -d -m 0755 /etc/pgbackrest

COPY --chmod=0644 pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
