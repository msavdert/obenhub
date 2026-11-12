#!/usr/bin/env bash
# Fail unless the tools on PATH are the ones the repository pins in
# mise.k8s.toml: kind, kubectl, helm and the kubectl-cnpg plugin, each exactly
# at its pin. Also: kubectl within one minor of the Kubernetes version of
# KIND_NODE_IMAGE (lab/k8s/versions.sh, the kubectl skew policy), and the
# plugin pin equal to CNPG_VERSION in versions.sh. docker must be on PATH (not
# a mise tool). Called by up.sh; can be run alone. On a mismatch run it as
# `MISE_ENV=k8s mise exec -- lab/k8s/scripts/check-tools.sh`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
mise_file="${repo_root}/mise.k8s.toml"
# shellcheck source=/dev/null
source "${here}/versions.sh"

errors=0
mise_errors=0
fail() { echo "tool check: $1" >&2; errors=$((errors + 1)); }
mise_fail() { fail "$1"; mise_errors=$((mise_errors + 1)); }

# pinned NAME: the version mise.k8s.toml pins, from `name = "x"` or from the
# inline table `"name" = { version = "x", ... }`
pinned() {
  sed -n -e "s|^\"\\{0,1\\}${1}\"\\{0,1\\} = \"\\([^\"]*\\)\"\$|\\1|p" \
    -e "s|^\"\\{0,1\\}${1}\"\\{0,1\\} = {.*version = \"\\([^\"]*\\)\".*}\$|\\1|p" "${mise_file}" | head -n1
}

# version_of TOOL CMD...: stdout of CMD; a failing CMD is a tool check message
# (a failed command substitution must not end the script silently under set -e)
out=""
version_of() {
  local tool="$1"
  shift
  if ! out="$("$@" 2>/dev/null)"; then
    mise_fail "${tool}: '$*' failed"
    out=""
    return 0
  fi
}

command -v docker >/dev/null || fail "docker not on PATH"
for t in kind kubectl helm; do
  command -v "${t}" >/dev/null || mise_fail "${t} not on PATH"
done

want_kind="$(pinned kind)"
want_kubectl="$(pinned kubectl)"
want_helm="$(pinned helm)"
want_cnpg="$(pinned github:cloudnative-pg/cloudnative-pg)"
for p in kind:"${want_kind}" kubectl:"${want_kubectl}" helm:"${want_helm}" kubectl-cnpg:"${want_cnpg}"; do
  [ -n "${p#*:}" ] || mise_fail "${p%%:*} has no pin in ${mise_file}"
done
[ "${want_cnpg}" = "${CNPG_VERSION}" ] || fail "mise.k8s.toml pins kubectl-cnpg '${want_cnpg}', versions.sh CNPG_VERSION is '${CNPG_VERSION}'"

have_kind="" have_helm="" have_kubectl="" have_cnpg=""
if command -v kind >/dev/null; then
  version_of kind kind version
  have_kind="$(sed -n 's/^kind v\([0-9.]*\).*/\1/p' <<<"${out}")"
fi
if command -v helm >/dev/null; then
  version_of helm helm version --template '{{.Version}}'
  have_helm="$(sed 's/^v//; s/+.*//' <<<"${out}")"
fi
if command -v kubectl >/dev/null; then
  version_of kubectl kubectl version --client
  have_kubectl="$(sed -n 's/^Client Version: v\([0-9.]*\).*/\1/p' <<<"${out}")"
  if command -v kubectl-cnpg >/dev/null; then
    version_of kubectl-cnpg kubectl cnpg version
    have_cnpg="$(sed -n 's/^Build: {Version:\([0-9.]*\) .*/\1/p' <<<"${out}")"
  else
    mise_fail "kubectl-cnpg not on PATH"
  fi
fi
cmp_pin() { # tool have want
  if [ -z "$2" ] && [ "${errors}" != 0 ]; then return 0; fi # already reported
  if [ "$2" != "$3" ]; then mise_fail "$1 is '${2:-unreadable}', mise.k8s.toml pins '$3'"; fi
}
cmp_pin kind "${have_kind}" "${want_kind}"
cmp_pin helm "${have_helm}" "${want_helm}"
cmp_pin kubectl "${have_kubectl}" "${want_kubectl}"
cmp_pin kubectl-cnpg "${have_cnpg}" "${want_cnpg}"

# KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:...
node_minor="$(sed -n 's|^[^:]*:v1\.\([0-9]*\)\..*|\1|p' <<<"${KIND_NODE_IMAGE}")"
kubectl_minor="$(sed -n 's/^1\.\([0-9]*\)\..*/\1/p' <<<"${have_kubectl}")"
if [ -z "${node_minor}" ]; then
  fail "cannot read the Kubernetes minor of KIND_NODE_IMAGE '${KIND_NODE_IMAGE}'"
elif [ -n "${kubectl_minor}" ]; then
  skew=$((kubectl_minor - node_minor))
  [ "${skew#-}" -le 1 ] || fail "kubectl ${have_kubectl} is more than one minor from the cluster's Kubernetes 1.${node_minor}"
fi

if [ "${errors}" != 0 ]; then
  [ "${mise_errors}" = 0 ] || echo "tool check: run it as 'MISE_ENV=k8s mise exec -- <script>' from ${repo_root} (install the tools with 'MISE_ENV=k8s mise install')" >&2
  exit 1
fi
echo "tools ok: kind ${have_kind}, kubectl ${have_kubectl}, helm ${have_helm}, kubectl-cnpg ${have_cnpg}"
