#!/usr/bin/env bash
# Create lab/k8s/mon/.env (gitignored, 0600) for the backend Compose project:
# the Grafana admin password (random, kept once set) and the address the
# gateway Collector is published on (rewritten on every run, not a secret).
# Same pattern as lab/pgha/scripts/gen-mon-env.sh.
# The address is the IPv4 gateway of the kind Docker network; it is read at run
# time because the subnet is chosen by Docker when the network is created.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$dir/mon/.env"

gateway_ip="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}{{"\n"}}{{end}}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)"
[ -n "$gateway_ip" ] || { echo "gen-mon-env: no IPv4 gateway on docker network 'kind'" >&2; exit 1; }

umask 077
touch "$env_file"
if [ -s "$env_file" ] && [ -n "$(tail -c1 "$env_file")" ]; then echo >>"$env_file"; fi
tmp="$(mktemp "$env_file.XXXXXX")"
# keep the password when it is set, drop every derived key
grep -E '^GRAFANA_ADMIN_PASSWORD=.' "$env_file" >"$tmp" || echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)" >>"$tmp"
{
  echo "GATEWAY_IP=$gateway_ip"
  echo "GATEWAY_PORT=44317"
} >>"$tmp"
if cmp -s "$tmp" "$env_file"; then rm -f "$tmp"; else mv "$tmp" "$env_file"; fi
echo "gen-mon-env: $env_file ready (gateway ${gateway_ip}:44317)"
