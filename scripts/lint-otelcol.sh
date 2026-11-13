#!/usr/bin/env bash
# Validate every tracked Collector config with `otelcol-contrib validate`, in
# the image tag the slice 1 lab runs. Needs docker. Dummy values only.
#
# Not covered: lab/k8s/otel/*-values.yaml (Helm values merged into the chart's
# own defaults; rendering needs the chart from the network, see
# lab/k8s/versions.sh OTEL_CHART_VERSION).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

image=$(sed -n 's/^ *image: *\(otel\/opentelemetry-collector-contrib:[^ ]*\)$/\1/p' lab/slice1/compose.yaml)
[ "$(printf '%s\n' "$image" | grep -c .)" = 1 ] || { echo "lint-otelcol: expected exactly one Collector image in lab/slice1/compose.yaml" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# lab/pgha/files/otelcol.yaml.tmpl is rendered by render() in
# lab/pgha/scripts/provision.sh with plain @NAME@ substitution.
sed -e 's/@NODE@/pgha-1/g' -e 's/@IP@/10.0.0.1/g' -e 's/@GATEWAY_IP@/10.0.0.2/g' \
  -e 's/@GATEWAY_PORT@/4317/g' -e 's/@OTELCOL_VERSION@/0.0.0/g' \
  lab/pgha/files/otelcol.yaml.tmpl >"$tmp/pgha-node.yaml"
if grep -q '@[A-Z_]*@' "$tmp/pgha-node.yaml"; then
  echo "lint-otelcol: unrendered placeholder in lab/pgha/files/otelcol.yaml.tmpl" >&2
  exit 1
fi

failed=0
validate() { # <label> <config file>
  if docker run --rm --user "$(id -u):$(id -g)" \
    -e OTEL_MONITOR_PASSWORD=dummy -e ORA_MON_PASSWORD=dummy -e ORA_DG_PASSWORD=dummy \
    -e OBENHUB_GATEWAY_ENDPOINT=https://10.0.0.2:4318 \
    -v "$2:/c.yaml:ro" \
    -v "$PWD/lab/packs:/etc/otelcol/packs:ro" \
    -v "$PWD/lab/packs:/etc/otelcol-contrib/packs:ro" \
    "$image" validate --config=/c.yaml >"$tmp/out" 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1" >&2
    cat "$tmp/out" >&2
    failed=1
  fi
}

# Every tracked Collector config (a top-level `service:` section).
while IFS= read -r f; do
  if grep -q '^service:' "$f"; then validate "$f" "$PWD/$f"; fi
done < <(git ls-files 'lab/*otelcol*.yaml' 'lab/*/otelcol/*.yaml')
validate "lab/pgha/files/otelcol.yaml.tmpl (rendered)" "$tmp/pgha-node.yaml"
exit "$failed"
