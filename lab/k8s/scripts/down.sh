#!/usr/bin/env bash
# Delete the kind cluster (and with it the operator and all data) and the
# backend Compose project with its volumes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${here}/versions.sh"
# compose interpolates the required variables even for down; values are unused
GATEWAY_IP=127.0.0.1 GATEWAY_PORT=0 GRAFANA_ADMIN_PASSWORD=unused \
  docker compose -p obenhub-k8s -f "${here}/mon/compose.yaml" down -v
rm -f "${here}/mon/.env"
kind delete cluster --name "${KIND_CLUSTER:?}"
