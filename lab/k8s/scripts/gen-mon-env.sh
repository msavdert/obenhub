#!/usr/bin/env bash
# Create lab/k8s/mon/.env for the backend Compose project: the Grafana admin
# password (random, kept once set) and the address the gateway Collector is
# published on (rewritten on every run, not a secret). Written by the shared
# lab/scripts/gen-env.sh.
# The address is the IPv4 gateway of the kind Docker network; it is read at run
# time because the subnet is chosen by Docker when the network is created.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

gateway_ip="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}{{"\n"}}{{end}}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)"
[ -n "$gateway_ip" ] || { echo "gen-mon-env: no IPv4 gateway on docker network 'kind'" >&2; exit 1; }

exec "$dir/../scripts/gen-env.sh" "$dir/mon/.env" GRAFANA_ADMIN_PASSWORD -- "GATEWAY_IP=$gateway_ip" GATEWAY_PORT=44317
