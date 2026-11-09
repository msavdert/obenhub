#!/usr/bin/env bash
# Create lab/pgha/mon/.env (gitignored, 0600) for the backend Compose project:
# the Grafana admin password (random, kept once set) and the values Compose
# needs from the box and from nodes.sh (rewritten on every run, not secrets).
# Same pattern as lab/stage3/scripts/gen-env.sh.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/nodes.sh"
env_file="$dir/mon/.env"

umask 077
touch "$env_file"
if [ -s "$env_file" ] && [ -n "$(tail -c1 "$env_file")" ]; then echo >>"$env_file"; fi
tmp="$(mktemp "$env_file.XXXXXX")"
# keep the password when it is set, drop every derived key
grep -E '^GRAFANA_ADMIN_PASSWORD=.' "$env_file" >"$tmp" || echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)" >>"$tmp"
{
  # the gateway container runs as this user to read the 0600 keys in pki/
  echo "GATEWAY_UID=$(id -u)"
  echo "GATEWAY_GID=$(id -g)"
  echo "GATEWAY_IP=$GATEWAY_IP"
  echo "GATEWAY_PORT=$GATEWAY_PORT"
} >>"$tmp"
mv "$tmp" "$env_file"
echo "gen-mon-env: $env_file written"
