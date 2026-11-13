#!/usr/bin/env bash
# Create lab/oracle/mon/.env for the backend Compose project: the Grafana admin
# password (random, kept once set) and the values Compose needs from the box
# and from gateway.sh (rewritten on every run, not secrets). Written by the
# shared lab/scripts/gen-env.sh.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/gateway.sh"
# the gateway container runs as GATEWAY_UID:GATEWAY_GID to read the 0600 keys in pki/
exec "$dir/../scripts/gen-env.sh" "$dir/mon/.env" GRAFANA_ADMIN_PASSWORD -- \
  "GATEWAY_UID=$(id -u)" "GATEWAY_GID=$(id -g)" "GATEWAY_IP=$GATEWAY_IP" "GATEWAY_PORT=$GATEWAY_PORT"
