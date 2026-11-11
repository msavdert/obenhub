#!/usr/bin/env bash
# Bring up kind, the CloudNativePG operator and the three-instance Cluster,
# the backend Compose project (obenhub-k8s, lab/k8s/mon) and the two Collector
# releases (lab/k8s/otel). Idempotent: every step checks or applies
# declaratively; a Helm release is upgraded only when its rendered manifest
# differs from the installed one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${here}/versions.sh"

# Values are pasted into YAML with sed: refuse empty ones and sed metacharacters.
for v in KIND_CLUSTER KIND_NODE_IMAGE PG_IMAGE OTELCOL_IMAGE OTEL_CHART_VERSION OTEL_CHART_REPO; do
  case "${!v:-}" in
    "" | *[\&\|\\]*) echo "versions.sh: ${v} is empty or contains & | or backslash" >&2; exit 1 ;;
  esac
done

# The pinned tools (mise.toml). Run directly from a shell without mise
# activated, the script re-runs itself once under `mise exec`.
if ! "${here}/scripts/check-tools.sh" >/dev/null 2>&1 && [ -z "${OBENHUB_MISE_REEXEC:-}" ] && command -v mise >/dev/null; then
  export OBENHUB_MISE_REEXEC=1
  cd "${here}/../.."
  exec mise exec -- "${here}/scripts/up.sh" "$@"
fi
"${here}/scripts/check-tools.sh"

name="${KIND_CLUSTER}"
# The CollectorAbsent inventory names the agents after the kind nodes.
if ! grep -q "otelcol-agent-${name}-worker\"" "${here}/mon/vmalert/inventory.yml"; then
  echo "mon/vmalert/inventory.yml does not list the agents of cluster ${name}; update it" >&2
  exit 1
fi
ctx="kind-${name}"
k() { kubectl --context "${ctx}" "$@"; }
repo_root="$(cd "${here}/../.." && pwd)"
otel_ns=obenhub-otel
monitor_secret=pg-otel-monitor
phase_start="$(date +%s)"
phase() { local now; now="$(date +%s)"; echo "[$((now - phase_start))s] $1"; phase_start="${now}"; }

if ! kind get clusters 2>/dev/null | grep -qx "${name}"; then
  # kind known-issues values: https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
  watches="$(sysctl -n fs.inotify.max_user_watches)"
  instances="$(sysctl -n fs.inotify.max_user_instances)"
  if [ "${watches}" -lt 524288 ] || [ "${instances}" -lt 512 ]; then
    echo "inotify too low: max_user_watches=${watches} (need 524288), max_user_instances=${instances} (need 512); not changing sysctls" >&2
    exit 1
  fi
  sed "s|\${KIND_NODE_IMAGE}|${KIND_NODE_IMAGE}|g" "${here}/kind.yaml" |
    kind create cluster --name "${name}" --config -
fi

# The operator manifest is downloaded once, checked against the sha256 recorded
# in versions.sh and only then applied.
cnpg_manifest="$(mktemp)"
trap 'rm -f "${cnpg_manifest}"' EXIT
curl -fsSL --retry 3 -o "${cnpg_manifest}" "${CNPG_MANIFEST_URL}"
cnpg_sha="$(sha256sum "${cnpg_manifest}" | cut -d' ' -f1)"
if [ "${cnpg_sha}" != "${CNPG_MANIFEST_SHA256}" ]; then
  echo "CloudNativePG manifest ${CNPG_MANIFEST_URL}: sha256 ${cnpg_sha}, versions.sh CNPG_MANIFEST_SHA256 ${CNPG_MANIFEST_SHA256}" >&2
  exit 1
fi
k apply --server-side -f "${cnpg_manifest}"
k -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s

# The monitoring role's password: generated once, kept in a Secret (never in a
# file, a log or the command line). CloudNativePG reads it for the managed role.
if ! k -n obenhub get secret "${monitor_secret}" >/dev/null 2>&1; then
  k create namespace obenhub --dry-run=client -o yaml | k apply -f - >/dev/null
  openssl rand -hex 16 | tr -d "\n" | k -n obenhub create secret generic "${monitor_secret}" \
    --type=kubernetes.io/basic-auth \
    --from-file=username=<(printf otel_monitor) --from-file=password=/dev/stdin
fi
k -n obenhub label --overwrite secret "${monitor_secret}" cnpg.io/reload=true >/dev/null

sed "s|\${PG_IMAGE}|${PG_IMAGE}|g" "${here}/cnpg/cluster.yaml" | k apply --server-side -f -

