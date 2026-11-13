# Slice 1 PostgreSQL image: the pinned postgres image plus pgBackRest from PGDG
# (the image already carries the PGDG apt source). pgBackRest is MIT licensed
# (ADR 0007). The package version is pinned; the exporter image in
# compose.yaml bundles its own pgbackrest binary, which must be the same
# version (checked 2026-11-13: 2.60.0).
FROM postgres:18.7-trixie@sha256:9f4fd4aa918f52ae3d6f3b687f1de90d8f867cd4d520021545a9a50c120eae3b

# renovate: datasource=deb depName=pgbackrest
ARG PGBACKREST_VERSION=2.60.0-1.pgdg13+1

RUN apt-get update \
 && apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o postgres -g postgres /var/log/pgbackrest /var/lib/pgbackrest \
 && install -d -m 0755 /etc/pgbackrest

COPY --chmod=0644 pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
