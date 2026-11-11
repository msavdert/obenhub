#!/usr/bin/env bash
# Bring up kind, the CloudNativePG operator and the three-instance Cluster.
# Idempotent: every step checks or applies declaratively.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${here}/versions.sh"

# Values are pasted into YAML with sed: refuse empty ones and sed metacharacters.
for v in KIND_CLUSTER KIND_NODE_IMAGE PG_IMAGE; do
  case "${!v:-}" in
    "" | *[\&\|\\]*) echo "versions.sh: ${v} is empty or contains & | or backslash" >&2; exit 1 ;;
  esac
done

name="${KIND_CLUSTER}"
ctx="kind-${name}"
k() { kubectl --context "${ctx}" "$@"; }

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

k apply --server-side -f "${CNPG_MANIFEST_URL}"
k -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s

sed "s|\${PG_IMAGE}|${PG_IMAGE}|g" "${here}/cnpg/cluster.yaml" | k apply --server-side -f -

echo "waiting for 3 ready instances"
for _ in $(seq 1 120); do
  ready="$(k -n obenhub get cluster pg -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
  if [ "${ready:-0}" = 3 ]; then
    k -n obenhub get cluster pg
    exit 0
  fi
  sleep 5
done
echo "timed out waiting for readyInstances=3 (got '${ready:-}')" >&2
exit 1
