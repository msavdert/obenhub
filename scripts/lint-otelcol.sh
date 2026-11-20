#!/usr/bin/env bash
# Validate every tracked Collector config with `otelcol-contrib validate`, in
# the image tag the slice 1 lab runs. Needs docker. Dummy values only.
#
# Also (ADR 0005 decision 3): each pack's Collector fragment
# (packs/<pack>/otelcol.yaml) is validated merged with its base
# (packs/otelcol-base.yaml, or otelcol-base-k8s.yaml for the Kubernetes packs
# cnpg and k8s). For the other packs the real Collector is also started once
# with base and fragment (dummy values, nothing listens at the endpoints) and
# must log "Everything is ready" within 30 s: a receiver that cannot reach its
# target at scrape time is fine, one that cannot start is not. The Kubernetes
# fragments are only validated: the pod observer and the kubelet receiver need
# an in-cluster environment (the real Collector exits on a VM).
# scripts/check-otelcol-fragments.py (needs yq) compares every lab block of a
# pack component and every lab pipeline with the fragment; what may differ is
# listed in its docstring and its ALLOW table.
#
# Not covered: lab/k8s/otel/*-values.yaml (Helm values merged into the chart's
# own defaults; rendering needs the chart from the network, see
# lab/k8s/versions.sh OTEL_CHART_VERSION).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

image=$(sed -n 's/^ *image: *\(otel\/opentelemetry-collector-contrib:[^ ]*\)$/\1/p' lab/slice1/compose.yaml)
[ "$(printf '%s\n' "$image" | grep -c .)" = 1 ] || { echo "lint-otelcol: expected exactly one Collector image in lab/slice1/compose.yaml" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'docker rm -f "obenhub-lint-$$" >/dev/null 2>&1; rm -rf "$tmp"' EXIT

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
    "${fragenv[@]}" \
    -e OBENHUB_NODE=dummy -e OBENHUB_DB_UNIQUE_NAME=DUMMY -e OBENHUB_ALERT_LOG=/var/log/dummy.log \
    -e OTEL_MONITOR_PASSWORD=dummy -e ORA_MON_PASSWORD=dummy -e ORA_DG_PASSWORD=dummy \
    -e OBENHUB_GATEWAY_ENDPOINT=https://10.0.0.2:4318 \
    -v "$2:/c.yaml:ro" \
    -v "$PWD/packs:/etc/otelcol/packs:ro" \
    -v "$PWD/packs:/etc/otelcol-contrib/packs:ro" \
    -v "$tmp/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    "${mount[@]}" "$image" validate --config=/c.yaml "${extra[@]}" >"$tmp/out" 2>&1; then
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
smoke() { # <label> <base file> <fragment file>: start the Collector, wait for "Everything is ready"
  local name="obenhub-lint-$$" i=0 up=0
  if ! docker run -d --name "$name" --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,mode=1777 \
    "${fragenv[@]}" \
    -v "$2:/c.yaml:ro" -v "$3:/c2.yaml:ro" \
    -v "$PWD/packs:/etc/otelcol-contrib/packs:ro" \
    "$image" --config=/c.yaml --config=/c2.yaml >"$tmp/out" 2>&1; then
    echo "FAIL $1" >&2; cat "$tmp/out" >&2; failed=1; return
  fi
  while [ "$i" -lt 30 ]; do
    if docker logs "$name" 2>&1 | grep -q 'Everything is ready'; then up=1; break; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
    sleep 1; i=$((i + 1))
  done
  if [ "$up" = 1 ]; then
    echo "ok   $1 (started)"
  else
    echo "FAIL $1 did not reach 'Everything is ready'" >&2
    docker logs "$name" 2>&1 | tail -15 >&2
    failed=1
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
}

while read -r f base kind; do
  validate "$f (+ $base)" "$PWD/$base" "$PWD/$f"
  if [ "$kind" = vm ]; then
    frag="$PWD/$f"
    if [ "$f" = packs/host/otelcol.yaml ]; then
      # the contrib image has no journalctl, so the journald receivers cannot start in it:
      # the host fragment is started without its logs pipeline (hostmetrics and the processors)
      yq 'del(.service.pipelines."logs/obenhub-host")' "$f" >"$tmp/host-without-logs.yaml"
      frag="$tmp/host-without-logs.yaml"
      echo "note $f: started without logs/obenhub-host (no journalctl in the image)"
    fi
    smoke "$f (+ $base)" "$PWD/$base" "$frag"
  else
    echo "note $f: Kubernetes fragment, validated only (no startup test outside a cluster)"
  fi
done < <(python3 -I scripts/check-otelcol-fragments.py --fragments)
python3 -I scripts/check-otelcol-fragments.py \
  --lab "lab/pgha/files/otelcol.yaml.tmpl (rendered)=$tmp/pgha-node.yaml" || failed=1
exit "$failed"
