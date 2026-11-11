#!/usr/bin/env bash
# Delete the kind cluster (and with it the operator and all data).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${here}/versions.sh"
kind delete cluster --name "${KIND_CLUSTER:?}"
