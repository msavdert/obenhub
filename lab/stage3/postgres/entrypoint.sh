#!/usr/bin/env bash
# Node entrypoint: prepare the log directory as root, then run Patroni as the
# postgres user. Patroni initialises or clones the data directory itself.
# Adapted from patroni/patroni at tag v4.1.5 (commit 235fdb3990513c7852da8dc51e9cb92b6d0e4907), MIT licence,
# docker/entrypoint.sh (environment-driven start of Patroni); everything else
# there (haproxy, confd, bundled etcd, Zookeeper) is not used.
set -euo pipefail

mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

exec gosu postgres patroni /etc/patroni/patroni.yml
