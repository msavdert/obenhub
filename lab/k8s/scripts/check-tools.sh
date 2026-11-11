#!/usr/bin/env bash
# Fail unless the tools on PATH are the ones the repository pins: kind, helm
# and the kubectl-cnpg plugin exactly as in mise.toml, kubectl within one minor
# of the Kubernetes version of KIND_NODE_IMAGE (lab/k8s/versions.sh, the
# kubectl skew policy), and the plugin at CNPG_VERSION. Called by up.sh; can be
# run alone. On a mismatch run it as `mise exec -- lab/k8s/scripts/check-tools.sh`
# (mise tasks and an activated mise shell already do).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
# shellcheck source=/dev/null
source "${here}/versions.sh"

errors=0
fail() { echo "tool check: $1" >&2; errors=$((errors + 1)); }
hint() { echo "tool check: run it as 'mise exec -- <script>' from ${repo_root} (install the tools with 'mise install')" >&2; exit 1; }

# pinned NAME: the version mise.toml pins (a plain `name = "x"` line)
pinned() { sed -n "s/^${1} = \"\\([^\"]*\\)\"\$/\\1/p" "${repo_root}/mise.toml" | head -n1; }

for t in docker kind kubectl helm; do
  command -v "${t}" >/dev/null || fail "${t} not on PATH"
done
[ "${errors}" = 0 ] || hint

want_kind="$(pinned kind)"
want_helm="$(pinned helm)"
have_kind="$(kind version | sed -n 's/^kind v\([0-9.]*\).*/\1/p')"
have_helm="$(helm version --template '{{.Version}}' | sed 's/^v//; s/+.*//')"
have_kubectl="$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version: v\([0-9.]*\).*/\1/p' || true)"
[ -n "${want_kind}" ] && [ "${have_kind}" = "${want_kind}" ] || fail "kind is '${have_kind}', mise.toml pins '${want_kind}'"
[ -n "${want_helm}" ] && [ "${have_helm}" = "${want_helm}" ] || fail "helm is '${have_helm}', mise.toml pins '${want_helm}'"

# KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:...
node_minor="$(sed -n 's|^[^:]*:v1\.\([0-9]*\)\..*|\1|p' <<<"${KIND_NODE_IMAGE}")"
kubectl_minor="$(sed -n 's/^1\.\([0-9]*\)\..*/\1/p' <<<"${have_kubectl}")"
if [ -z "${node_minor}" ] || [ -z "${kubectl_minor}" ]; then
  fail "cannot read the Kubernetes minor (node image '${KIND_NODE_IMAGE}', kubectl '${have_kubectl}')"
else
  skew=$((kubectl_minor - node_minor))
  [ "${skew#-}" -le 1 ] || fail "kubectl ${have_kubectl} is more than one minor from the cluster's Kubernetes 1.${node_minor}"
fi

have_cnpg="$(kubectl cnpg version 2>/dev/null | sed -n 's/^Build: {Version:\([0-9.]*\) .*/\1/p' || true)"
[ "${have_cnpg}" = "${CNPG_VERSION}" ] || fail "kubectl-cnpg is '${have_cnpg:-missing}', versions.sh CNPG_VERSION is '${CNPG_VERSION}' (mise.toml pins the plugin)"

[ "${errors}" = 0 ] || hint
echo "tools ok: kind ${have_kind}, kubectl ${have_kubectl}, helm ${have_helm}, kubectl-cnpg ${have_cnpg}"