echo "waiting for 3 ready instances and the monitoring role"
ok=
for _ in $(seq 1 120); do
  ready="$(k -n obenhub get cluster pg -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
  role="$(k -n obenhub get cluster pg -o jsonpath='{.status.managedRolesStatus.byStatus.reconciled}' 2>/dev/null || true)"
  if [ "${ready:-0}" = 3 ] && [[ "${role}" == *otel_monitor* ]]; then ok=1; break; fi
  sleep 5
done
if [ -z "${ok}" ]; then
  echo "timed out waiting for readyInstances=3 and role otel_monitor (got '${ready:-}', '${role:-}')" >&2
  exit 1
fi
k -n obenhub get cluster pg
phase "cluster ready"

# Write load for the fault scenarios (needs the Secret pg-app, made with the Cluster).
sed "s|\${PG_IMAGE}|${PG_IMAGE}|g" "${here}/load/load.yaml" | k apply -f -
k -n obenhub rollout status deployment/obenhub-load --timeout=300s
phase "load client ready"

# Backend on the box. The gateway is published on the kind network's IPv4
# gateway, which only exists once kind has created the network.
"${here}/scripts/gen-mon-env.sh"
docker compose -p obenhub-k8s -f "${here}/mon/compose.yaml" up -d --wait
phase "backend up"
gateway_ip="$(sed -n 's/^GATEWAY_IP=//p' "${here}/mon/.env")"
gateway_port="$(sed -n 's/^GATEWAY_PORT=//p' "${here}/mon/.env")"
gateway_endpoint="http://${gateway_ip}:${gateway_port}"

# Collector inputs in the cluster: the monitoring Secret, the PostgreSQL pack
# and the cluster CA (public certificate only), as ConfigMaps.
k create namespace "${otel_ns}" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n "${otel_ns}" create secret generic "${monitor_secret}" \
  --type=kubernetes.io/basic-auth \
  --from-file=username=<(printf otel_monitor) \
  --from-file=password=<(k -n obenhub get secret "${monitor_secret}" -o jsonpath='{.data.password}' | base64 -d) \
  --dry-run=client -o yaml | k apply -f - >/dev/null
ca_file="$(mktemp)"
trap 'rm -f "${cnpg_manifest}" "${ca_file}"' EXIT
k -n obenhub get secret pg-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_file}"
k -n "${otel_ns}" create configmap obenhub-pack-postgresql \
  --from-file=queries.yaml="${repo_root}/lab/packs/postgresql/queries.yaml" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n "${otel_ns}" create configmap obenhub-pg-ca \
  --from-file=ca.crt="${ca_file}" --dry-run=client -o yaml | k apply -f - >/dev/null
# the monitoring password is read from the Secret at pod start: its hash (not
# the value) is part of the checksum so that a new password rolls the pods
inputs_sha="$({ cat "${repo_root}/lab/packs/postgresql/queries.yaml" "${ca_file}"
  k -n obenhub get secret "${monitor_secret}" -o jsonpath='{.data.password}'; } | sha256sum | cut -d' ' -f1)"

# OTELCOL_IMAGE is repository:tag@digest
img_repo="${OTELCOL_IMAGE%%:*}"
img_rest="${OTELCOL_IMAGE#*:}"
img_tag="${img_rest%%@*}"
img_digest="${OTELCOL_IMAGE#*@}"

release() {
  local name="$1" values args
  values="$(sed -e "s|\${OTELCOL_IMAGE_REPOSITORY}|${img_repo}|g" \
    -e "s|\${OTELCOL_IMAGE_TAG}|${img_tag}|g" \
    -e "s|\${OTELCOL_IMAGE_DIGEST}|${img_digest}|g" \
    -e "s|\${GATEWAY_ENDPOINT}|${gateway_endpoint}|g" \
    -e "s|\${INPUTS_SHA256}|${inputs_sha}|g" "${here}/otel/${name}-values.yaml")"
  args=(opentelemetry-collector --repo "${OTEL_CHART_REPO}" --version "${OTEL_CHART_VERSION}"
    --kube-context "${ctx}" -n "${otel_ns}" -f -)
  # helm get manifest adds blank lines; compare without them
  if [ "$(helm template "${name}" "${args[@]}" <<<"${values}" | sed '/^$/d' | sha256sum)" = \
       "$(helm get manifest "${name}" --kube-context "${ctx}" -n "${otel_ns}" 2>/dev/null | sed '/^$/d' | sha256sum)" ]; then
    echo "release ${name}: unchanged"
  else
    helm upgrade --install "${name}" "${args[@]}" --history-max 3 <<<"${values}"
  fi
}
release agent
release cluster
k -n "${otel_ns}" rollout status daemonset/otelcol-agent-agent --timeout=300s
k -n "${otel_ns}" rollout status deployment/otelcol-cluster --timeout=300s
phase "collectors ready"
