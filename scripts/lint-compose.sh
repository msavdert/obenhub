#!/usr/bin/env bash
# `docker compose config -q` for every tracked compose file. The files require
# variables that the gen-env scripts fill with random secrets; the same names
# get a dummy value here, so nothing real is read or written.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s=dummy\n' APP_PASSWORD GRAFANA_ADMIN_PASSWORD LOGICAL_PASSWORD \
  OTEL_MONITOR_PASSWORD POSTGRES_PASSWORD REPLICATOR_PASSWORD >"$tmp/env"
printf '%s\n' GATEWAY_IP=10.0.0.2 GATEWAY_PORT=4317 GATEWAY_UID=1000 GATEWAY_GID=1000 >>"$tmp/env"

failed=0
while IFS= read -r f; do
  if out=$(docker compose --env-file "$tmp/env" -f "$f" config -q 2>&1); then
    echo "ok   $f"
  else
    echo "FAIL $f" >&2
    echo "$out" >&2
    failed=1
  fi
done < <(git ls-files '*compose.yaml' '*compose.yml')
exit "$failed"
