#!/usr/bin/env bash
# Validate every tracked Collector config with `otelcol-contrib validate`, in
# the image tag the slice 1 lab runs. Needs docker. Dummy values only.
#
# Also: each pack's Collector fragment (packs/<pack>/otelcol.yaml, ADR 0005
# decision 3) is validated merged with the base packs/otelcol-base.yaml, and
# scripts/check-otelcol-fragments.py (needs yq) fails when a lab's block for a
# pack component differs from the fragment's in more than endpoints,
# credentials, TLS and identity.
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

# The kubeletstats and k8s_cluster receivers read the in-cluster service account
# CA and token when they are built, so validate gets dummies at that path (the
# host's CA bundle stands in for a CA).
mkdir "$tmp/serviceaccount"
cp /etc/ssl/certs/ca-certificates.crt "$tmp/serviceaccount/ca.crt"
echo dummy >"$tmp/serviceaccount/token"
# dummy values of the ${env:OBENHUB_...} variables of the fragments and the base
fragenv=()
while IFS= read -r kv; do fragenv+=(-e "$kv"); done < <(python3 -I scripts/check-otelcol-fragments.py --env)

failed=0
validate() { # <label> <config file> [<second config file, merged>]
  local mount=() extra=()
  if [ -n "${3:-}" ]; then mount=(-v "$3:/c2.yaml:ro"); extra=(--config=/c2.yaml); fi
  if docker run --rm --user "$(id -u):$(id -g)" \
    -e OBENHUB_NODE=dummy -e OBENHUB_DB_UNIQUE_NAME=DUMMY -e OBENHUB_ALERT_LOG=/var/log/dummy.log \
    -e OTEL_MONITOR_PASSWORD=dummy -e ORA_MON_PASSWORD=dummy -e ORA_DG_PASSWORD=dummy \
    -e OBENHUB_GATEWAY_ENDPOINT=https://10.0.0.2:4318 \
    -v "$2:/c.yaml:ro" \
    -v "$PWD/packs:/etc/otelcol/packs:ro" \
    -v "$PWD/packs:/etc/otelcol-contrib/packs:ro" \
    -v "$tmp/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    "${fragenv[@]}" "${mount[@]}" "$image" validate --config=/c.yaml "${extra[@]}" >"$tmp/out" 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1" >&2
    cat "$tmp/out" >&2
    failed=1
  fi
}

# Every tracked Collector config (a top-level `service:` section).
while IFS= read -r f; do
  case "$f" in
    # per-VM overlays of the Oracle lab, loaded with otelcol-host.yaml
    lab/oracle/files/otelcol-db.yaml|lab/oracle/files/otelcol-obs.yaml)
      validate "$f (+ otelcol-host.yaml)" "$PWD/$f" "$PWD/lab/oracle/files/otelcol-host.yaml" ;;
    *) if grep -q '^service:' "$f"; then validate "$f" "$PWD/$f"; fi ;;
  esac
done < <(git ls-files 'lab/*otelcol*.yaml' 'lab/*/otelcol/*.yaml')
validate "lab/pgha/files/otelcol.yaml.tmpl (rendered)" "$tmp/pgha-node.yaml"
while IFS= read -r f; do
  validate "$f (+ packs/otelcol-base.yaml)" "$PWD/packs/otelcol-base.yaml" "$PWD/$f"
done < <(python3 -I scripts/check-otelcol-fragments.py --fragments)
python3 -I scripts/check-otelcol-fragments.py \
  --lab "lab/pgha/files/otelcol.yaml.tmpl (rendered)=$tmp/pgha-node.yaml" || failed=1
exit "$failed"
