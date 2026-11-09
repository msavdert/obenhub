#!/usr/bin/env bash
# Create lab/pgha/.env (gitignored, 0600) with random passwords and add any key
# that is missing from an existing one. Existing non-empty values are never
# changed. Same pattern as lab/stage3/scripts/gen-env.sh.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$dir/.env"

umask 077
touch "$env_file"
added=""
if [ -s "$env_file" ] && [ -n "$(tail -c1 "$env_file")" ]; then echo >>"$env_file"; fi
for key in POSTGRES_PASSWORD REPLICATOR_PASSWORD OTEL_MONITOR_PASSWORD APP_PASSWORD PATRONI_API_PASSWORD; do
  if ! grep -q "^${key}=." "$env_file"; then
    tmp="$(mktemp "$env_file.XXXXXX")"
    grep -v "^${key}=" "$env_file" >"$tmp" || true
    echo "${key}=$(openssl rand -hex 16)" >>"$tmp"
    mv "$tmp" "$env_file"
    added="$added $key"
  fi
done
if [ -n "$added" ]; then
  echo "gen-env: $env_file: added$added"
else
  echo "gen-env: $env_file complete, keeping it"
fi
