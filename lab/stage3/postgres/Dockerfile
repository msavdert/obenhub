# Stage 3 node image: the stage 2 base image plus the PGDG patroni package.
# Patroni is MIT licensed (ADR 0004). The package version is pinned.
FROM postgres:18.7-trixie@sha256:9f4fd4aa918f52ae3d6f3b687f1de90d8f867cd4d520021545a9a50c120eae3b

# renovate: datasource=deb depName=patroni
ARG PATRONI_VERSION=4.1.5-2.pgdg13+1

# python3-etcd (python-etcd, MIT) is not a hard dependency of the package, but
# patroni/dcs/etcd3.py imports it (observed: without it Patroni 4.1.5 offers
# only consul and kubernetes). Left unpinned: it is Debian's own package and
# provides only that import.
RUN apt-get update \
 && apt-get install -y --no-install-recommends "patroni=${PATRONI_VERSION}" python3-etcd \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0644 patroni.yml /etc/patroni/patroni.yml
COPY --chmod=0755 post-bootstrap.sh /etc/patroni/post-bootstrap.sh
ENTRYPOINT ["/entrypoint.sh"]
