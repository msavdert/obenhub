#!/usr/bin/env bash
# Write lab/slice1/.env with random passwords unless it already exists.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$dir/.env"

if [ -e "$env_file" ]; then
  echo "gen-env: $env_file exists, keeping it"
  exit 0
fi

umask 077
{
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
  echo "REPLICATOR_PASSWORD=$(openssl rand -hex 16)"
  echo "OTEL_MONITOR_PASSWORD=$(openssl rand -hex 16)"
} >"$env_file"
echo "gen-env: wrote $env_file"
